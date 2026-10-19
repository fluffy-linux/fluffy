#!/usr/bin/env bash
set -euo pipefail

LFS=/mnt/lfs

cleanup() {
    ret=$?
    trap - EXIT
    umount -v $LFS/dev/shm || echo "Failed to umount $LFS/dev/shm"
    umount -v $LFS/run || echo "Failed to umount $LFS/run"
    umount -v $LFS/sys || echo "Failed to umount $LFS/sys"
    umount -v $LFS/proc || echo "Failed to umount $LFS/proc"
    umount -v $LFS/dev/pts || echo "Failed to umount $LFS/dev/pts"
    umount -lv $LFS/dev || echo "Failed to umount $LFS/dev"
    exit $ret
}

trap cleanup EXIT

mount -v --bind /dev $LFS/dev
mount -vt devpts devpts -o gid=5,mode=0620 $LFS/dev/pts
mount -vt proc proc $LFS/proc
mount -vt sysfs sysfs $LFS/sys
mount -vt tmpfs tmpfs $LFS/run
if [ -h $LFS/dev/shm ]; then
  install -v -d -m 1777 $LFS$(realpath /dev/shm)
else
  mount -vt tmpfs -o nosuid,nodev tmpfs $LFS/dev/shm
fi
chroot "$LFS" /usr/bin/env -i               \
    HOME=/root                              \
    TERM="$TERM"                            \
    PS1='(lfs chroot) \u:\w\$ '             \
    PATH=/usr/bin:/usr/sbin                 \
    MAKEFLAGS="-j$(($(nproc) - 1))"         \
    TESTSUITEFLAGS="-j$(($(nproc) - 1))"    \
    /bin/bash --login
