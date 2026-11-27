#!/usr/bin/env bash
# boot-test.sh: install a built Fluffy root on a fresh disk image and boot
# it under QEMU/KVM; it passes when a getty's "login:" prompt reaches the
# serial console.
#
# Usage: sudo FLUFFY=/mnt/ci CROSS=1 ./boot-test.sh [options]
#
# Options (each also settable by the environment variable in capitals):
#   --timeout N   hard limit, in seconds, from QEMU's start to "login:"
#                 (TIMEOUT, default 180): QEMU runs under timeout(1), is
#                 killed when it expires, and the test fails
#   --out DIR     where the image, the logs and the serial console's log
#                 go (OUT, default ./boot-test)
#   --keep        keep the image after a pass (KEEP=1; it is always kept
#                 after a failure)
#
# Environment:
#   FLUFFY        the Fluffy root that `swctl build world` built
#   CROSS         as for that build: swctl's recipe checksums depend on
#                 it, and `swctl run grub` must find grub up to date
#   SIZE          the image's size (default 5G)
#   MEM, SMP      the guest's memory in MiB (default 2048) and CPUs (2)
#   SERIAL_TAIL   how many of the serial log's last lines to print (30)
#   ANALYZE_WAIT  after login:, how long to wait for the guest's
#                 systemd-analyze report (default 60 s)
#
# Outputs, in OUT: serial.log (the console), report.log (the guest's
# systemd-analyze report, on its second serial port), boot-analyze.txt (systemd-analyze time,
# critical-chain and blame), boot-plot.svg (systemd-analyze plot), and
# annotation.md with annotation-style, a Buildkite annotation of them.
#
# The image is what an install would make: GPT with a BIOS boot partition
# and a btrfs root whose subvolume @ is the Fluffy root, holding the
# packages' images; bootstrap.sh prepares the rest (/etc/fstab, /init,
# /boot/grub/grub.cfg...), and Fluffy's grub is installed with `swctl run
# grub grub-install`.  The test only adds a serial console to grub.cfg:
# grub's terminal, and console=ttyS0 for the kernel, so systemd's getty
# generator starts a getty there.  The firmware is QEMU's own (SeaBIOS).
#
# Exit status: 0 when "login:" appeared in time; 1 otherwise (no login:
# within the timeout, QEMU exited, a kernel panic, a dead /init, grub found
# nothing to boot, or a step before the boot failed).  QEMU is killed, and
# the loop device and the mounts are released, however it ends.
#
# Needs: root (through sudo, for swctl), /dev/kvm, qemu-system-x86_64,
# timeout, sgdisk, losetup, mkfs.btrfs, btrfs, unsquashfs, unshare.
set -euo pipefail

die() { echo "boot-test: $*" >&2; exit 1; }
say() { echo "boot-test: $*" >&2; }
usage() { sed -n '6,23p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

while test $# -gt 0
do
    case "$1" in
        --timeout) TIMEOUT="${2:?}"; shift 2 ;;
        --timeout=*) TIMEOUT="${1#*=}"; shift ;;
        --out) OUT="${2:?}"; shift 2 ;;
        --out=*) OUT="${1#*=}"; shift ;;
        --keep) KEEP=1; shift ;;
        -h|--help) usage ;;
        *) echo "boot-test: unknown argument: $1" >&2; usage ;;
    esac
done
TIMEOUT="${TIMEOUT:-180}"
OUT="${OUT:-$PWD/boot-test}"
KEEP="${KEEP:-0}"
ANALYZE_WAIT="${ANALYZE_WAIT:-60}"
export TIMEOUT OUT KEEP ANALYZE_WAIT

test "$(id -u)" = 0 || die "must run as root (sudo)"

# Every mount in a mount namespace of its own: none propagates into the
# host's, and all go away with this script however it ends.
if test -z "${BOOT_TEST_UNSHARED:-}"
then
    BOOT_TEST_UNSHARED=1 exec unshare -m --propagation private "$0"
