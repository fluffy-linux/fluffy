#!/usr/bin/env bash
# bench-fswc.sh -- FSWC Phase 0 benchmark driver (GLOB.md §6 Phase 0).
#
# Builds a synthetic multi-package prefix (never the host's /sw), then measures
# glob, execvpe PATH search, per-exec DT_NEEDED resolution, dlopen, cold index
# build, and optionally a make -j storm, in three FSWC states:
#   off   GLIBC_TUNABLES disables FSWC (the plain walk)
#   warm  FSWC enabled with a valid index already built
#   cold  FSWC enabled with the index directory removed before each process
#
# Usage: tools/bench-fswc.sh [options]
#   --cc CC            compiler for fixtures and the worker (default: cc)
#   --ldso PATH        run every measured program through this ld.so
#   --libpath DIRS     ':'-separated --library-path for --ldso (the glibc under test)
#   --pkgs N           packages in the synthetic prefix (default: 100)
#   --files N          filler files per package (default: 600)
#   --iters N          iterations per in-process glob sample (default: 2000)
#   --spawns N         spawns per exec sample (default: 200)
#   --squashfs         seal each package as a mounted SquashFS image (root only;
#                      runs inside a private mount namespace). Without it, FSWC
#                      sees no SquashFS and every state is the plain walk.
#   --index-dir DIR    FSWC index directory (default: /dev/shm/.fswc-$(id -u))
#   --storm            also time a 500-TU make -j build whose headers come from
#                      -I'<prefix>/*/include' (needs a compiler that expands it)
#   --label TEXT       label for the results header (e.g. "v5", "v6")
#   --out FILE         append results to FILE (default: stdout only)
#   --keep             keep the fixture directory
#
# Example (glibc build tree, unprivileged, plain walk only):
#   tools/bench-fswc.sh --ldso "$B/elf/ld.so" \
#       --libpath "$B:$B/math:$B/elf:$B/dlfcn:$B/nptl" --label v5
# Example (real SquashFS, v5 or v6 engaged):
#   sudo tools/bench-fswc.sh --squashfs --ldso ... --libpath ... --label v5

set -euo pipefail

cc=cc ldso='' libpath='' pkgs=100 files=600 iters=2000 spawns=200 squashfs=''
index_dir='' storm='' label=unlabeled out='' keep=''
inner=''
args=("$@")
while (( $# ))
do
    case "$1" in
        --cc) cc="$2"; shift ;;
        --ldso) ldso="$2"; shift ;;
        --libpath) libpath="$2"; shift ;;
        --pkgs) pkgs="$2"; shift ;;
        --files) files="$2"; shift ;;
        --iters) iters="$2"; shift ;;
        --spawns) spawns="$2"; shift ;;
        --squashfs) squashfs=1 ;;
        --index-dir) index_dir="$2"; shift ;;
        --storm) storm=1 ;;
        --label) label="$2"; shift ;;
        --out) out="$2"; shift ;;
        --keep) keep=1 ;;
        --inner) inner=1 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done
index_dir="${index_dir:-/dev/shm/.fswc-$(id -u)}"

if test -n "$squashfs" && test -z "$inner"
then
    if test "$(id -u)" != 0
    then
        echo "--squashfs needs root (loop mounts)" >&2
        exit 2
    fi
    exec unshare -m --propagation private "$0" "${args[@]}" --inner
fi

here="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/bench-fswc.XXXXXX")"
cleanup() {
    if test -n "$squashfs"
    then
        for p in "$work"/pfx/pkg*
        do
            umount "$p" 2>/dev/null || true
        done
    fi
    if test -z "$keep"
    then
        rm -rf "$work"
    else
        echo "fixture kept: $work" >&2
    fi
}
trap cleanup EXIT
pfx="$work/pfx"

say() {
    printf '%s\n' "$*"
    if test -n "$out"
    then
        printf '%s\n' "$*" >> "$out"
    fi
}

# --- Fixture -----------------------------------------------------------------
"$cc" -O2 -Wall -Wextra -o "$work/bench-fswc" "$here/bench-fswc.c" -ldl
printf 'int main (void) { return 0; }\n' > "$work/true.c"

