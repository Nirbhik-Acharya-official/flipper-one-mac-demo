import Foundation
import Virtualization

@MainActor
final class FlipperVM: ObservableObject {
    @Published private(set) var status = "Ready to start"
    @Published private(set) var console = ""
    @Published private(set) var url: URL?
    @Published private(set) var running = false
    @Published private(set) var preparing = false
    @Published private(set) var stopping = false

    var lifecycleActive: Bool { preparing || machine != nil || running }

    private var sessionID: UUID?
    private var preparationID: UUID?
    private var shutdownID: UUID?
    private var shutdownCheck: DispatchWorkItem?
    private var quitRequested = false
    private var machine: VZVirtualMachine?
    private var serialInput: Pipe?
    private var serialOutput: Pipe?
    private var poller: Timer?
    private var candidateURL: URL?
    private var events: VMEvents?
    private var probeTask: URLSessionDataTask?
    private let probeSession = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)

    func start() {
        guard !lifecycleActive && !quitRequested else { return }
        let sessionID = UUID()
        self.sessionID = sessionID
        preparationID = sessionID
        preparing = true
        status = "Preparing the Flipper OS disk. First launch may take a few minutes."
        console = ""
        url = nil
        candidateURL = nil

        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try Self.prepareDisk() }
            DispatchQueue.main.async {
                guard self.preparationID == sessionID else { return }
                self.preparationID = nil
                guard self.sessionID == sessionID, !self.quitRequested else {
                    self.preparing = false
                    self.status = "Preparation cancelled. Ready to start."
                    return
                }
                switch result {
                case .success(let disk): self.boot(disk: disk, sessionID: sessionID)
                case .failure(let error):
                    self.sessionID = nil
                    self.preparing = false
                    self.status = "Cannot prepare disk: \(error.localizedDescription)"
                }
            }
        }
    }

    func stop() {
        guard !stopping else { return }
        guard let machine, let sessionID else {
            if preparing {
                self.sessionID = nil
                status = "Cancelling preparation; waiting for disk extraction to finish…"
            }
            return
        }
        stopping = true
        if preparing {
            status = "Waiting for VM startup before shutting down…"
            return
        }
        requestShutdown(machine: machine, sessionID: sessionID)
    }

    func prepareToQuit() {
        quitRequested = true
        stop()
    }

    func cancelQuit() {
        quitRequested = false
    }

    private func isCurrent(sessionID: UUID, machine: VZVirtualMachine) -> Bool {
        isCurrent(sessionID: sessionID, machineID: ObjectIdentifier(machine))
    }

    private func isCurrent(sessionID: UUID, machineID: ObjectIdentifier) -> Bool {
        self.sessionID == sessionID && self.machine.map(ObjectIdentifier.init) == machineID
    }

    private func requestShutdown(machine: VZVirtualMachine, sessionID: UUID) {
        guard isCurrent(sessionID: sessionID, machine: machine) else { return }
        if machine.state == .stopped {
            finished(error: nil)
            return
        }
        status = "Shutting down Flipper OS…"
        do {
            try machine.requestStop()
        } catch {
            stopping = false
            status = "Shutdown request failed: \(error.localizedDescription)"
            return
        }
        let shutdownID = UUID()
        self.shutdownID = shutdownID
        checkStopped(machine: machine, sessionID: sessionID, shutdownID: shutdownID, attemptsRemaining: 20)
    }

    private func checkStopped(machine: VZVirtualMachine, sessionID: UUID, shutdownID: UUID,
                              attemptsRemaining: Int) {
        guard isCurrent(sessionID: sessionID, machine: machine), self.shutdownID == shutdownID else { return }
        if machine.state == .stopped {
            finished(error: nil)
        } else if attemptsRemaining > 0 {
            let check = DispatchWorkItem { [weak self, weak machine] in
                guard let self, let machine else { return }
                self.checkStopped(machine: machine, sessionID: sessionID, shutdownID: shutdownID,
                                  attemptsRemaining: attemptsRemaining - 1)
            }
            shutdownCheck = check
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: check)
        } else {
            shutdownCheck = nil
            self.shutdownID = nil
            stopping = false
            status = "Shutdown timed out. Try Shut Down again or use the guest OS shutdown command."
        }
    }

    nonisolated private static func prepareDisk() throws -> URL {
        let resources = Bundle.main.resourceURL!
        let packaged = resources.appendingPathComponent("guest.tar.xz")
        guard FileManager.default.fileExists(atPath: packaged.path) else {
            throw NSError(domain: "FlipperOneMac", code: 1, userInfo: [NSLocalizedDescriptionKey: "The bundled Flipper OS archive is missing."])
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Flipper One Mac", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let destination = support.appendingPathComponent("guest.img")
        if !FileManager.default.fileExists(atPath: destination.path) {
            let partial = support.appendingPathComponent("flipper-guest.img")
            try? FileManager.default.removeItem(at: partial)
            let extract = Process()
            extract.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            extract.arguments = ["-xJf", packaged.path, "-C", support.path]
            try extract.run()
            extract.waitUntilExit()
            guard extract.terminationStatus == 0 else {
                try? FileManager.default.removeItem(at: partial)
                throw NSError(domain: "FlipperOneMac", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not unpack the guest disk. Check free space and retry."])
            }
            try FileManager.default.moveItem(at: partial, to: destination)
        }
        return destination
    }

    private func boot(disk: URL, sessionID: UUID) {
        guard self.sessionID == sessionID, !quitRequested else { return }
        do {
            let resources = Bundle.main.resourceURL!
            let loader = VZLinuxBootLoader(kernelURL: resources.appendingPathComponent("kernel"))
            loader.initialRamdiskURL = resources.appendingPathComponent("initrd")
            loader.commandLine = "console=hvc0 root=UUID=a8bf455c-b2e2-4df4-93bb-bf2479013f40 rootflags=subvol=@Minimal rootwait rw systemd.unit=multi-user.target"

            let config = VZVirtualMachineConfiguration()
            config.platform = VZGenericPlatformConfiguration()
            config.bootLoader = loader
            config.cpuCount = min(4, max(2, ProcessInfo.processInfo.activeProcessorCount / 2))
            config.memorySize = 2 * 1024 * 1024 * 1024
            config.storageDevices = [VZVirtioBlockDeviceConfiguration(
                attachment: try VZDiskImageStorageDeviceAttachment(url: disk, readOnly: false)
            )]
            let network = VZVirtioNetworkDeviceConfiguration()
            network.attachment = VZNATNetworkDeviceAttachment()
            config.networkDevices = [network]
            config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
            let audioOutput = VZVirtioSoundDeviceOutputStreamConfiguration()
            audioOutput.sink = VZHostAudioOutputStreamSink()
            let sound = VZVirtioSoundDeviceConfiguration()
            sound.streams = [audioOutput]
            config.audioDevices = [sound]

            let output = Pipe()
            let input = Pipe()
            serialInput = input
            serialOutput = output
            let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
            serial.attachment = VZFileHandleSerialPortAttachment(
                fileHandleForReading: input.fileHandleForReading,
                fileHandleForWriting: output.fileHandleForWriting
            )
            config.serialPorts = [serial]
            try config.validate()

            let machine = VZVirtualMachine(configuration: config)
            output.fileHandleForReading.readabilityHandler = { [weak self, weak machine] handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil }
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                DispatchQueue.main.async {
                    guard let self, let machine, self.isCurrent(sessionID: sessionID, machine: machine) else { return }
                    self.received(text)
                }
            }

            let events = VMEvents { [weak self] stoppedMachine, error in
                DispatchQueue.main.async {
                    guard let self, self.isCurrent(sessionID: sessionID, machine: stoppedMachine) else { return }
                    self.finished(error: error)
                }
            }
            machine.delegate = events
            self.events = events
            self.machine = machine
            status = "Booting Linux and FlipCTL…"
            machine.start { [weak self, weak machine] result in
                DispatchQueue.main.async {
                    guard let self, let machine, self.isCurrent(sessionID: sessionID, machine: machine) else { return }
                    self.preparing = false
                    switch result {
                    case .success:
                        self.running = true
                        if self.stopping || self.quitRequested {
                            self.stopping = true
                            self.requestShutdown(machine: machine, sessionID: sessionID)
                        } else {
                            self.status = self.url == nil ? "Waiting for FlipCTL…" : "Flipper OS running locally"
                        }
                    case .failure(let error):
                        self.finished(error: nil)
                        self.status = "VM failed to start: \(error.localizedDescription)"
                    }
                }
            }
        } catch {
            finished(error: nil)
            status = "VM configuration failed: \(error.localizedDescription)"
        }
    }

    private func received(_ text: String) {
        console = String((console + text).suffix(30_000))
        guard let sessionID, let machine, candidateURL == nil,
              let match = console.range(of: #"FLIPPER_URL=http://[0-9.]+:8899/"#, options: .regularExpression),
              let parsed = URL(string: String(console[match]).replacingOccurrences(of: "FLIPPER_URL=", with: "")),
              let host = parsed.host else { return }
        let octets = host.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4, octets.prefix(3) == [192, 168, 64],
              octets[3] >= 2, octets[3] < 255,
              parsed.scheme == "http", parsed.port == 8899, parsed.path == "/" else { return }
        candidateURL = parsed
        if !stopping { status = "Connecting to FlipCTL at \(parsed.host ?? "guest")…" }
        let machineID = ObjectIdentifier(machine)
        poller = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isCurrent(sessionID: sessionID, machineID: machineID) else { return }
                self.checkWebService()
            }
        }
        checkWebService()
    }

    private func checkWebService() {
        guard let sessionID, let machine, let candidateURL, url == nil, probeTask == nil else { return }
        var request = URLRequest(url: candidateURL)
        request.timeoutInterval = 2
        let machineID = ObjectIdentifier(machine)
        probeTask = probeSession.dataTask(with: request) { [weak self] _, response, error in
            DispatchQueue.main.async {
                guard let self, self.isCurrent(sessionID: sessionID, machineID: machineID),
                      self.candidateURL == candidateURL else { return }
                self.probeTask = nil
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    if let error, !self.stopping { self.status = "Waiting for FlipCTL: \(error.localizedDescription)" }
                    return
                }
                self.url = candidateURL
                if !self.stopping { self.status = "Flipper OS running locally" }
                self.poller?.invalidate()
                self.poller = nil
            }
        }
        probeTask?.resume()
    }

    private func finished(error: Error?) {
        sessionID = nil
        shutdownID = nil
        shutdownCheck?.cancel()
        shutdownCheck = nil
        poller?.invalidate()
        poller = nil
        probeTask?.cancel()
        probeTask = nil
        candidateURL = nil
        serialOutput?.fileHandleForReading.readabilityHandler = nil
        serialInput = nil
        serialOutput = nil
        machine?.delegate = nil
        events = nil
        machine = nil
        running = false
        preparing = false
        stopping = false
        url = nil
        status = error.map { "Guest stopped: \($0.localizedDescription)" } ?? "Stopped"
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private final class VMEvents: NSObject, VZVirtualMachineDelegate {
    private let onStop: (VZVirtualMachine, Error?) -> Void

    init(onStop: @escaping (VZVirtualMachine, Error?) -> Void) {
        self.onStop = onStop
    }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        onStop(virtualMachine, nil)
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        onStop(virtualMachine, error)
    }
}
