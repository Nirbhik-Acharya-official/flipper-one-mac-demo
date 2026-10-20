#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
source_initrd="${1:-.artifacts/boot/debian-initrd}"
destination="${2:-.artifacts/boot/mac-initrd}"
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
mkdir -p "$staging/scripts/local-bottom" "$staging/conf"
cp Tools/guest/flipper-mac-runtime "$staging/scripts/local-bottom/flipper-mac-runtime"
chmod 755 "$staging/scripts/local-bottom/flipper-mac-runtime"
cp Tools/guest/flipctl-mac.conf "$staging/conf/flipctl-mac.conf"
cp Tools/guest/flipper-mac-audio.conf "$staging/conf/flipper-mac-audio.conf"
cp Tools/guest/flipper-mac-modules.conf "$staging/conf/flipper-mac-modules.conf"
if /usr/bin/tar -tf "$source_initrd" | grep -Ex '(\./)?scripts/local-bottom/ORDER' > "$staging/order-path"; then
    /usr/bin/tar -xOf "$source_initrd" "$(cat "$staging/order-path")" > "$staging/scripts/local-bottom/ORDER"
fi
printf '\n%s\n' '/scripts/local-bottom/flipper-mac-runtime "$@"' >> "$staging/scripts/local-bottom/ORDER"
cat "$source_initrd" > "$staging/initrd"
(
    cd "$staging"
    printf '%s\n' scripts scripts/local-bottom scripts/local-bottom/ORDER scripts/local-bottom/flipper-mac-runtime conf conf/flipctl-mac.conf conf/flipper-mac-audio.conf conf/flipper-mac-modules.conf |
        /usr/bin/cpio -o -H newc --quiet | gzip -n
) >> "$staging/initrd"
mv "$staging/initrd" "$destination"