fi

FLUFFY="$(realpath "${FLUFFY:?set FLUFFY to the built Fluffy root}")"
REPO="$(dirname "$(realpath "$0")")"
OUT="$(realpath -m "$OUT")"
SIZE="${SIZE:-5G}"
MEM="${MEM:-2048}"
SMP="${SMP:-2}"
SERIAL_TAIL="${SERIAL_TAIL:-30}"
[[ "$TIMEOUT" =~ ^[1-9][0-9]*$ ]] || die "--timeout must be a whole number of seconds, not $TIMEOUT"

test -x "$REPO/swctl" && test -x "$REPO/bootstrap.sh" || die "$REPO has no swctl and bootstrap.sh"
test -s "$FLUFFY/sw/.build/fstab" || die "$FLUFFY has no built world ($FLUFFY/sw/.build/fstab)"
test -c /dev/kvm || die "no /dev/kvm"

# On Buildkite, each part's output in a collapsed section of its own.
section() {
    if test "${BUILDKITE:-}" = true
    then
        echo "--- $1"
    fi
}

mkdir -p "$OUT"
IMG="$OUT/disk.img"
LOG="$OUT/serial.log"
REPORT="$OUT/report.log"
rm -f "$IMG" "$LOG" "$REPORT"

LOOP="" MNT="" MADE_MNT="" QEMU_PID=""
cleanup() {
    local rc=$?
    set +e
    # QEMU_PID is timeout(1)'s, which passes the TERM on to QEMU, and
    # kills QEMU if it has not gone 5 s later.
    if test -n "$QEMU_PID" && kill -0 "$QEMU_PID" 2>/dev/null
    then
        kill "$QEMU_PID"
        wait "$QEMU_PID" 2>/dev/null
    fi
    if test -n "$MNT"
    then
        mountpoint -q "$MNT" && umount "$MNT"
        rmdir "$MNT"
    fi
    test -z "$MADE_MNT" || rmdir "$FLUFFY/mnt"
    test -z "$LOOP" || losetup -d "$LOOP"
    # The output belongs to whoever ran sudo (on CI, the agent, which
    # uploads it and cleans the checkout).
    if test -n "${SUDO_UID:-}" && test -n "${SUDO_GID:-}"
    then
        chown -R "$SUDO_UID:$SUDO_GID" "$OUT" 2>/dev/null
    fi
    if test "$rc" != 0 && test "${BUILDKITE:-}" = true
    then
        echo "^^^ +++"
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

section "image"

# The test's grub.cfg is a fixed file, boot/grub/grub-ci.cfg (bootstrap.sh
# copies the user's machine's): the image is made with the IDs it names,
# the root's btrfs UUID and its partition's PARTUUID, and it must name
# world's kernel.
ci_cfg="$REPO/boot/grub/grub-ci.cfg"
test -f "$ci_cfg" || die "$ci_cfg is missing"
fs_uuid="$(awk '$1 == "search" { print $NF; exit }' "$ci_cfg")"
part_uuid="$(sed -nE 's/.* root=PARTUUID=([0-9a-f-]+).*/\1/p' "$ci_cfg" | head -n1)"
test -n "$fs_uuid" && test -n "$part_uuid" || die "$ci_cfg names no file system UUID or PARTUUID"
linux_img="$(awk '$2 == "/sw/linux" { print $1; exit }' "$FLUFFY/sw/.build/fstab" 2>/dev/null || true)"
grep -qF "loopback loop0 /@$linux_img" "$ci_cfg" \
    || die "$ci_cfg doesn't boot world's kernel (${linux_img:-none in the fstab of $FLUFFY}); update it"

# GPT: a BIOS boot partition, where grub's i386-pc core goes, and the root.
truncate -s "$SIZE" "$IMG"
sgdisk -o \
    -n 1:0:+1M -t 1:ef02 -c 1:bios \
    -n 2:0:0   -t 2:8304 -c 2:fluffy -u "2:$part_uuid" \
    "$IMG" > /dev/null
LOOP="$(losetup -f --show -P "$IMG")"
udevadm settle 2>/dev/null || true
for _ in $(seq 50)
do
    test -b "${LOOP}p2" && break
    sleep 0.1
done
test -b "${LOOP}p2" || die "${LOOP}p2 did not appear"
mkfs.btrfs -q -f -L fluffy -U "$fs_uuid" "${LOOP}p2"

# The image's root is mounted inside the Fluffy root, where `swctl run`
# (which chroots into $FLUFFY) can reach it.
if test ! -d "$FLUFFY/mnt"
then
    mkdir "$FLUFFY/mnt"
    MADE_MNT=1
fi
MNT="$(mktemp -d "$FLUFFY/mnt/boot-test.XXXXXX")"
mount "${LOOP}p2" "$MNT"
btrfs -q subvolume create "$MNT/@"
umount "$MNT"
mount -o subvol=@ "${LOOP}p2" "$MNT"

# The packages' images that a running system mounts (no -passN builds, no
# cross- or host-build environments) and swctl's fstab of them; then
# bootstrap.sh makes the rest of the root.
mkdir -p "$MNT/sw/.build"
for img in "$FLUFFY"/sw/*.squashfs
do
    case "${img##*/}" in
        *-pass[0-9]*-*.squashfs|cross-build-*|host-build-*) continue ;;
    esac
    cp --reflink=auto "$img" "$MNT/sw/"
