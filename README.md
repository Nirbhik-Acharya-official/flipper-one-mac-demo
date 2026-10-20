<img src="assets/icon.png" width="96" height="96" alt="Flipper One Mac Demo icon">

# Flipper One Mac Demo

**Explore Flipper OS on your Apple Silicon Mac—no Flipper board required.**

An unofficial macOS app that boots the Flipper OS Debian ARM64 image using Apple's Virtualization framework and displays FlipCTL in a native window. Linux runs locally, with persistent storage, virtual Ethernet, software-rendered apps, and audio output through your Mac.

> This is a software demo, not a native macOS port or a full Flipper One hardware emulator. It is not affiliated with or endorsed by Flipper Devices.

## Highlights

- **Self-contained installation:** the DMG includes the app, Linux boot files, and prepared guest image.
- **No runtime setup:** users do not need UTM, Docker, or a separate image download.
- **Persistent guest:** installed apps and guest files survive restarts and app updates.
- **Mac audio output:** a virtual sound card connects guest playback to your Mac's default output device. No microphone is exposed.
- **Native controls:** Start, Shut Down, Reload, and a boot log for troubleshooting.

## Requirements

| Requirement | Details |
| --- | --- |
| Mac | Apple Silicon; Intel Macs are not supported by this build |
| macOS | Build target: macOS 13 or later; tested on macOS 27.0.1 only |
| Free storage | At least 12 GB for first launch and guest use |
| Guest resources | 2 GB RAM, 2–4 virtual CPUs, and a 10 GB virtual disk |
| Network | Guest apps and the app catalog may access the internet through NAT |

## Install

