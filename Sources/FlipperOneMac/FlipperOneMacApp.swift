import SwiftUI
import WebKit

@main
struct FlipperOneMacApp: App {
    @NSApplicationDelegateAdaptor(FlipperAppDelegate.self) private var delegate
    @StateObject private var vm = FlipperVM()
    @State private var reloadID = UUID()

    var body: some Scene {
        WindowGroup("Flipper One") {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: "desktopcomputer")
                        .foregroundStyle(.orange)
                    Text("Flipper One")
                        .font(.headline)
                    Spacer()
                    Text(vm.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if vm.url != nil {
                        Button("Reload") { reloadID = UUID() }
                    }
                    if vm.running || vm.stopping {
                        Button(vm.stopping ? "Stopping…" : "Shut Down") { vm.stop() }
                            .disabled(vm.stopping)
                    } else {
                        Button("Start") { vm.start() }
                            .disabled(vm.lifecycleActive)
                    }
                }
                .padding(14)

                Divider()

                if let url = vm.url {
                    FlipperWebView(url: url, reloadID: reloadID)
                        .id(url)
                } else {
                    VStack(spacing: 18) {
                        Image(systemName: "cpu")
                            .font(.system(size: 58))
                            .foregroundStyle(.orange)
                        Text("Flipper OS on your Mac")
                            .font(.title2.weight(.semibold))
                        Text(vm.status)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        if vm.preparing {
                            ProgressView().controlSize(.large)
                        }
                        if !vm.console.isEmpty {
                            DisclosureGroup("Boot log") {
                                ScrollView {
                                    Text(vm.console)
                                        .font(.system(size: 11, design: .monospaced))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .textSelection(.enabled)
                                }
                                .frame(height: 190)
                            }
                            .frame(maxWidth: 650)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(30)
                }
            }
            .frame(minWidth: 760, minHeight: 560)
            .onAppear { delegate.vm = vm }
            .task { vm.start() }
        }
    }
}

@MainActor
private final class FlipperAppDelegate: NSObject, NSApplicationDelegate {
    weak var vm: FlipperVM?
    private var terminationID: UUID?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let vm else { return .terminateNow }
        guard terminationID == nil else { return .terminateLater }
        vm.prepareToQuit()
        guard vm.lifecycleActive else { return .terminateNow }
        let terminationID = UUID()
        self.terminationID = terminationID
        waitForShutdown(terminationID: terminationID, attemptsRemaining: 25)
        return .terminateLater
    }

    private func waitForShutdown(terminationID: UUID, attemptsRemaining: Int) {
        guard self.terminationID == terminationID else { return }
        guard vm?.lifecycleActive == true else {
            self.terminationID = nil
            NSApplication.shared.reply(toApplicationShouldTerminate: true)
            return
        }
        guard attemptsRemaining > 0 else {
            self.terminationID = nil
            vm?.cancelQuit()
            NSApplication.shared.reply(toApplicationShouldTerminate: false)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            self.waitForShutdown(terminationID: terminationID, attemptsRemaining: attemptsRemaining - 1)
        }
    }
}

private struct FlipperWebView: NSViewRepresentable {
    let url: URL
    let reloadID: UUID

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        if context.coordinator.loadedURL != url || context.coordinator.reloadID != reloadID {
            context.coordinator.loadedURL = url
            context.coordinator.reloadID = reloadID
            context.coordinator.loadOrigin(in: view)
        }
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.invalidate()
        view.navigationDelegate = nil
        view.stopLoading()
    }

    func makeCoordinator() -> Coordinator { Coordinator(origin: url) }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let origin: URL
        var loadedURL: URL?
        var reloadID: UUID?
        private var navigation: WKNavigation?
        private var retry: DispatchWorkItem?
        private var generation = UUID()
        private var retriesRemaining = 3
        private var initialLoadFinished = false

        init(origin: URL) { self.origin = origin }

        func invalidate() {
            generation = UUID()
            retry?.cancel()
            retry = nil
            navigation = nil
        }

        func loadOrigin(in webView: WKWebView) {
            invalidate()
            retriesRemaining = 3
            initialLoadFinished = false
            navigation = webView.load(URLRequest(url: origin))
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            loadOrigin(in: webView)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard navigation === self.navigation else { return }
            initialLoadFinished = true
            retry?.cancel()
            retry = nil
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            retryInitialLoad(in: webView, navigation: navigation, error: error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            retryInitialLoad(in: webView, navigation: navigation, error: error)
        }

        private func retryInitialLoad(in webView: WKWebView, navigation: WKNavigation?, error: Error) {
            guard navigation === self.navigation, !initialLoadFinished, retriesRemaining > 0,
                  retry == nil, (error as NSError).code != NSURLErrorCancelled else { return }
            retriesRemaining -= 1
            let generation = generation
            let retry = DispatchWorkItem { [weak self, weak webView] in
                guard let self, let webView, self.generation == generation else { return }
                self.retry = nil
                self.navigation = webView.load(URLRequest(url: self.origin))
            }
            self.retry = retry
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: retry)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let target = navigationAction.request.url,
                  target.scheme == "http", target.host == origin.host,
                  target.port == origin.port else {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}
