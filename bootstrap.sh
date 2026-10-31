#!/usr/bin/env bash
set -euo pipefail

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
mkdir -pv "$FLUFFY/sw"
mkdir -pv "$FLUFFY/work"
mkdir -pv "$FLUFFY/etc"
mkdir -pv "$FLUFFY/etc/fluffy"
mkdir -pv "$FLUFFY/etc/fluffy/keys"
chmod 0700 "$FLUFFY/etc/fluffy/keys"

if test ! -f "$FLUFFY/etc/passwd"
then
    cat << "PW_EOF" > "$FLUFFY/etc/passwd"
root:x:0:0:root:/root:/sw/bash/bin/bash
bin:x:1:1:bin:/dev/null:/bin/false
builder:x:1000:1000::/home/builder:/sw/bash/bin/bash
nobody:x:65534:65534:Nobody:/:/bin/false
PW_EOF
fi

if ! grep -q "^builder:" "$FLUFFY/etc/passwd"
then
    echo "builder:x:1000:1000::/home/builder:/sw/bash/bin/bash" >> "$FLUFFY/etc/passwd"
fi

if test ! -f "$FLUFFY/etc/group"
then
    cat << "GRP_EOF" > "$FLUFFY/etc/group"
root:x:0:
bin:x:1:daemon
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
builder:x:1000:
nogroup:x:65534:
GRP_EOF
fi

if ! grep -q "^builder:" "$FLUFFY/etc/group"
then
    echo "builder:x:1000:" >> "$FLUFFY/etc/group"
fi