last=$(( pkgs - 1 ))
for (( i = 0; i < pkgs; i++ ))
do
    p="$pfx/$(printf 'pkg%04d' "$i")"
    mkdir -p "$p"/{bin,lib,include,share/terminfo/x,lib/python3.14/site-packages,share/doc}
    for (( f = 0; f < files; f++ ))
    do
        case $(( f % 4 )) in
            0) : > "$p/include/f$f.h" ;;
            1) : > "$p/share/doc/f$f" ;;
            2) : > "$p/lib/libfill$f.a" ;;
            3) : > "$p/share/terminfo/x/xterm-f$f" ;;
        esac
    done
    mkdir -p "$p/lib/python3.14/site-packages/mod$i"
done
# Targets live in the last packages, so every lookup crosses the whole prefix.
if ! "$cc" -O2 -static -o "$pfx/$(printf 'pkg%04d' "$last")/bin/bench-true" "$work/true.c" 2>/dev/null
then
    "$cc" -O2 -o "$pfx/$(printf 'pkg%04d' "$last")/bin/bench-true" "$work/true.c"
fi
ldirs=()
for (( k = 1; k <= 15; k++ ))
do
    d="$pfx/$(printf 'pkg%04d' $(( pkgs - k )))/lib"
    printf 'int bf%d (void) { return %d; }\n' "$k" "$k" > "$work/bf$k.c"
    "$cc" -O2 -fPIC -shared -Wl,-soname,libbf$k.so -o "$d/libbf$k.so" "$work/bf$k.c"
    ldirs+=("-L$d")
done
for n in 1 7 15
do
    {
        for (( k = 1; k <= n; k++ ))
        do
            printf 'int bf%d (void);\n' "$k"
        done
        printf 'int main (void) { int s = 0;'
        for (( k = 1; k <= n; k++ ))
        do
            printf ' s += bf%d ();' "$k"
        done
        printf ' return s == 0; }\n'
    } > "$work/need$n.c"
    libs=()
    for (( k = 1; k <= n; k++ ))
    do
        libs+=("-lbf$k")
    done
    "$cc" -O2 -Wl,--no-as-needed -o "$pfx/pkg0000/bin/need$n" "$work/need$n.c" "${ldirs[@]}" "${libs[@]}"
done
for (( h = 0; h < 10; h++ ))
do
    printf '#define HDR_%d %d\n' "$h" "$h" > "$pfx/$(printf 'pkg%04d' $(( pkgs - 1 - h )))/include/hdr$h.h"
done

if test -n "$squashfs"
then
    mkdir -p "$work/img"
    for p in "$pfx"/pkg*
    do
        n="$(basename "$p")"
        mksquashfs "$p" "$work/img/$n.squashfs" -all-root -comp zstd -quiet -no-progress
        mount -t squashfs -o loop,ro "$work/img/$n.squashfs" "$p"
    done
fi

# --- Runners -------------------------------------------------------------------
run=()
if test -n "$ldso"
then
    run=("$ldso" --library-path "$libpath:$pfx/*/lib")
fi
off_tun='glibc.fswc.mode=0:glibc.fswc.enable=0'

state_env() {
    case "$1" in
        off) export GLIBC_TUNABLES="$off_tun" ;;
        warm|cold) unset GLIBC_TUNABLES ;;
    esac
    if test -z "$ldso"
    then
        export LD_LIBRARY_PATH="$pfx/*/lib"
    fi
}

drop_index() {
    rm -rf "$index_dir"
}

warm_index() {
    "${run[@]}" "$work/bench-fswc" glob "$pfx/*/bin/bench-true" 0 1 > /dev/null
    "${run[@]}" "$work/bench-fswc" first "${run[@]}" "$pfx/pkg0000/bin/need1" > /dev/null
}

median() {
    sort -n | awk '{ v[NR] = $1 } END { if (NR) print v[int((NR + 1) / 2)] }'
}

say "=== bench-fswc label=$label pkgs=$pkgs files/pkg=$files squashfs=${squashfs:-no} kernel=$(uname -r) date=$(date -u +%FT%TZ) ==="

globs=(
    "$pfx/*/bin/bench-true|0"
    "$pfx/*/bin/missing|0"
    "$pfx/*/{bin,include,lib}|$(( (1 << 10) | (1 << 13) ))"
    "$pfx/*/lib/python3.14/site-packages/*|0"
    "$pfx/*/share/terminfo/*/*|0"
)

