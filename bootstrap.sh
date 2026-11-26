#!/usr/bin/env bash
set -euo pipefail

DIR="$(dirname "$(realpath "$0")")"
FLUFFY="${FLUFFY:-/mnt/fluffy}"

# Never interactive unless asked: a terminal on stdin does not mean a person
# is there (Buildkite runs commands in a pseudo-terminal).
set_root_password=0
for arg in "$@"
do
    case "$arg" in
        --root-password)
            set_root_password=1
            ;;
        *)
            echo "Usage: $0 [--root-password]" >&2
            exit 2
            ;;
    esac
done

# On Buildkite (every CI step runs this first), its output goes in a
# collapsed section of its own, and only when there is any: run again with
# the output captured, then print the section, opened if this failed.
if test "${BUILDKITE:-}" = true && test -z "${FLUFFY_BOOTSTRAP_CAPTURED:-}"
then
    rc=0
    out="$(FLUFFY_BOOTSTRAP_CAPTURED=1 "$0" "$@" 2>&1)" || rc=$?
    if test -n "$out"
    then
        echo "--- bootstrap"
        printf '%s\n' "$out"
    fi
    if test "$rc" != 0
    then
        echo "^^^ +++"
    fi
    exit "$rc"
fi

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

# Mount points for the virtual kernel file systems, as LFS makes them
# ("Preparing Virtual Kernel File Systems").  The root has to bring them:
# the kernel mounts it read-only, its devtmpfs automount needs /dev, and
# /init mounts devtmpfs, proc, sysfs and /run before it remounts /
# read-write, so it cannot make them itself.
mkdir -pv "$FLUFFY"/{dev,proc,sys,run}

if test ! -f "$FLUFFY/etc/machine-id"
then
    tr -d '-' < /proc/sys/kernel/random/uuid > "$FLUFFY/etc/machine-id"
fi

# glibc reads /etc/hosts, /etc/services and /etc/protocols at those paths.
# A root gets minimal copies, only where it has none: enough for localhost
# and the common services (libstdc++'s resolver tests look up
# localhost/http), and the same on a fresh CI root as on a local one.
if test ! -f "$FLUFFY/etc/hosts"
then
    cat << "HOSTS_EOF" > "$FLUFFY/etc/hosts"
127.0.0.1 localhost
::1 localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
HOSTS_EOF
fi

if test ! -f "$FLUFFY/etc/protocols"
then
    cat << "PROTOCOLS_EOF" > "$FLUFFY/etc/protocols"
ip      0       IP
icmp    1       ICMP
tcp     6       TCP
udp     17      UDP
ipv6    41      IPv6
PROTOCOLS_EOF
fi

if test ! -f "$FLUFFY/etc/services"
then
    cat << "SERVICES_EOF" > "$FLUFFY/etc/services"
echo            7/tcp
echo            7/udp
discard         9/tcp           sink null
discard         9/udp           sink null
daytime         13/tcp
daytime         13/udp
qotd            17/tcp          quote
chargen         19/tcp          ttytst source
chargen         19/udp          ttytst source
ftp-data        20/tcp
ftp             21/tcp
ssh             22/tcp
telnet          23/tcp
smtp            25/tcp          mail
time            37/tcp          timserver
time            37/udp          timserver
domain          53/tcp
domain          53/udp
http            80/tcp          www
http            80/udp
pop3            110/tcp         pop-3
sunrpc          111/tcp         portmapper
sunrpc          111/udp         portmapper
auth            113/tcp         ident
nntp            119/tcp         readnews
ntp             123/udp
imap            143/tcp         imap4
snmp            161/udp
https           443/tcp
https           443/udp
SERVICES_EOF
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

# root_mnt FIELD: FIELD of the file system mounted on $FLUFFY, one line: the
# topmost mount there, the one $FLUFFY shows.  findmnt can list more than
# one: under a shared bind mount of a directory on itself (CI's /mnt/ci),
# a mount below it is listed twice, and an over-mounted $FLUFFY lists the
# hidden file system first.
root_mnt() {
    findmnt -f -d backward -M "$FLUFFY" -no "$1" 2>/dev/null || true
}

root_uuid="$(root_mnt UUID)"
root_fstype="$(root_mnt FSTYPE)"
root_fsroot="$(root_mnt FSROOT)"
root_src="$(root_mnt SOURCE)"
root_dev="${root_src%%\[*}"
if test -z "$root_uuid" && test -n "$root_dev" && test -b "$root_dev"
then
    root_uuid="$(blkid -s UUID -o value "$root_dev" 2>/dev/null || true)"
fi

if test ! -f "$FLUFFY/etc/fstab"
then
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

# /init, from the init package: only when it changed, like the rest (CI
# runs this before every step).
if test -f "$FLUFFY/sw/init/bin/init"
then
    if ! cmp -s "$FLUFFY/sw/init/bin/init" "$FLUFFY/init"
    then
        cp -fv "$FLUFFY/sw/init/bin/init" "$FLUFFY/init"
    fi
    chmod 0755 "$FLUFFY/init"
else
    init_squashfs=$(ls "$FLUFFY"/sw/init-*.squashfs 2>/dev/null | head -n 1 || true)
    if test -n "$init_squashfs" && test -f "$init_squashfs" &&
        { test ! -f "$FLUFFY/init" || test "$init_squashfs" -nt "$FLUFFY/init"; }
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
    if test "$set_root_password" = 0
    then
        # A note for a person; a CI root never gets a password.
        if test "${BUILDKITE:-}" != true
        then
            echo "bootstrap: root has no password; run $0 --root-password to set one" >&2
        fi
    elif test -s "$FLUFFY/etc/fluffy/fstab" && grep -q '^/sw/shadow-[0-9]' "$FLUFFY/etc/fluffy/fstab"
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
    else
        echo "bootstrap: cannot set root's password yet: shadow is not built" >&2
    fi