done
cp "$FLUFFY/sw/.build/fstab" "$MNT/sw/.build/fstab"
(cd "$REPO" && env -u BUILDKITE FLUFFY="$MNT" ./bootstrap.sh) > "$OUT/bootstrap.log" 2>&1 \
    || { cat "$OUT/bootstrap.log" >&2; die "bootstrap.sh failed on the image"; }
cfg="$MNT/boot/grub/grub.cfg"
while read -r src _
do
    test -f "$MNT$src" || die "/etc/fluffy/fstab names $src, which the image lacks"
done < "$MNT/etc/fluffy/fstab"
mkdir -p "$MNT/boot/grub"
test ! -f "$cfg" || cp "$cfg" "$OUT/grub.cfg.bootstrap"
cp "$ci_cfg" "$cfg"
cp "$cfg" "$OUT/grub.cfg"

say "installing Fluffy's grub on $LOOP"
(cd "$REPO" && env -u BUILDKITE FLUFFY="$FLUFFY" ./swctl run grub \
    grub-install --target=i386-pc --boot-directory="${MNT#"$FLUFFY"}/boot" "$LOOP") \
    > "$OUT/grub-install.log" 2>&1 \
    || { cat "$OUT/grub-install.log" >&2; die "grub-install failed"; }

# The boot's own measurements, from systemd-analyze, once boot has
# finished: on a second serial port between markers, the plot (an SVG
# timeline) gzipped and in base64.  The host stops the guest once it has
# both login: and the report.  Only in this throwaway image.  Type=exec, so the unit is up at once and doesn't hold
# up the boot it waits for.
cat > "$MNT/etc/boot-test-analyze" << "EOF"
#!/sw/bash/bin/bash
export PATH='/sw/*/bin' SYSTEMD_COLORS=0 SYSTEMD_PAGER=cat TERM=dumb
systemctl is-system-running --wait > /dev/null 2>&1
# On the second serial port, ttyS1 (QEMU writes it to report.log): the
# getty owns the console's, ttyS0, and hangs it up when it starts.  Through
# a pipe, not straight to the tty: on a terminal, systemd's tools query it
# (cursor position, OSC context) and wait for answers that never come.
{
    echo "@@boot-test-analyze-begin@@"
    echo "state: $(systemctl is-system-running)"
    systemd-analyze time
    echo
    systemd-analyze critical-chain
    echo
    systemd-analyze blame | head -n 40
    echo "@@boot-test-analyze-end@@"
    echo "@@boot-test-plot-begin@@"
    systemd-analyze plot | gzip -9 | base64
    echo "@@boot-test-plot-end@@"
} 2>&1 | cat > /dev/ttyS1
EOF
chmod 755 "$MNT/etc/boot-test-analyze"
mkdir -p "$MNT/etc/systemd/system/multi-user.target.wants"
cat > "$MNT/etc/systemd/system/boot-test-analyze.service" << "EOF"
[Unit]
Description=boot-test: systemd-analyze on the serial console
After=multi-user.target

