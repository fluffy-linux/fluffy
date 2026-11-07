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
