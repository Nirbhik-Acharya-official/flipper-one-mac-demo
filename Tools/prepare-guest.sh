#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
mkdir -p .artifacts/boot
image='.artifacts/flipper-os-2413.img.zst'
expected='36b0c6bf504b2b8400da25e136807a5e223a21b99657d9e623b9489e55e0b0aa'

command -v docker >/dev/null || { echo 'Docker is needed by builders only, not by the installed app.' >&2; exit 1; }
command -v zstd >/dev/null || { echo 'zstd is needed by builders only, not by the installed app.' >&2; exit 1; }

if [[ ! -f "$image" ]]; then
    curl -fL --retry 3 -o "$image" \
        'https://dl-linux-images.flipp.dev/full-img/2413/debian-512-nobootloader-2413.img.zst'
fi
printf '%s  %s\n' "$expected" "$image" | shasum -a 256 -c -
zstd -d -f "$image" -o .artifacts/flipper-guest.img

docker run --rm --privileged \
    -v "$PWD/.artifacts:/data" -v "$PWD/Tools/guest:/assets:ro" \
    debian:trixie@sha256:913f6706df59a68922d1dd08f78c2476560a8d367897200a6005b00e5f67c2d5 bash -euo pipefail -c '
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y -qq btrfs-progs cloud-guest-utils util-linux >/dev/null

        loop="$(losetup -f --show -o 67108864 /data/flipper-guest.img)"
        cleanup() {
            set +e
            umount /guest/sys /guest/proc /guest/dev/pts /guest/dev /guest/boot /guest 2>/dev/null
            losetup -d "$loop" 2>/dev/null
        }
        trap cleanup EXIT
        mkdir -p /guest
        mount -t btrfs -o subvol=@Minimal "$loop" /guest
        mount -t btrfs -o subvol=boot "$loop" /guest/boot
        mount --bind /dev /guest/dev
        mount --bind /dev/pts /guest/dev/pts
        mount -t proc proc /guest/proc
        mount -t sysfs sysfs /guest/sys
        dns_link="$(readlink /guest/etc/resolv.conf || true)"
        cp --remove-destination /etc/resolv.conf /guest/etc/resolv.conf
        printf "%s\n" virtio_pci virtio_blk virtio_net virtio_console >> /guest/etc/initramfs-tools/modules
        chroot /guest apt-get update -qq
        chroot /guest apt-get install -y --no-install-recommends linux-image-arm64
        chroot /guest apt-get clean
        rm -f /guest/etc/resolv.conf
        if [ -n "$dns_link" ]; then ln -s "$dns_link" /guest/etc/resolv.conf; fi

        mkdir -p /guest/etc/systemd/system/multi-user.target.wants /guest/usr/local/bin
        cp /assets/flipctl.service /guest/etc/systemd/system/flipctl.service
        mkdir -p /guest/etc/systemd/system/flipctl.service.d
        cp /assets/flipctl-mac.conf /guest/etc/systemd/system/flipctl.service.d/90-flipper-mac.conf
        mkdir -p /guest/etc/wireplumber/wireplumber.conf.d /guest/etc/modules-load.d
        cp /assets/flipper-mac-audio.conf /guest/etc/wireplumber/wireplumber.conf.d/90-flipper-mac.conf
        cp /assets/flipper-mac-modules.conf /guest/etc/modules-load.d/flipper-mac.conf
        cp /assets/flipper-mac-announce.service /guest/etc/systemd/system/flipper-mac-announce.service
        install -m 755 /assets/flipper-mac-announce /guest/usr/local/bin/flipper-mac-announce
        ln -sf /etc/systemd/system/flipper-mac-announce.service \
            /guest/etc/systemd/system/multi-user.target.wants/flipper-mac-announce.service

        kernel="$(find /guest/boot -maxdepth 1 -name "vmlinuz-6.12*" | sort -V | tail -1)"
        version="${kernel##*/vmlinuz-}"
        test -n "$version" && test -f "/guest/usr/lib/modules/$version/initrd"
        cp "$kernel" /data/boot/debian-kernel
        cp "/guest/usr/lib/modules/$version/initrd" /data/boot/debian-initrd
        uuid="$(blkid -p -o value -s UUID "$loop")"
        test "$uuid" = a8bf455c-b2e2-4df4-93bb-bf2479013f40

        umount /guest/sys /guest/proc /guest/dev/pts /guest/dev /guest/boot /guest
        losetup -d "$loop"
        trap - EXIT

        truncate -s 10G /data/flipper-guest.img
        full_loop="$(losetup -f --show /data/flipper-guest.img)"
        growpart "$full_loop" 3
        losetup -d "$full_loop"
        loop="$(losetup -f --show -o 67108864 /data/flipper-guest.img)"
        trap cleanup EXIT
        mount -t btrfs -o subvol=@Minimal "$loop" /guest
        btrfs filesystem resize max /guest
        btrfs filesystem resize -1M /guest
        df -h /guest
    '

rm -f .artifacts/guest.tar.xz
echo 'Guest prepared. Run: bash Tools/package.sh'