[Service]
Type=exec
ExecStart=/etc/boot-test-analyze

[Install]
WantedBy=multi-user.target
EOF
ln -sf ../boot-test-analyze.service "$MNT/etc/systemd/system/multi-user.target.wants/boot-test-analyze.service"

# Everything on the disk before QEMU opens it.
umount "$MNT"
rmdir "$MNT"
MNT=""
if test -n "$MADE_MNT"
then
    rmdir "$FLUFFY/mnt"
    MADE_MNT=""
fi
losetup -d "$LOOP"
LOOP=""

section "boot"
say "booting, the serial console in $LOG, for up to ${TIMEOUT}s"
start="$(date +%s.%N)"
# QEMU runs under timeout(1): the hard limit, whatever happens here.
timeout --kill-after=5 "$TIMEOUT" \
    qemu-system-x86_64 -enable-kvm -machine q35 -cpu host -smp "$SMP" -m "$MEM" \
    -drive "file=$IMG,format=raw,if=virtio" \
    -nic none -no-reboot \
    -nographic -monitor none -serial "file:$LOG" -serial "file:$REPORT" \
    < /dev/null > "$OUT/qemu.log" 2>&1 &
QEMU_PID=$!

result="" qemu_rc=""
while test -z "$result"
do
    if grep -aq 'login:' "$LOG" 2>/dev/null
    then
        result=pass
    elif grep -aqE 'Kernel panic|init: FATAL: emergency shell failed|Failed to boot both default and fallback' "$LOG" 2>/dev/null
    then
        # Dead ends that never reach a getty: fail now, not at the timeout.
        result=stuck
    elif ! kill -0 "$QEMU_PID" 2>/dev/null
    then
        qemu_rc=0
        wait "$QEMU_PID" || qemu_rc=$?
        QEMU_PID=""
        # timeout(1): 124 when it expired (QEMU took the TERM), 137 when
        # it had to kill QEMU.
        case "$qemu_rc" in
            124|137) result=timeout ;;
            *) result=exited ;;
        esac
        # QEMU may have written the prompt just before it went.
        if grep -aq 'login:' "$LOG" 2>/dev/null
        then
            result=pass
        fi
    else
        sleep 0.2
    fi
done
elapsed="$(awk -v a="$start" -v b="$(date +%s.%N)" 'BEGIN { printf "%.1f", b - a }')"
# After login:, wait for the guest's systemd-analyze report, up to
# ANALYZE_WAIT seconds, but not past QEMU's hard limit; then stop QEMU.
if test "$result" = pass && test -n "$QEMU_PID"
then
    for _ in $(seq $(( ANALYZE_WAIT * 5 )))
    do
        grep -aq '@@boot-test-plot-end@@' "$REPORT" 2>/dev/null && break
        kill -0 "$QEMU_PID" 2>/dev/null || break
        sleep 0.2
    done
fi
if test -n "$QEMU_PID"
then
    kill "$QEMU_PID" 2>/dev/null || true
    wait "$QEMU_PID" 2>/dev/null || true
    QEMU_PID=""
fi

