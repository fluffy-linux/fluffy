#!/usr/bin/env bash
set -euo pipefail

LFS=/mnt/lfs

cleanup() {
    ret=$?
    trap - EXIT
    umount -R $LFS/dev/pts || echo "Failed to umount $LFS/dev/pts"
    umount -R $LFS/proc || echo "Failed to umount $LFS/proc"
    umount -R $LFS/sys || echo "Failed to umount $LFS/sys"
    umount -R $LFS/run || echo "Failed to umount $LFS/run"
    umount -R $LFS/dev/shm || echo "Failed to umount $LFS/dev/shm"
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