1. Download `Flipper-One-Mac-Demo.dmg` from [GitHub Releases](https://github.com/Nirbhik-Acharya-official/flipper-one-mac-demo/releases), or build it locally.
2. Open the DMG and drag **Flipper One Mac Demo.app** into **Applications**.
3. Launch the app. First launch unpacks the included disk and may take a few minutes; later launches reuse it.
4. Use FlipCTL to explore the guest and launch apps.
5. Click **Shut Down** and wait for **Stopped** before closing the app.

### Gatekeeper

The app is **ad-hoc signed, not Apple notarized**. macOS may block the first launch. If you trust the build, use Finder's **right-click → Open**, then follow any offered option in **System Settings → Privacy & Security**. Do not disable Gatekeeper globally.

### Update to 0.1.2

Shut down the old app, replace it with the new app from the DMG, and launch again. **Do not delete your guest disk.** The bundled initramfs applies compatibility settings to both new and existing guests before Linux services start. Installed apps and guest files remain in place.

Version 0.1.2 adds virtual audio output, fixes Doom's audio initialization, improves startup/shutdown handling, and adds viewer reload and initial-load retries.

## Compatibility

| Feature | Validation / limitation |
| --- | --- |
| Linux boot and FlipCTL viewer | Verified locally, including a connected remote-control page and App Manager |
| Doom | Launch and gameplay rendering verified with software rendering |
| Audio | Guest WAV playback completed; Doom produced active stereo PipeWire links and a running virtual PCM device |
| Other apps | System Monitor, Uptime, Ping, Browser, and Internet Radio passed launch smoke checks |
| Internet access | Virtual Ethernet/NAT; not a physical Wi-Fi or cellular connection |
| Physical peripherals | Not emulated: Rockchip RK3576 hardware, MCU, GPIO, radios, LEDs, device display, and USB gadget/controller modes |

Launch checks are not complete functional tests. The full app catalog, every radio station, audio quality, and every app's controls have **not** been manually validated. Other guest image profiles are unsupported. Automatic viewer discovery currently expects the `192.168.64.0/24` NAT subnet.

## Troubleshooting

| Symptom | What to check |
| --- | --- |
| First launch takes a while | Allow disk extraction to finish and confirm at least 12 GB of free space |
| Viewer is blank or disconnected | Wait for Linux to finish booting, inspect **Boot log**, then click **Reload** |
| No sound | Check guest volume/mute settings, your Mac's selected output device, and Mac volume |
| Doom fails on an older build | Install 0.1.2 and restart the guest; do not reset the disk |
| Shutdown times out | Retry **Shut Down** or use the guest OS shutdown command; avoid force-quitting while the guest writes data |
| Wi-Fi scans or board diagnostics fail | These need physical hardware and are not implemented by the VM |

When reporting a bug, include the app version, Mac model, macOS version, affected guest app, reproduction steps, and relevant boot-log excerpts. Remove private information first. **Never upload your guest disk.**

## Data and security

Guest data is stored at:

```text
~/Library/Application Support/Flipper One Mac/guest.img
```

Removing the macOS app does not remove this disk. It may contain private files, credentials, or app data. Back it up only after shutting down the guest.

The viewer connects to the guest over a private virtual NAT network using HTTP. The guest is not offline-only, and this demo does not establish a trusted security boundary for guest images or downloaded apps. Run only images and applications you trust.

## Build from source

Builders need an Apple Silicon Mac, Xcode command-line tools, a running Docker installation, `zstd`, `xz`, internet access, and substantial free disk space for intermediate images. **Docker, `zstd`, and `xz` are build-time dependencies only.**

From the repository root:

```sh
xcode-select --install # If command-line tools are not installed
bash Tools/prepare-guest.sh
bash Tools/package.sh
hdiutil verify dist/Flipper-One-Mac-Demo.dmg
codesign --verify --strict 'build/dmg-root/Flipper One Mac Demo.app'
```

The output is `dist/Flipper-One-Mac-Demo.dmg`. Signing is ad-hoc; the build does not notarize the app.

### Build pipeline

1. `prepare-guest.sh` downloads official image build **2413**, verifies its SHA-256, and uses a privileged build-time Debian container to install a compatible ARM64 kernel and guest services. Rerunning this script recreates the prepared build image.
2. `patch-initrd.sh` embeds boot-time settings for hosted-app runtime directories, software rendering, and audio routing. These also migrate existing guest disks without a reset.
3. `package.sh` compiles the Swift app, embeds the kernel/initramfs and XZ-compressed guest archive, creates the app icon, signs the bundle, and produces the DMG.

Pinned upstream image: `debian-512-nobootloader-2413.img.zst`

```text
SHA-256: 36b0c6bf504b2b8400da25e136807a5e223a21b99657d9e623b9489e55e0b0aa
```

Build intermediates stay in `.artifacts/`; `.artifacts/`, `build/`, and `dist/` are ignored by Git. Publish installers as release assets, not source files. **Never package a user's live guest disk:** releases must use the prepared build image, not the disk in Application Support.

## Project layout

```text
Sources/FlipperOneMac/    SwiftUI app, VM lifecycle, and FlipCTL viewer
Resources/               App metadata and virtualization entitlement
Tools/guest/             Linux services and compatibility settings
Tools/prepare-guest.sh   Prepare the upstream guest image
Tools/patch-initrd.sh    Apply compatibility settings during guest boot
Tools/package.sh         Compile, sign, and package the installer
assets/                  App icon
```

## License and credits

The original macOS wrapper and build scripts are available under the [MIT License](LICENSE). This does **not** relicense Flipper OS, Debian, FlipCTL, bundled packages or firmware, or the user-supplied icon. Those components retain their respective licenses and redistribution obligations. Review third-party licensing before distributing a bundled installer.

Flipper names and imagery belong to their respective owners. The icon is used for this demo and is not offered as a general-purpose brand asset.

- [Flipper One development log](https://docs.flipper.net/one/dev-log/10)
- [Official Linux image builds](https://dl-linux-images.flipp.dev/full-img/)
- [Flipper One Linux build scripts](https://github.com/flipperdevices/flipperone-linux-build-scripts)
- [FlipCTL](https://github.com/flipperdevices/flipctl-slint)