fi

# grub_cfg FS_UUID PARTUUID FS_MODULE SUBVOL KERNEL_VERSION FONT: the root's
# grub.cfg, on stdout.  grub finds the root's file system by FS_UUID, loads
# FS_MODULE to read it, and loops the kernel back out of linux's image, in
# subvolume SUBVOL (none: "") or, failing that, the file system's own /sw;
# the kernel mounts the root by PARTUUID (there is no initramfs).  With
# FONT (1), a gfxterm in 4K with that font; without the font, grub's own
# text console.  No serial console: the boot test adds its own.
grub_cfg() {
    local fs_uuid="$1" partuuid="$2" fs_mod="$3" subvol="$4" kver="$5" font="$6"
    local img="sw/linux-$kver.squashfs" flags="" entry

    cat << EOF
set default=0
set timeout=5

insmod $fs_mod
insmod part_gpt

EOF
    if test "$font" = 1
    then
        cat << "EOF"
# Initialize graphical video drivers
set gfxmode=3840x2160x32,auto

insmod video
insmod font
insmod gfxterm
terminal_output gfxterm

# Load a larger font for the GRUB interface
font /boot/grub/fonts/djsans64.pf2

EOF
    fi
    cat << EOF
# DYNAMIC SEARCH: This finds the drive containing your LFS partition by its UUID
# and assigns it to the 'root' variable automatically, bypassing the need for "hd0".
search --no-floppy --fs-uuid --set=root $fs_uuid
EOF
    if test -n "$subvol"
    then
        flags=" rootflags=subvol=$subvol"
    fi
    for entry in "native root=PARTUUID=$partuuid" "libvirt root=/dev/sda1"
    do
        echo
        echo "menuentry \"Fluffy Linux $kver (${entry%% *})\" {"
        echo "    insmod loopback"
        echo "    insmod squash4"
        if test -n "$subvol"
        then
            echo "    if [ -f /$subvol/$img ]; then"
            echo "        loopback loop0 /$subvol/$img"
            echo "    else"
            echo "        loopback loop0 /$img"
            echo "    fi"
        else
            echo "    loopback loop0 /$img"
        fi
        echo "    linux (loop0)/boot/vmlinuz-$kver ${entry#* }$flags init=/init ro"
        echo "}"
    done
}

# /boot/grub/grub.cfg, written for this root: its file system, partition,
# subvolume and kernel.  Only for a root that can boot: once linux is built,
# on a partition, and the whole file system or a btrfs subvolume (not a
# CI root on a whole disk, nor a bind mount of a directory, like CI's
# /mnt/ci); only when it changed.
grub_note=""
grub_linux="$(awk '$2 == "/sw/linux" { print $1; exit }' "$FLUFFY/etc/fluffy/fstab" 2>/dev/null || true)"
grub_kver="${grub_linux#/sw/linux-}"
grub_kver="${grub_kver%.squashfs}"
grub_partuuid=""
if test -n "$root_dev" && test -b "$root_dev"
then
    grub_partuuid="$(blkid -s PARTUUID -o value "$root_dev" 2>/dev/null || true)"
fi
case "$root_fstype" in
    btrfs) grub_fs_mod=btrfs ;;
    ext2|ext3|ext4) grub_fs_mod=ext2 ;;
    xfs) grub_fs_mod=xfs ;;
    *) grub_fs_mod="" ;;
esac
grub_subvol=""
if test "$root_fstype" = btrfs && test -n "$root_fsroot" && test "$root_fsroot" != /
then
    grub_subvol="${root_fsroot#/}"
fi
grub_font=0
if test -f "$FLUFFY/boot/grub/fonts/djsans64.pf2"
then
    grub_font=1
fi
if test -z "$grub_linux" || test "$grub_kver" = "$grub_linux"
then
    grub_note="linux is not built"
elif test -z "$root_uuid" || test -z "$grub_partuuid"
then
    grub_note="the root's file system UUID or partition UUID is unknown"
elif test -z "$grub_fs_mod"
then
    grub_note="grub reads no ${root_fstype:-unknown} file system here"
elif test -z "$grub_subvol" && test -n "$root_fsroot" && test "$root_fsroot" != /
then
    grub_note="the root is a directory of its file system ($root_fsroot), which the kernel cannot mount as /"
else
    mkdir -pv "$FLUFFY/boot/grub"
    grub_cfg "$root_uuid" "$grub_partuuid" "$grub_fs_mod" "$grub_subvol" "$grub_kver" "$grub_font" \
        > "$FLUFFY/boot/grub/grub.cfg.new"
    if cmp -s "$FLUFFY/boot/grub/grub.cfg.new" "$FLUFFY/boot/grub/grub.cfg"
    then
        rm -f "$FLUFFY/boot/grub/grub.cfg.new"
    else
        # The grub.cfg it replaces is kept, as grub.cfg.old: a machine that
        # booted with it can be put back if the new one doesn't boot.
        if test -f "$FLUFFY/boot/grub/grub.cfg"
        then
            cp -fv "$FLUFFY/boot/grub/grub.cfg" "$FLUFFY/boot/grub/grub.cfg.old"
            if test "${BUILDKITE:-}" != true
            then
                echo "bootstrap: /boot/grub/grub.cfg changed; the previous one is grub.cfg.old (diff them before rebooting)" >&2
            fi
        fi
        mv -fv "$FLUFFY/boot/grub/grub.cfg.new" "$FLUFFY/boot/grub/grub.cfg"
    fi
fi
if test -n "$grub_note" && test "${BUILDKITE:-}" != true
then
    echo "bootstrap: no /boot/grub/grub.cfg written: $grub_note" >&2
fi