for state in off warm cold
do
    state_env "$state"
    if test "$state" = warm
    then
        drop_index
        warm_index
    fi
    say "--- state=$state"
    for g in "${globs[@]}"
    do
        pat="${g%|*}"
        fl="${g##*|}"
        if test "$state" = cold
        then
            samples=()
            for (( r = 0; r < 15; r++ ))
            do
                drop_index
                samples+=("$("${run[@]}" "$work/bench-fswc" glob "$pat" "$fl" 1 | awk '{ print $3 }')")
            done
            say "glob ${pat#"$pfx"/} $(printf '%s\n' "${samples[@]}" | median) us/call (first call, cold, median of 15)"
        else
            say "$("${run[@]}" "$work/bench-fswc" glob "$pat" "$fl" "$iters" | sed "s|$pfx/||")"
        fi
    done
    for n in 1 7 15
    do
        if test "$state" = cold
        then
            samples=()
            for (( r = 0; r < 15; r++ ))
            do
                drop_index
                samples+=("$("${run[@]}" "$work/bench-fswc" first "${run[@]}" "$pfx/pkg0000/bin/need$n" | awk '{ print $3 }')")
            done
            say "exec need$n $(printf '%s\n' "${samples[@]}" | median) us/spawn (cold, median of 15)"
        else
            say "exec need$n $("${run[@]}" "$work/bench-fswc" spawn "$spawns" "${run[@]}" "$pfx/pkg0000/bin/need$n" | awk '{ print $3 }') us/spawn"
        fi
    done
    if test "$state" != cold
    then
        say "spawnp bench-true $("${run[@]}" "$work/bench-fswc" spawnp "$spawns" "$pfx/*/bin" bench-true | awk '{ print $3 }') us/spawn (PATH=<prefix>/*/bin)"
    fi
    samples=()
    for (( r = 0; r < 15; r++ ))
    do
        if test "$state" = cold
        then
            drop_index
        fi
        samples+=("$("${run[@]}" "$work/bench-fswc" dlopen libbf15.so | awk '{ print $3 }')")
    done
    say "dlopen libbf15.so $(printf '%s\n' "${samples[@]}" | median) us (median of 15 processes)"
done

# Cold build cost and index size (FSWC enabled).
state_env warm
drop_index
cold_us="$("${run[@]}" "$work/bench-fswc" first "${run[@]}" "$pfx/pkg0000/bin/need1" | awk '{ print $3 }')"
warm_us="$("${run[@]}" "$work/bench-fswc" first "${run[@]}" "$pfx/pkg0000/bin/need1" | awk '{ print $3 }')"
size="none"
if test -d "$index_dir"
then
    size="$(du -sb "$index_dir" | awk '{ print $1 }') bytes in $(find "$index_dir" -type f | wc -l) files"
fi
say "index first-process ${cold_us} us vs next ${warm_us} us; index ${size}"

if command -v strace > /dev/null
then
    for state in off warm
    do
        state_env "$state"
        if test "$state" = warm
        then
            warm_index
        fi
        strace -f -c -o "$work/strace.$state" "${run[@]}" "$pfx/pkg0000/bin/need15" > /dev/null 2>&1 || true
        total="$(awk '/^100.00/ { print $4 }' "$work/strace.$state")"
        say "syscalls exec need15 state=$state total=${total:-?}"
    done
fi

if test -n "$storm"
then
    mkdir -p "$work/storm"
    for (( t = 0; t < 500; t++ ))
    do
        {
            for (( h = 0; h < 10; h++ ))
            do
                printf '#include <hdr%d.h>\n' "$h"
            done
            printf 'int tu%d (void) { return HDR_0 + HDR_9; }\n' "$t"
        } > "$work/storm/tu$t.c"
    done
    printf 'SRCS := $(wildcard *.c)\nall: $(SRCS:.c=.o)\n%%.o: %%.c\n\t$(CC) -c -I'"'"'%s/*/include'"'"' $< -o $@\n' "$pfx" > "$work/storm/Makefile"
    for state in off warm
    do
        state_env "$state"
        if test "$state" = warm
        then
            warm_index
        fi
        rm -f "$work"/storm/*.o
        t0=$(date +%s%N)
        make -s -C "$work/storm" -j"$(nproc)" CC="$cc" > /dev/null
        t1=$(date +%s%N)
        say "storm 500 TUs state=$state $(( (t1 - t0) / 1000000 )) ms"
    done
fi