# The log without terminal control sequences and carriage returns.
clean_log() {
    sed 's/\x1b\[[0-9;?!]*[A-Za-z]//g; s/\x1b\][^\x07\x1b]*\(\x07\|\x1b\\\)//g; s/\x1bP[^\x1b]*\x1b\\//g; s/\x1b[78]//g; s/\r//g' "$LOG" 2>/dev/null
}
# systemd-analyze's report and plot, when the guest sent them.
analyze="$OUT/boot-analyze.txt" plot="$OUT/boot-plot.svg"
rm -f "$analyze" "$plot"
tr -d '\r' < "$REPORT" 2>/dev/null | sed -n '/@@boot-test-analyze-begin@@/,/@@boot-test-analyze-end@@/{//!p}' > "$analyze"
test -s "$analyze" || rm -f "$analyze"
tr -d '\r' < "$REPORT" 2>/dev/null | sed -n '/@@boot-test-plot-begin@@/,/@@boot-test-plot-end@@/{//!p}' | base64 -d 2>/dev/null | gunzip > "$plot" 2>/dev/null || true
test -s "$plot" || rm -f "$plot"

# The log's tail, without the report's blocks.
echo "----- the last $SERIAL_TAIL lines of $LOG"
clean_log | sed '/@@boot-test-analyze-begin@@/,/@@boot-test-plot-end@@/d' | tail -n "$SERIAL_TAIL"
echo
echo "-----"
if test -f "$analyze"
then
    cat "$analyze"
    echo "-----"
else
    echo "boot-test: no systemd-analyze report from the guest (the test still judges by login:)"
fi

# A Buildkite annotation (annotation.md, its style in annotation-style),
# which the pipeline's step posts: the result, systemd-analyze's times, the
# plot from the step's artifacts, and the critical chain.
write_annotation() {
    local style="$1" title="$2"
    {
        echo "#### Boot test: $title"
        if test -f "$analyze"
        then
            echo
            echo '```'
            sed -n '/^state:/,/^$/p' "$analyze" | sed '/^$/d'
            echo '```'
        fi
        if test -f "$plot"
        then
            echo
            echo '<img src="artifact://boot-test/boot-plot.svg" alt="systemd-analyze plot of the boot">'
        fi
        if test -f "$analyze"
        then
            echo
            echo '<details><summary>Critical chain and slowest units</summary>'
            echo
            echo '```'
            sed '1,/^$/d' "$analyze"
            echo '```'
            echo '</details>'
        fi
        if test "$style" = error
        then
            echo
            echo '<details><summary>The serial console'"'"'s last lines</summary>'
            echo
            echo '```'
            clean_log | sed '/@@boot-test-analyze-begin@@/,/@@boot-test-plot-end@@/d' | tail -n "$SERIAL_TAIL"
            echo '```'
            echo '</details>'
        fi
    } > "$OUT/annotation.md"
    echo "$style" > "$OUT/annotation-style"
}
case "$result" in
    pass)
        echo "boot-test: PASS: login: after ${elapsed}s"
        write_annotation success "\`login:\` after ${elapsed} s"
        test "$KEEP" = 1 || rm -f "$IMG"
        ;;
    timeout)
        echo "boot-test: FAIL: no login: within ${TIMEOUT}s; QEMU killed" >&2
        write_annotation error "FAIL, no \`login:\` within ${TIMEOUT} s"
        exit 1
        ;;
    exited)
        cat "$OUT/qemu.log" >&2
        echo "boot-test: FAIL: QEMU exited (status $qemu_rc) after ${elapsed}s, with no login: prompt" >&2
        write_annotation error "FAIL, QEMU exited (status $qemu_rc) after ${elapsed} s with no \`login:\`"
        exit 1
        ;;
    stuck)
        echo "boot-test: FAIL: the boot came to a dead end after ${elapsed}s (see the serial log above)" >&2
        write_annotation error "FAIL, a dead end after ${elapsed} s"
        exit 1
        ;;
esac
