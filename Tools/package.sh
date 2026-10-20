#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
mkdir -p .artifacts build dist

[[ -f .artifacts/flipper-guest.img ]] || { echo 'Missing prepared guest image' >&2; exit 1; }
command -v xz >/dev/null || { echo 'xz is needed by builders only, not by the installed app.' >&2; exit 1; }
if [[ ! -f .artifacts/guest.tar.xz || .artifacts/flipper-guest.img -nt .artifacts/guest.tar.xz ]]; then
    tar -cf - -C .artifacts flipper-guest.img | xz -T4 -3 > .artifacts/guest.tar.xz
fi

app='build/Flipper One Mac Demo.app'
rm -rf "$app" build/dmg-root
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" build/dmg-root
cp Resources/Info.plist "$app/Contents/Info.plist"
cp .artifacts/boot/debian-kernel "$app/Contents/Resources/kernel"
bash Tools/patch-initrd.sh .artifacts/boot/debian-initrd "$app/Contents/Resources/initrd"
cp .artifacts/guest.tar.xz "$app/Contents/Resources/guest.tar.xz"
iconset='.artifacts/FlipperOneMac.iconset'
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
    sips -s format png -z "$size" "$size" assets/icon.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
    doubled=$((size * 2))
    sips -s format png -z "$doubled" "$doubled" assets/icon.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"
xcrun swiftc -O -target arm64-apple-macos13.0 \
    -framework Virtualization -framework WebKit -framework SwiftUI \
    -o "$app/Contents/MacOS/FlipperOneMac" Sources/FlipperOneMac/*.swift
codesign --force --sign - --entitlements Resources/FlipperOneMac.entitlements "$app"

mv "$app" build/dmg-root/
ln -s /Applications build/dmg-root/Applications
hdiutil create -quiet -ov -volname 'Flipper One Mac Demo' \
    -srcfolder build/dmg-root -format UDZO 'dist/Flipper-One-Mac-Demo.dmg'
echo "Ready: $(pwd)/dist/Flipper-One-Mac-Demo.dmg"
