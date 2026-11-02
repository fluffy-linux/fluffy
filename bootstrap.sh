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
mkdir -pv "$FLUFFY/sw/.build/keys"
chmod 0700 "$FLUFFY/sw/.build/keys"
mkdir -pv "$FLUFFY/work"
mkdir -pv "$FLUFFY/etc"

if test ! -f "$FLUFFY/etc/passwd"
then
    cat << "PW_EOF" > "$FLUFFY/etc/passwd"
root:x:0:0:root:/root:/sw/bash/bin/bash
builder:x:1000:1000::/home/builder:/sw/bash/bin/bash
nobody:x:65534:65534:Nobody:/:/sw/coreutils/bin/false
PW_EOF
fi

if test ! -f "$FLUFFY/etc/group"
then
    cat << "GRP_EOF" > "$FLUFFY/etc/group"
root:x:0:
tty:x:5:
disk:x:8:
dialout:x:10:
audio:x:11:
video:x:12:
usb:x:14:
cdrom:x:15:
adm:x:16:
builder:x:1000:
nogroup:x:65534:
GRP_EOF
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
