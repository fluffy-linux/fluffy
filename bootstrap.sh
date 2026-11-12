#!/usr/bin/env bash
set -euo pipefail

DIR="$(dirname "$(realpath "$0")")"
FLUFFY=/mnt/fluffy

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

touch "$FLUFFY/etc/passwd"
while IFS= read -r entry
do
    test -n "$entry" || continue
    user="${entry%%:*}"
    if ! grep -q "^${user}:" "$FLUFFY/etc/passwd"
    then
        echo "$entry" >> "$FLUFFY/etc/passwd"
    fi
done << "PW_EOF"
root:x:0:0:root:/root:/sw/bash/bin/bash
bin:x:1:1:bin:/dev/null:/sw/coreutils/bin/false
daemon:x:6:6:Daemon User:/dev/null:/sw/coreutils/bin/false
messagebus:x:18:18:D-Bus Message Daemon User:/run/dbus:/sw/coreutils/bin/false
systemd-journal-gateway:x:73:73:systemd Journal Gateway:/:/sw/coreutils/bin/false
systemd-journal-remote:x:74:74:systemd Journal Remote:/:/sw/coreutils/bin/false
systemd-journal-upload:x:75:75:systemd Journal Upload:/:/sw/coreutils/bin/false
systemd-network:x:76:76:systemd Network Management:/:/sw/coreutils/bin/false
systemd-resolve:x:77:77:systemd Resolver:/:/sw/coreutils/bin/false
systemd-timesync:x:78:78:systemd Time Synchronization:/:/sw/coreutils/bin/false
systemd-coredump:x:79:79:systemd Core Dumper:/:/sw/coreutils/bin/false
uuidd:x:80:80:UUID Generation Daemon User:/dev/null:/sw/coreutils/bin/false
systemd-oom:x:81:81:systemd Out Of Memory Daemon:/:/sw/coreutils/bin/false
builder:x:1000:1000::/home/builder:/sw/bash/bin/bash
nobody:x:65534:65534:Unprivileged User:/dev/null:/sw/coreutils/bin/false
PW_EOF

touch "$FLUFFY/etc/group"
while IFS= read -r entry
do
    test -n "$entry" || continue
    grp="${entry%%:*}"
    if ! grep -q "^${grp}:" "$FLUFFY/etc/group"
    then
        echo "$entry" >> "$FLUFFY/etc/group"
    fi
done << "GRP_EOF"
root:x:0:
bin:x:1:
sys:x:2:
kmem:x:3:
tape:x:4:
tty:x:5:
daemon:x:6:
floppy:x:7:
disk:x:8:
lp:x:9:
dialout:x:10:
audio:x:11:
video:x:12:
utmp:x:13:
usb:x:14:
cdrom:x:15:
adm:x:16:
clock:x:17:
messagebus:x:18:
systemd-journal:x:23:
input:x:24:
mail:x:34:
kvm:x:61:
systemd-journal-gateway:x:73:
systemd-journal-remote:x:74:
systemd-journal-upload:x:75:
systemd-network:x:76:
systemd-resolve:x:77:
systemd-timesync:x:78:
systemd-coredump:x:79:
uuidd:x:80:
systemd-oom:x:81:
wheel:x:97:
users:x:999:
builder:x:1000:
nogroup:x:65534:
GRP_EOF

touch "$FLUFFY/etc/shadow"
chmod 0600 "$FLUFFY/etc/shadow"
while IFS=: read -r user _
do
    test -n "$user" || continue
    if ! grep -q "^${user}:" "$FLUFFY/etc/shadow"
    then
        echo "${user}:!:20000:0:99999:7:::" >> "$FLUFFY/etc/shadow"
    fi
done < "$FLUFFY/etc/passwd"

if test ! -f "$FLUFFY/etc/machine-id"
then
    tr -d '-' < /proc/sys/kernel/random/uuid > "$FLUFFY/etc/machine-id"
fi

if test ! -f "$FLUFFY/etc/os-release"
then
    cat << "OS_EOF" > "$FLUFFY/etc/os-release"
NAME="Fluffy Linux"
ID=fluffy
PRETTY_NAME="Fluffy Linux"
OS_EOF
fi

if test ! -f "$FLUFFY/etc/hosts"
then
    cat << "HOSTS_EOF" > "$FLUFFY/etc/hosts"
127.0.0.1 localhost
::1 localhost
HOSTS_EOF
fi

if test ! -f "$FLUFFY/etc/nsswitch.conf"
then
    cat << "NSS_EOF" > "$FLUFFY/etc/nsswitch.conf"
passwd: files
group: files
shadow: files

hosts: files dns
networks: files

protocols: files
services: files
ethers: files
rpc: files
NSS_EOF
fi

if test ! -f "$FLUFFY/etc/protocols"
then
    if test -f "$FLUFFY/sw/iana-etc/etc/protocols"
    then
        cp -v "$FLUFFY/sw/iana-etc/etc/protocols" "$FLUFFY/etc/protocols"
    else
        cat << "PROTO_EOF" > "$FLUFFY/etc/protocols"
ip      0       IP
icmp    1       ICMP
tcp     6       TCP
udp     17      UDP
ipv6    41      IPv6
PROTO_EOF
    fi
fi

if test ! -f "$FLUFFY/etc/services"
then
    if test -f "$FLUFFY/sw/iana-etc/etc/services"
    then
        cp -v "$FLUFFY/sw/iana-etc/etc/services" "$FLUFFY/etc/services"
    else
        cat << "SERV_EOF" > "$FLUFFY/etc/services"
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
SERV_EOF
    fi
fi

if test ! -f "$FLUFFY/etc/fstab"
then
    root_uuid="$(findmnt -no UUID "$FLUFFY")"
    root_fstype="$(findmnt -no FSTYPE "$FLUFFY")"
    root_fsroot="$(findmnt -no FSROOT "$FLUFFY")"
    if test "$root_fstype" = "btrfs" && test "$root_fsroot" != "/"
    then
        root_opts="subvol=${root_fsroot#/},defaults"
    else
        root_opts="defaults"
    fi
    echo "UUID=$root_uuid / $root_fstype $root_opts 0 0" > "$FLUFFY/etc/fstab"
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
    cp -fv "$FLUFFY/sw/.build/fstab" "$FLUFFY/etc/fluffy/fstab"
fi

if test -f "$DIR/boot/grub/grub.cfg"
then
    mkdir -pv "$FLUFFY/boot/grub"
    cp -fv "$DIR/boot/grub/grub.cfg" "$FLUFFY/boot/grub/grub.cfg"
fi
