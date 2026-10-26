#!/usr/bin/env bash
set -euo pipefail

FLUFFY=/mnt/fluffy

cleanup() {
    ret=$?
    trap - EXIT
    umount -v $FLUFFY/dev/shm || echo "Failed to umount $FLUFFY/dev/shm"
    umount -v $FLUFFY/run || echo "Failed to umount $FLUFFY/run"
    umount -v $FLUFFY/sys || echo "Failed to umount $FLUFFY/sys"
    umount -v $FLUFFY/proc || echo "Failed to umount $FLUFFY/proc"
    umount -v $FLUFFY/dev/pts || echo "Failed to umount $FLUFFY/dev/pts"
    umount -v $FLUFFY/etc/resolv.conf || echo "Failed to umount $FLUFFY/etc/resolv.conf"
    umount -lv $FLUFFY/dev || echo "Failed to umount $FLUFFY/dev"
    umount -v $FLUFFY/ || echo "Failed to umount $FLUFFY/"
    exit $ret
}

trap cleanup EXIT
mount $FLUFFY/
mount -v --bind /dev $FLUFFY/dev
mount -v --bind /etc/resolv.conf $FLUFFY/etc/resolv.conf
mount -vt devpts devpts -o gid=5,mode=0620 $FLUFFY/dev/pts
mount -vt proc proc $FLUFFY/proc
mount -vt sysfs sysfs $FLUFFY/sys
mount -vt tmpfs tmpfs $FLUFFY/run
if [ -h $FLUFFY/dev/shm ]; then
  install -v -d -m 1777 $FLUFFY$(realpath /dev/shm)
else
  mount -vt tmpfs -o nosuid,nodev tmpfs $FLUFFY/dev/shm
fi
chroot "$FLUFFY" /usr/bin/env -i            \
    HOME=/root                              \
    TERM="$TERM"                            \
    PS1='(fluffy chroot) \u:\w\$ '          \
    PATH=/usr/bin:/usr/sbin                 \
    MAKEFLAGS="-j$(($(nproc) - 1))"         \
    TESTSUITEFLAGS="-j$(($(nproc) - 1))"    \
    /bin/bash --login
