#!/usr/bin/env bash
set -euo pipefail

DIR="$(dirname "$(realpath "$0")")"
FLUFFY="${FLUFFY:-/mnt/fluffy}"

"$DIR/mkuid.sh" --check

if ! mountpoint -q "$FLUFFY"
then
    mount "$FLUFFY"
fi

if ! id -u builder &>/dev/null
then
    useradd -m -U -s /bin/bash builder
fi

mkdir -pv /sw
mkdir -pv /work
mkdir -pv "$FLUFFY/sw/.build/keys"
chmod 0700 "$FLUFFY/sw/.build/keys"
mkdir -pv "$FLUFFY/work"
mkdir -pv "$FLUFFY/etc"
mkdir -pv "$FLUFFY/root"
chmod 0750 "$FLUFFY/root"
mkdir -pv "$FLUFFY/tmp"
chmod 1777 "$FLUFFY/tmp"
mkdir -pv "$FLUFFY/var/log"

if test ! -f "$FLUFFY/etc/machine-id"
then
    tr -d '-' < /proc/sys/kernel/random/uuid > "$FLUFFY/etc/machine-id"
fi

if ! compgen -G "$FLUFFY/etc/systemd/network/*.network" >/dev/null
then
    mkdir -pv "$FLUFFY/etc/systemd/network"
    cat << "NET_EOF" > "$FLUFFY/etc/systemd/network/10-eth-dhcp.network"
[Match]
Name=en* eth*

[Network]
DHCP=yes

[DHCPv4]
UseDomains=true
NET_EOF
fi

if test ! -f "$FLUFFY/etc/fstab"
then
    root_uuid="$(findmnt -no UUID "$FLUFFY" 2>/dev/null || true)"
    root_fstype="$(findmnt -no FSTYPE "$FLUFFY" 2>/dev/null || true)"
    root_fsroot="$(findmnt -no FSROOT "$FLUFFY" 2>/dev/null || true)"
    if test -z "$root_uuid"
    then
        root_src="$(findmnt -no SOURCE "$FLUFFY" 2>/dev/null || true)"
        root_dev="${root_src%%\[*}"
        if test -n "$root_dev" && test -b "$root_dev"
        then
            root_uuid="$(blkid -s UUID -o value "$root_dev" 2>/dev/null || true)"
        fi
    fi
    if test -n "$root_uuid" && test -n "$root_fstype"
    then
        if test "$root_fstype" = "btrfs" && test -n "$root_fsroot" && test "$root_fsroot" != "/"
        then
            root_opts="subvol=${root_fsroot#/},defaults"
        else
            root_opts="defaults"
        fi
        echo "UUID=$root_uuid / $root_fstype $root_opts 0 0" > "$FLUFFY/etc/fstab"
    fi
fi

if test -f "$FLUFFY/sw/init/bin/init"
then
    cp -fv "$FLUFFY/sw/init/bin/init" "$FLUFFY/init"
    chmod 0755 "$FLUFFY/init"
else
    init_squashfs=$(ls "$FLUFFY"/sw/init-*.squashfs 2>/dev/null | head -n 1 || true)
    if test -n "$init_squashfs" && test -f "$init_squashfs"
    then
        mkdir -p "$FLUFFY/tmp/init-extract"
        unsquashfs -f -d "$FLUFFY/tmp/init-extract" "$init_squashfs" bin/init
        cp -fv "$FLUFFY/tmp/init-extract/bin/init" "$FLUFFY/init"
        rm -rf "$FLUFFY/tmp/init-extract"
        chmod 0755 "$FLUFFY/init"
    fi
fi

if test -f "$FLUFFY/sw/.build/fstab"
then
    mkdir -pv "$FLUFFY/etc/fluffy"
    sed -E '/^#/d; /^\/sw\/[^ ]*-pass[0-9]+-[^ ]*\.squashfs[[:space:]]/d; /^\/sw\/(cross|host)-build-[^ ]*\.squashfs[[:space:]]/d; s/-pass[0-9]+//g' \
        "$FLUFFY/sw/.build/fstab" > "$FLUFFY/etc/fluffy/fstab"
fi

if test ! -f "$FLUFFY/etc/shadow"
then
    install -m 0600 /dev/null "$FLUFFY/etc/shadow"
else
    chmod 0600 "$FLUFFY/etc/shadow"
fi

if ! grep -q '^root:' "$FLUFFY/etc/shadow"
then
    echo "root:!:20000:0:99999:7:::" >> "$FLUFFY/etc/shadow"
fi

if ! awk -F: '$1 == "root" && $2 != "" && $2 != "!" && $2 != "*" { found=1 } END { exit !found }' "$FLUFFY/etc/shadow"
then
    if test -t 0 && test -s "$FLUFFY/etc/fluffy/fstab" && grep -q '^/sw/shadow-[0-9]' "$FLUFFY/etc/fluffy/fstab"
    then
        FLUFFY="$FLUFFY" unshare -m bash -euo pipefail -c '
            mount --make-rprivate /
            mkdir -p "$FLUFFY/dev" "$FLUFFY/dev/pts" "$FLUFFY/proc" "$FLUFFY/sys"
            mount --bind /dev "$FLUFFY/dev"
            mount --bind /dev/pts "$FLUFFY/dev/pts"
            mount -t proc proc "$FLUFFY/proc"
            mount -t sysfs sysfs "$FLUFFY/sys"
            while read -r src tgt _
            do
                test -n "$src" || continue
                mkdir -p "$FLUFFY$tgt"
                mount -t squashfs -o ro "$FLUFFY$src" "$FLUFFY$tgt"
            done < "$FLUFFY/etc/fluffy/fstab"
            if test -x "$FLUFFY/sw/shadow/bin/passwd"
            then
                chroot "$FLUFFY" /sw/shadow/bin/passwd root
            fi
        '
    fi
fi

if test -f "$DIR/boot/grub/grub.cfg"
then
    mkdir -pv "$FLUFFY/boot/grub"
    cp -fv "$DIR/boot/grub/grub.cfg" "$FLUFFY/boot/grub/grub.cfg"
fi
