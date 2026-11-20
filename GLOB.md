# Fluffy Linux Globbing & `FSWC` Design and Implementation Plan

This document is the authoritative specification and phased execution plan for universal wildcard path resolution (`<glob.h>`, `<fnmatch.h>`, `GLOB_PATHS`), language runtime glob delegation, and the internal `glibc` Fluffy SquashFS Wildcard Cache (`FSWC`). It supersedes the prototype notes previously kept in [NOTES.md](NOTES.md).

**Revision note (`FSWC` v6).** Earlier revisions of this document specified `FSWC` v5: a cache built inside `ld.so` and `libc` by whichever process needed it, revalidated by hashing the entire mount tree on every call, plus an opt-in mode in which `open`/`stat`/`access` answered `ENOENT` from the cache on the kernel's behalf. v6 reduces `FSWC` to a single existence-lookup primitive over a sorted snapshot of the packages, fed into `glob()` through its existing `GLOB_ALTDIRFUNC` hooks, built only at program startup, and validated with 2–3 syscalls. §2 records every earlier design, why each failed, and the decisions behind v6; §4 is the new design; §4.7 maps v5 code to keep/change/delete; §4.9 lists open questions.

---

## 1. Architectural Vision & Non-Negotiable Principles

In a traditional FHS distribution, packages pour files into mutable shared directories (`/usr/bin`, `/usr/lib`, `/usr/include`, `/etc`), then paper over the resulting lookup and collision problems with subsystem-specific caches and generators (`ldconfig` / `/etc/ld.so.cache`, `pkg-config`, `update-ca-certificates`, symlink farms, post-install triggers).

Fluffy Linux mounts each package as an independent, read-only SquashFS image at `/sw/<pkg>` with zero symlink farms and zero install hooks. Consequently, **every** subsystem shares the exact same discovery primitive: lexicographically ordered wildcard expansion over `/sw/*/...` (combined with ordered colon-delimited search paths such as `/sw/.build/*/bin:/sw/*/bin` or `/sw/*/etc/foo.conf:/etc/foo.conf`).

Fluffy elevates POSIX `<glob.h>` and `<fnmatch.h>` in `glibc` into the **single universal lookup primitive**. `FSWC` is a private `glibc` accelerator for that primitive: a per-user, per-mount-namespace index of the immutable `/sw/*` trees that lets wildcard lookups skip packages that cannot match, without ever changing an answer.

### Non-Negotiable Design Rules

1. **The kernel is the authority; the plain walk is the specification.**
   - The *plain walk* is: `getdents64(<prefix>)`, drop leading-dot names (and, for search lists, entries that are not directories or symlinks to directories), sort (byte order for search lists, §3.2; the caller's collation for `glob()` patterns), then probe `<prefix>/<name>/<relpath>` in order (first match wins for search paths; all matches for merges). This is exactly what a program that never calls `glibc`—Go (`os.ReadDir` + sort + `os.Stat`), Rust, raw `SYSCALL`s—observes.
   - Go and other non-`glibc` walkers sort by bytes, so they are an exact oracle only under `C`/`POSIX` collation; under other locales the reference is the plain walk sorted with the caller's collation.
   - Every `FSWC`-accelerated answer **must** be identical to the plain walk evaluated at some instant during the call (the same linearizability a Go walk racing with concurrent mounts has). Correctness never depends on `glibc` syscall-wrapper hooks, TTL timers, or other processes having called `glibc`.
2. **The cache is a hint, never an assumption.**
   - Read-only SquashFS mounts are an *optimization opportunity*, not a precondition. A user creating a directory in `/sw`, unmounting a package, mounting over a package subdirectory, bind-mounting a writable tree, or deleting the index must leave every answer correct; only speed may degrade.
   - **Always on; never opt out** (decided 2026-11-17). No tunable, environment variable, or flag disables `FSWC`. Every process that runs `libc`'s initialization takes part, so an index is always present or being built. The worst case is an *outdated* index: validation (§4.3) fails and that call takes the plain walk, which is correct by Rule 1. Tests and benchmarks therefore reach "plain walk" through real states (no index yet, stale index, unusable index directory), never through a switch. `AT_SECURE` (§4.5) is a trust boundary, not an opt-out.

3. **Globs belong to lookups and to aggregation, never to the meaning of a single path in libc.** Fluffy makes globs efficient, and it makes *path lookups* and configuration *aggregation* understand them. The goal is not globs everywhere.
   - **One deliberate exception (2026-11-20, not yet built): `#!` lines.** The planned `binfmt_misc` shebang handler (NOTES, "`PATH`-Resolving `#!` via `binfmt_misc`") treats a shebang's interpreter as a lookup: a bare name through `PATH`, and a path through `glob(path, GLOB_PATHS)`, so `#!/sw/*/bin/bash` runs the first match. It is outside libc, whose `execve`, `execvpe` and `posix_spawn` keep taking a path literally. The 2026-11-16 failures cannot recur there: `GLOB_PATHS` makes only a whole `*` component a wildcard, so `#!/tmp/build[1]/tool` stays literal, and a bare `#!*` is a name for `execvpe`, which takes it literally.
   - **The experiment.** Can configuration work purely by aggregation over path conventions? Every package contributes fragments under `/sw/<pkg>/...`, consumers combine them in a defined order, and the administrator's `/etc` always has the final say. `passwd`/`group` are the model: vendor records from `/sw/*/etc/<db>`, with `/etc/<db>` last and winning.
   - **The administrator can subtract as well as add.**
     - Example: `systemd` discovers units across `/sw/*/lib/systemd/system`, so a mounted package's units exist with no install step. `/etc/systemd/system/<unit>` → `/dev/null` masks one without touching the read-only package.
     - Each kind of consumer needs a removal story:
       - **Keyed records** (`passwd`, `group`, `hosts`): redefine the key in `/etc`, which is read first.
       - **Basename-keyed fragments** (units, `*.d/*.conf`, modprobe, tmpfiles): the same basename in `/etc` replaces the fragment, and the same basename → `/dev/null` masks it.
       - **Accumulating files** (`profile`, `sysctl.conf`): `/etc` is applied last and can override values, but cannot remove a vendor fragment. This is the open gap in the experiment. The `/dev/null`-by-basename convention is the candidate fix if it matters.
   - **libc single-path calls stay literal.** A path passed to `exec*`, `posix_spawn*`, `open`, `stat`, `access`, or `dlopen` means exactly that file; glibc never expands metacharacters in it. A wildcard `execve` fallback that ran "the first match" was removed on 2026-11-16 (§2.5).
   - **Applications aggregate.** Search lists (`PATH`, library search paths, `TERMINFO_DIRS`, `MANPATH`, `/sw/*/etc/<file>:/etc/<file>`) and file-name *arguments or options that name configuration or data inputs* should accept glob patterns, and ideally `GLOB_PATHS` `:`-lists, combined in order with `/etc` last. Examples: openssl `-CAfile`/`-CRLfile`, curl `--cacert`/`--crlfile`, kmod `-C`, `MKE2FS_CONFIG`, `INPUTRC`. Letting the invoking shell expand a pattern into several arguments is an equally acceptable way to aggregate.
   - `open`, `openat`, `*_nocancel`, `stat`, `fstatat`, `statx`, `access`, and `faccessat` are **unmodified upstream**. `FSWC` is consulted only by code that is itself expanding a wildcard (`glob()`, `execvpe()` `PATH` search, `ld.so` wildcard search paths, `GLOB_PATHS` stateless-`/etc` merges), and it only ever tells that code which concrete paths are worth trying.
4. **`ld.so` reads; it never builds.**
   - The dynamic loader maps, validates, and queries an existing index, or performs the plain walk. Index construction lives only in `libc` (§4.4). Every `FSWC` function linked into `rtld` uses bounded stack (target `< 1 KiB` per frame, verified by `objdump` in `CHECK()`), zero `malloc`, zero locks, and is safe on a `PTHREAD_STACK_MIN` thread and inside a `vfork` child.
5. **Daemonless; every cache is user- and namespace-scoped.**
   - Every `FSWC` artifact is scoped to `(euid, user namespace, mount namespace, prefix)`. Nothing is shared across users or namespaces, and identical UIDs in different user namespaces are different identities (decided 2026-11-17).
   - The index for that scope is built at program startup (`__libc_early_init`) by an ordinary dynamically linked process of that user under a non-blocking lock. Until it exists or whenever it fails validation, lookups use the plain walk. No daemon, no `swctl` involvement, no cross-user trust.
6. **Zero implementation leakage.**
   - No downstream package (`binutils`, `gcc`, `bash`, `python`, `perl`, `tcl`, `systemd`, `kmod`, etc.) may include an `FSWC` header, parse index files, or know `FSWC` exists. Downstream packages call standard `<glob.h>` (`glob()`, `globfree()`), `<fnmatch.h>`, `<dlfcn.h>`, `<unistd.h>` (`execvp()`, `execvpe()`), and `<spawn.h>` (`posix_spawnp()`).
7. **Zero hardcoded `"/sw"` literals in C source.**
   - Fluffy paths (`/sw/*/bin`, `/sw/*/lib`, `/sw/*/include`, `/sw/*/etc/...`) enter strictly through build configuration (`configparms` `user-defined-trusted-dirs`, `./configure` flags, `paths.h`, `STANDARD_STARTFILE_PREFIX`, `NATIVE_SYSTEM_HEADER_DIR`, default environment variables).
8. **Preserve `glob_t` ABI — no `GLOB_MOUNTS` flag.**
   - `sizeof(glob_t)` and `sizeof(glob64_t)` remain upstream ABI-compatible. Language runtimes with in-process virtual filesystems (e.g., Tcl `//zipfs:/`) check whether a pattern touches a registered non-OS prefix and delegate native OS patterns to `glibc` `glob()`.
9. **Kernel baseline: host kernel and Fluffy's own kernel only.**
   - Supported kernels are the bootstrap host's (currently 7.0) and Fluffy's `sw/linux` (currently 7.1.8). No compatibility code for older kernels: `statx(STATX_MNT_ID_UNIQUE)`, `listmount`/`statmount` returning **all descendant mounts** (verified on 7.0), and multigrain timestamps are assumed. Fluffy's kernel additionally carries a small patch exposing the mount-namespace change counter (§4.6).
10. **High-bit custom flags, host-environment independence & timestamp-preserving patch hygiene.**
    - Custom `<glob.h>` and `<fnmatch.h>` flags are allocated downward from `(1 << 30)`.
    - All patches preserve upstream file modification timestamps (`TZ=UTC0`, applied with `patch -Z -Np1`).
    - Neither implementation nor tests/benchmarks may depend on host-specific paths existing (Ubuntu without `/sw`, Fluffy without `/snap`, `/bin/sh`, or `/usr/bin`, bare GitHub Actions runners with zero SquashFS mounts). Wildcard tests construct their own prefix (§4.8).
    - Every behavioral modification to an upstream package must be verified by automated tests executed in that recipe's `CHECK()` phase.

### LOC & Duplication Scorecard (Pre-v5 Prototype Baseline → Target State)

**Why `glob.c` stays bigger than upstream (decided 2026-11-17).** The extensions (`GLOB_PATHS`, `**`, extglob, case-folding, dot handling, keep-slashes) add about 1,220 lines to upstream's 1,552. They are what lets bash, Python, Perl, and Tcl delete their own glob implementations and call `glibc`'s, which is how they get the cache without knowing it exists. The cost is paid once in `glibc` and repaid downstream (the rows below), so trimming the extensions is not a goal. `FSWC`'s own footprint in `glob.c` is about 45 lines (one stat helper and a per-call context).

| Component | Pre-v5 Prototype Baseline | Target State | Net LOC Delta |
| :--- | :--- | :--- | :--- |
| `binutils` (`include/fluffy-cache.h` + `ldfile.c`) | 3,379 lines (3,286-line leaked cache header) | ~25-line `glob(GLOB_ONLYDIR)` in `ld/ldfile.c` | **-3,315 LOC** |
| `gcc` (`include/fluffy-cache.h` + `gcc/*.cc`) | 3,676 lines (3,282-line leaked cache header) | ~180 lines using `glob(GLOB_ONLYDIR)` (`libcpp/files.cc` unmodified) | **-3,350+ LOC** |
| `glibc` (`FSWC`) | v4: 3,285-line header compiled into 3 TUs. v5: ~4,400 lines (`fswc.c` + `fswc.h`) compiled into `rtld` + `libc`, a reimplementation of glob semantics, plus hooks in 11 single-path syscall wrappers | v6: one existence-lookup primitive over a sorted path snapshot (`fswc-read.c` + `fswc-build.c`, target < 1,500 lines); `glob()` uses its own `GLOB_ALTDIRFUNC` hooks; **zero** single-path wrapper hooks | **~-3,000 LOC; removes builder from `rtld`** |
| `bash` (`lib/glob/*` deleted + `<glob.h>` wiring) | Deleted `lib/glob/*` (-1,849 lines); delegates 100% to `glibc` | Keep + per-segment `~` tilde expansion & `-DSYS_INPUTRC` polish | *(Already -1,849 LOC)* |
| `perl` (`ext/File-Glob/bsd_glob.c` + `File::Spec`) | Unmodified 1,050-line BSD glob + unpatched `File::Spec->path()` | `<glob.h>` leaf delegation in `bsd_glob.c` + `File::Spec::Unix::path()` + `@INC` `S_incpush` `glob()` | **~-750 LOC active** |
| `python` (`posixmodule.c`, `glob.py`, `os.py`, `site.py`, `getpath.py`, `shutil.py`) | Partial `posix._glob` + 4 separate `:`-splitting glob loops | Full-featured `posix._glob` (`str\|bytes`, all flags, `root_dir`) + shared `posix._glob` path helpers | **Unified C fast-path** |
| `tcl` (`tclFileName.c`, `init.tcl`) | Coarse `TclFSIsPureNative` bailout; `GLOB_BRACE` disabled | ~20-line `TclFSPatternIsNative` prefix check + `GLOB_BRACE` enabled + `GLOB_PATHS` | **~-40 LOC** |
| `make`, `coreutils`, `util-linux`, `which`, `curl` | 75-line `active_glob` in `which.c`; 65-line `curl` wrapper; manual loops in `findprog-in.c` & `util-linux` | `GLOB_PATHS` in `findprog-in.c` & `util-linux`; local `glob()` in `which.c`; `curl` wrapper deleted | **~-180 LOC** |

---

## 2. History: How `FSWC` Got to v6

Six caching designs preceded v6. Each failure is recorded here so it is not proposed again. Quotes are the project owner's own words from earlier assistant sessions; numbers marked *(unverified)* are assistant estimates or one-off measurements that were never reproduced.

### 2.0 The Six Recurring Failure Modes

Any new proposal must avoid all six.

| # | Failure mode | Where it occurred |
| :--- | :--- | :--- |
| **R1** | Cache code copied into several packages | FGC5 and v2–v4: `fluffy-cache.h` duplicated in `glibc`, `binutils`, and `gcc` (97% of the `binutils` patch, 89% of the `gcc` patch) |
| **R2** | Tests or benchmarks depending on host specifics | `tst-glob-bz30635` asserting `execvp` against the default `PATH=/sw/*/bin`; the v5 oracle probing `/snap/core24` and the host's `/sw`; benchmarks run against the live `/mnt/fluffy/sw`. "Ubuntu soon won't have /sw and fluffy will never have /snap and a GitHub ephemeral runner won't have either." |
| **R3** | Work inside `ld.so` or the link step, where there is no `malloc`, stacks may be `PTHREAD_STACK_MIN`, and the caller may be a `vfork` child | v2 (`ld.so` built or mapped the cache at startup through `GLRO`), v4, v5 (27.7 KiB cold-build frame inside `dlopen`) |
| **R4** | An index maintained by `swctl` | The early "`swctl` bumps `/sw`'s ctime on every mount" idea; v4's `/tmp/.fluffy_ns_sealed` marker; a `swctl`-written `/sw/.index` proposed during the v6 redesign. "I don't like swctl making the hint… glibc should do it or some other daemon." |
| **R5** | Assuming nobody changes `/sw` outside `swctl`, or within a running process | The original premise that "/sw mounts never change within a launched process" (abandoned once fresh installs no longer needed a new namespace, NOTES.md principle 2); v4's sealed mode skipping validation; v5's 50 ms revalidation window. "Read-only mounts should be an optimization, not an assumption… make a directory in sw or unmount something manually, we need to still be correct." |
| **R6** | Re-implementing `glob()` pattern matching | FGC5–v4's Case A/B/C fast paths plus the overlapping `glob_literal_suffix_try`; v5's `fswc_glob_try` over a trie |

Standing principles distilled from those failures:

- "The cache must return the same as Go would, even if Go isn't going through glibc." Languages like Go skip glibc, so correctness can never depend on glibc wrappers being called.
- "Optimizations should not change correctness." When a review finds a correctness hole, fix it or drop the feature. Never cover it with a time window.
- "I do want to have one impl in one place." The spec should "work and feel general purpose" even though it has a specific purpose in mind: no Fluffy-specific literals, with Fluffy-specific speedups layered on top.
- "We hardcode a lot of limits; I would prefer dynamic."
- Get it right, then get it fast. Benchmarks and test suites are part of the design, not afterthoughts.

### 2.1 Origins

- **Why a cache at all.** "99% of the time /sw/*/bin/bash is going to return the same thing." "In memory is insufficient because on Linux we have many short-lived processes" (a `configure` run forks thousands of times, so bash's per-process `hash` table does not help). "It's gotta be cross-process, per-user, per-namespace, because permissions matter."
- **Why `glob()` is the primitive.** `ldconfig` and `ld.so.cache` were dropped (`use_ldconfig=no`). A cache frozen inside `glibc`'s own image misses every other package, and `ldconfig` is "a specific-purpose hack to a general-purpose problem (bash /sw/*/bin… tcl's plugin lookup)". "If we disable ldconfig and force /sw/*/lib, we can make this eventually as efficient as its cache… my hope is we just use/optimize glob()."
- **Why one glob dialect.** Hand-written `getdents` + insertion-sort loops in `dl-load.c` and `execvpe.c`, a `strcmp(name, "/sw/*/lib")` in `binutils`, and separate glob code in every shell and runtime were the duplication that started the unification: "everywhere we add glob support should support the same thing: POSIX style", "we should try not to write it ourselves and use stdlib functions", "why isn't everything just going to glibc glob".
- **Why `GLOB_PATHS`.** "So many people reinvent path splitting"; "a colon is just a fancy glob construct… then a myriad of special functions falls away." Ordering is per segment: "'/x:/y/z:/w' must resolve /x/foo first."

### 2.2 FGC5 → v4 (`glob_fluffy_cache.h` / `fluffy-cache.h`)

1. **FGC5.** A per-euid/egid `/dev/shm` file validated by hashing `statx(STATX_MNT_ID_UNIQUE)` + `listmount`. It used raw `INTERNAL_SYSCALL` (so `errno` was untouched and no `malloc`), fixed tables (`top_ht[512]`, `sub_ht[8192]`, 256-bit package bitmasks), and was wired into `glob.c`, `execvpe.c`, and `ld.so`. To kill the `#include` probe storm it was then copied into `binutils` and `gcc` with a hardcoded subdirectory whitelist (`bin`, `lib`, `etc`, `include`, `libexec`) and an include depth cap of 4 (R1, R6). Verdict: "the current optimizations are quite brittle (max mount count etc)."
2. **v2.** A relocatable image modeled on `dl-cache`'s `cache_extension`, `gconv_cache` hashing, and `stringtable.c`. All fixed limits were removed, but `ld.so` built or mapped the cache at startup (R3).
3. **v3.** Correctness tightening: cross-mount and dangling symlinks tagged, permission checks on deep include directories, an `AT_SECURE` bypass, `O_EXCL | O_NOFOLLOW`. It also introduced `MAP_PRIVATE` and 16 hashed shm slots per uid, both later judged defects (copy-on-write page dirtying, slot collisions).
4. **v4.** "Sealed" namespaces: `swctl` remounted `/sw` read-only and created a root-owned `/tmp/.fluffy_ns_sealed`, after which non-root processes skipped validation entirely (R4, R5). v4 also added `#include_next` chain skipping in `libcpp` and routed allocation through `xmalloc` because `gcc`'s `system.h` poisons `malloc` (deeper R1). The cache had also been silently disabled for every `ON=host-build` package, because the host's `/bin/bash` bind-mounted at `/sw/bash/bin/bash` made `/sw` non-SquashFS. Verdicts: "it can't be a great design to have this in triplicate across a header file"; "kill the marker file… optimizations should not change correctness."

Other v4-era defects: per-package keys degrading cross-package probes to $O(N_{\text{pkgs}})$, and Case A/B/C pattern fast paths in `posix/glob.c` overlapping `glob_literal_suffix_try`.

### 2.3 v5 (one module in `glibc`)

v5 moved everything into one internal `glibc` module, a Merged Virtual Trie with per-UID `0700` `/dev/shm` blobs mapped `MAP_SHARED`. The whitelist was replaced with a uniform full-tree index ("I agree on your points about 5 paths vs a uniform index"), and `d_type` was added to every posting because of `include/ncursesw -> .`. State moved from `GLRO` into a writable `GL` slot table, because `GLRO` is RELRO-frozen and extending it would `SIGSEGV`. v5 reached 6,733/6,736 passing `glibc` tests. Review and the remaining failures then exposed structural problems:

1. **Builder inside `ld.so`.** The cold-build path (`fswc_build_or_load_snap_locked`, 27.7 KiB stack frame) ran inside `dlopen`, overflowing `PTHREAD_STACK_MIN` threads (`elf/tst-dl-path-buf` `SIGSEGV`). Stack frames were since reduced to ~1.1 KiB with `mmap` workspaces, but the loader still carried shared-memory construction, mount-tree hashing, and SquashFS scanning: far more than a loader should.
2. **Per-call validation cost proportional to the whole mount table.** Default `mode=1` re-hashed `listmount(LSMT_ROOT)` plus one `statmount` per mount on **every** `glob()`, `execvpe()`, and `dlopen()`. Correct, but a `make -j` build spawning hundreds of `gcc` → `cc1` → `as` → `ld` processes pays that on every exec ("can't do once per process because that kills… makefile builds that spawn hundreds of gccs").
3. **`mode=2` answered on the kernel's behalf.** `__fswc_probe_exact` hooked `open`/`open64`/`openat`/`openat64`/`*_nocancel`/`access`/`faccessat`/`fstatat64`/`statx` to return `ENOENT`/`ENOTDIR` from the cache, with a 50 ms revalidation window and invalidation hooks on `glibc`'s `mount`/`setuid`/… wrappers. A stale cache could therefore produce a *wrong* answer, invisible to Go, `strace`, audit, and fanotify. *Provenance:* an assistant first suggested syscall interception unprompted. It was later approved ("Agree on all") as the way to strip `fluffy-cache.h` from `gcc`/`binutils` without per-`#include` `ENOENT` storms. The TTL and wrapper hooks then came from an assistant review that identified the external-process blind spot and covered it with a staleness window, which violates §2.0's principles. The redesign's verdict: "why are we even modifying open/close?"; "open shouldn't be resolving globs." The probe storm is better eliminated at its source, the wildcard-expanding caller.
4. **Mount relocations required per-mount `statmount`.** Detecting `move_mount`/`MS_MOVE` (which keeps the mount's unique ID and changes no directory entries) required `STATMOUNT_MNT_POINT` for every mount, the main reason for cost 2.
5. **A second implementation of `glob()`.** `fswc_glob_try` re-implemented `GLOB_MARK`, `GLOB_ONLYDIR`, `GLOB_PERIOD`, `GLOB_CASEFOLD`, `**`, and collation on top of a hash-table trie, duplicating upstream `glob()` instead of feeding it (R6).
6. **Three artifact tiers** (`pkg_*`, `blob_*`, `ns_*`) and a 16-slot writable `_rtld_global` table with cross-DSO futexes, fork quiescing, and write-once snapshot publication. This complexity was driven largely by building inside arbitrary processes, including the loader.

v6 keeps v5's per-UID storage hardening and the wildcard parsing and ordering logic in `execvpe.c` and `dl-load.c`, and replaces items 1–6 with a much smaller design (§4).

### 2.4 The v6 Decision Record

In order, each with its reason:

1. **Correctness oracle = Go / raw syscalls** (Rule 1). Get the builder out of the dynamic loader (R3).
2. **Delete the single-path hooks** (§2.3 item 3).
3. **Read-only mounts are an optimization, not an assumption.** This led to the sealed/unsealed split and exact change signals (`statx` ctime + unique mount ID, `listmount`). The 50 ms TTL is a correctness hole, not a tuning knob.
4. **≤ 3 syscalls per call, no `/proc`**, because `make -j` storms exec hundreds of processes.
5. **Kernel baseline = host kernel + Fluffy's kernel only.** "Not interested with compatibility with old kernels. Host kernel and built kernel are sufficient." `listmount` returning all descendant mounts was verified by the project owner on 7.0.
6. **No `swctl`-made index** (R4). **Trust is per user, per namespace:** "a user can trust itself." **Daemonless:** "use the old cache until the new one is made, and cache misses are just manual lookups" (an `nscd`-like `fswcd` and a per-user systemd service were rejected).
7. **`mount --move` is invisible to ID-set checks.** "Small kernel patch is ok" (§4.6). On the host kernel without it, the check is deliberately omitted: "All builds are unprivileged and we control all mount behavior." This is a scoped exception to R5, accepted for unprivileged host-side builds only (§4.3).
8. **Build only at startup, in `__libc_early_init`**, so the first resolved library is not a cold miss. `glob()` is a reader only ("you don't even have to care about glob except for checking cache invalidation"), so the fork hooks go too. A background build thread was rejected because a thread before `main` breaks `unshare(CLONE_NEWUSER)`.
9. **One question, one structure.** "Which packages contain relpath P," answered by binary search over a sorted path array. Stale-delta mode and per-package listing caches were dropped or deferred. "Dramatically simplify this, it's far too much machinery… using the existing function hooks you can pass in if they aren't given" led to `glob()`'s own `GLOB_ALTDIRFUNC` hooks, with real `opendir`/`readdir` and index-backed `lstat`/`stat`. Earlier, the same instinct rejected a Tcl `GLOB_MOUNTS` flag as something that "doesn't pay for itself (and could probably be done with the existing callbacks glob provides optionally)" (Rule 8).
10. "Ok that's fine until we prove it out." v6 is provisional until Phase 0/2 numbers exist.

### 2.5 Other Rejected Alternatives (outside R1–R6)

| Alternative | Why rejected |
| :--- | :--- |
| `overlayfs` merged view or symlink farm | "Overlayfs can only go so deep"; an installer that skips already-present files makes it incorrect; symlink farms are "verboten" (NOTES.md). A merged view would also bypass `glob()`, so runtimes would not benefit transparently. |
| SQLite or an LMDB-style mutable single-writer/multi-reader B+tree index | `malloc` and locks under `vfork` corrupt or deadlock the parent (same constraint as R3); in-place mutation needs `swctl` or in-namespace writers (R4/R5). v6 uses an immutable file per `(euid, userns, mntns, prefix)` replaced by `rename()`. |
| Package identity from the fstab `sha256`, a squashfs xattr, or the loop device's `backing_file` | The fstab is absent in sandboxes (hidden behind a tmpfs by `swctl`) and stale across live upgrades, and it couples `glibc` to Fluffy formats. "I'd really like to avoid a secondary system if we can"; "we don't even need the sha256… we have its inode/mtime/etc and we can do as git does." `backing_file` holds the pre-chroot host path, so it returns `ENOENT` inside `swctl`'s chroot. `SOURCE_DATE_EPOCH=0` gives every package root mtime 0, and loop minors change per phase, so naive `(dev, ino, mtime)` identity misses every phase. Deferred (§4.4). |
| Content-addressed shared blobs + per-namespace bindings | Aimed at namespaces rebuilding identical indexes. Dropped for simplicity (see §4.9). |
| Once-per-process mountinfo snapshot; per-process snapshots in `ld.so`/`gcc` | Never sees packages mounted after startup (R5). |
| Passing a mountinfo poll fd to children; arm-then-poll for long-lived processes | Shared fds race. The arm-then-poll idea was dropped implicitly in v6, not explicitly (§4.9). |
| `system()`/`popen()` running the shell as `bash` (`SHELL_NAME "bash"`) | POSIX requires `sh -c` behavior. Bash started as `bash` is not in POSIX mode; started as `sh` it is. The name had been changed only so upstream `tst-system` (which expects the error prefix `basename(_PATH_BSHELL)`) would pass. Fixed 2026-11-16 the upstream way: `SHELL_NAME` is `"sh"` again and `_PATH_BSHELL` is `/sw/bash/bin/sh` (the `sh -> bash` link both bash recipes install), matching upstream's `/bin/sh`. Upstream `tst-system` passes unmodified apart from an added POSIX-mode check. |
| Wildcard executable paths (`execve`/`execvpe`/`posix_spawn` expanding a path containing `/` and metacharacters, "first lexicographical match wins") | Out of scope (Rule 3): globs are for lookups, not for what a single path means. It also ran arbitrary programs: `Popen(["*"])`, or `execve("/tmp/build[1]/tool")` running `/tmp/build1/tool`. Python's `test_subprocess.test_handles_closed_on_exception` caught it. Removed 2026-11-16; `tst-fswc-vfork`, `tst-fswc-edge` 5b2, and `tst-glob-fluffy-flags` §10 now guard that such paths fail with `ENOENT` and run nothing. |
| `GLOB_MOUNTS` mount table (`{mountpoint, vfs ops, userdata}`) for Tcl | It blew out the implementation complexity; Tcl's VFS is in practice only used for zip files; Tcl can hook the existing callbacks itself and fall back to callback-free `glob()` (Rule 8, §5 `tcl`). |
| Old-kernel fallbacks; capability flags in the index; runtime strict/relaxed mode | Kernel baseline decision (§2.4 item 5, item 7). |
| `/run` as a namespace-private store | Assumed by an assistant and false: tmpfs is not per-namespace unless remounted. v6 puts the mount-namespace ID in the file name (§4.2). |
| An NSS `fluffy` module reading an index for `passwd` | Never adopted; stateless `/etc` uses `GLOB_PATHS` in `nss_files` instead. |

### 2.6 Measurements to Date

**No v6 numbers exist, and no benchmark in the history was independently reproduced.** All figures below are *(unverified)* and were measured against the live 76–91 package `/mnt/fluffy/sw`, which Rule 10 now forbids for tests.

| Measurement | Figure *(unverified)* |
| :--- | :--- |
| Stock `glob("/sw/*/bin/bash")` | 218–258 µs at 76 packages; ~1,004 µs at 350 packages |
| FGC5 / v2 warm lookup | 4.4–5.3 µs / 3.9–4.4 µs |
| Same lookup on a literal non-wildcard path | 1.87 µs |
| `statx` + `listmount` validation ("the physical floor") | ~2.8–4.1 µs |
| v4 sealed mode, no validation | ~250 ns |
| `fc_lookup_path` negative probe vs a real failed `open` | 32 ns vs 1,016 ns |
| `vfork` + `execvpe` over a 59-directory `PATH` | 384 µs (cached) vs 399 µs (plain) |
| Full tree, 91 packages | 57,417 inodes, 1.05 GiB (from squashfs headers, plausible) |
| Index size estimates | 105 KB (v2 image) vs 683 KB (FGC5); ~2 MiB full tree |

The only first-hand comment on speed: "yeah this definitely seems to speed up builds" (FGC5), and earlier "the speed seems ok? i haven't benchmarked." Phase 0 exists to replace this table.

### 2.7 Pitfalls Already Hit

- **`errno` on a cache-proven miss.** `execvpe` returned `-1` with `errno == 0` because `__execve` was never called. Perl's `op/exec.t` caught it; upstream `tst-execvp1`/`tst-execvp4` each test only half of the condition. Any path that skips the real syscall must set the `errno` the plain walk would have produced (§4.8).
- **Link-namespace traps.** `memrchr` in `glob.c` broke `check-localplt` and 14 `conform/*/linknamespace` tests. `__builtin_popcountll` emitted a `__popcountdi2` call into `libgcc`.
- **`-Werror` asymmetry.** `glibc-pass1` builds with `-Werror` and `glibc` does not, so a static helper unused in one TU breaks only the pass1 build.
- **Patch regeneration dropping hunks.** A regeneration script silently lost the `execvpe.c` and `paths.h` hunks, and `tar` could no longer exec `xz`. Existing patches use different hunk orders (`gcc` en_US, `glibc` C); see §6 patch regeneration.
- **Unquoted wildcard configuration.** `binutils`' `genscripts.sh` `LIB_PATH` was expanded by the build shell, so no literal `SEARCH_DIR` reached the ldscripts. Wildcard configure values must be single-quoted (`--with-lib-path='=/sw/*/lib'`).
- **Non-SquashFS `/sw` entries in `host-build`.** The bind-mounted host `/bin/bash` silently disabled v4's cache. In v6 it must simply be unsealed (§4.2).
- **`use_ldconfig=no` is under-tested upstream.** `pldd`/`xmalloc.o` fails with `MODULE_NAME` errors, and `_dl_check_ldsocache_needs_loading` leaves `errno == ENOENT` behind.
- **Tcl and Jim `glob` have no POSIX character classes.** `glob {/sw/[[:alpha:]]*}` returns nothing in both, while `[a-z]*` matches. So Tcl-side `PATH` splitters (sqlite `autosetup` `split-path` under `tclsh` or `jimsh0`, and `dejagnu`'s `proc which`) can keep a `[[:alpha:]]` element intact and still never match it. Only runtimes that delegate to `glibc` `glob()` get POSIX classes. Open bug in `sw/sqlite-3530400-fluffy.patch`; its test records it as an expected failure (2026-11-16).
- **`getconf PATH` is not wildcard-aware.** Fluffy's `glibc` reports `_CS_PATH` as `/bin:/usr/bin`, which matches neither `_PATH_DEFPATH` nor `_PATH_STDPATH` (`/sw/*/bin`). Anything using `confstr(_CS_PATH)` (for example POSIX `command -p`) gets directories that do not exist on Fluffy. Open; see the `glibc` entry in §5.
- **Inline `CHECK()` tests that never tested anything.** While moving them into test patches (§5 intro), several turned out to be dead or vacuous:
  - `man-db` asserted `manpath -g` output, but `-g` prints only `MANDB_MAP` entries.
  - `iproute2`'s test program never linked (missing `-lcap`).
  - `binutils` fixtures had mismatched sonames.
  - `e2fsprogs` fixtures used mke2fs's built-in default values, and an unknown `-T` type only warns.
  - `coreutils` only exercised `glibc` `execvp`, never its own patched `findprog-in.c`.

  Every moved test is now run once against unpatched code to show it fails.
- **`nss_files` lookups ignored the requested address family (fixed 2026-11-16).** The stateless-`/etc` patch wrapped `internal_getent` in `files-XXX.c` and forwarded `EXTRA_ARGS_VALUE`. That is an include-time constant (`, AF_INET, 0` in `files-hosts.c`), where the wrapper's own `EXTRA_ARGS` parameters belonged. So every `hosts` scan parsed lines as `AF_INET`:
  - `gethostbyname2("localhost", AF_INET6)` returned `127.0.0.1` with a 4-byte length;
  - with `multi on`, `getaddrinfo(AF_INET6)` aborted (`gethostbyname3_multi: h_length == 16`).

  gcc's `g++.dg/modules/bad-mapper-3.C` found it. It only shows when `files` actually answers: in a build sandbox without systemd's `myhostname`/`resolve` modules, `myhostname` had been answering `localhost` first and hiding the bug. `nss/tst-fluffy-stateless-etc` now checks `AF_INET6` via both `getaddrinfo` and `gethostbyname2`, and it fails without the fix.
- **Flags that silently stop applying (2026-11-17).** Under the strict `GLOB_PATHS` rule, pattern-syntax flags such as `GLOB_TILDE` are ignored rather than rejected, so `readline`'s `GLOB_PATHS | GLOB_TILDE` call quietly lost `~/.inputrc` entries. Its own test caught it. When a flag's meaning goes away, search every caller that passes it.
- **Cross-toolchain libstdc++ underlinking.** The `--disable-shared` `gcc-pass1` driver never links `libgcc_s`, so cross-built `libstdc++.so` lacked `DT_NEEDED libgcc_s.so.1` until a `-shared`-only specs file was added in `sw/libstdcpp-pass1` and `sw/gcc-pass2`. `binutils` `CHECK()` (a) exists to catch exactly this class of indirect-`DT_NEEDED` failure.

---

## 3. Public `<glob.h>` & `<fnmatch.h>` Specification

### 3.1 High-Bit Flag Allocation Table

All Fluffy extensions occupy bits `30` downward and preserve strict ISO C and POSIX.2 (`_POSIX_C_SOURCE >= 2` without `_GNU_SOURCE` / `_DEFAULT_SOURCE`) namespace cleanliness: `<glob.h>` guards the seven `GLOB_*` flags under `#if !defined __USE_POSIX2 || defined __USE_MISC`, and `<fnmatch.h>` guards `FNM_DOTDOT` under `#if !defined _POSIX_C_SOURCE || _POSIX_C_SOURCE < 2 || defined _GNU_SOURCE`:

| Header | Macro | Value | Purpose |
| :--- | :--- | :--- | :--- |
| `<fnmatch.h>` | `FNM_DOTDOT` | `(1 << 30)` | Never match `.` or `..` via leading wildcards (`*`, `?`, `[...]`, `!(...)`), even when `FNM_PERIOD` is absent (leading `.` matched on `.foo`, whereas `.` and `..` require a literal leading `.` such as `.`, `..`, or `.*`, which `GLOB_SKIPDOTS` suppresses in `glob`). |
| `<glob.h>` | `GLOB_KEEP_SLASHES` | `(1 << 30)` | Preserve redundant trailing slashes on completely literal directory patterns (`"dir//"` → `"dir//"`) while normalizing wildcard matches (`"d*//"` → `"dir/"`). Required for Python `glob.glob()` parity. |
| `<glob.h>` | `GLOB_PATHS` | `(1 << 29)` | Treat the pattern as a search list (§3.2): `:`-separated elements, empty means `.`, a whole `*` component is the only wildcard (at most one per element), byte order within an element; `{list}/NAME` appends a literal NAME to every element. Shared with `execvp` and `ld.so`. |
| `<glob.h>` | `GLOB_EXTMATCH` | `(1 << 28)` | Enable ksh/Bash extended globs (`?(pat-list)`, `*(pat-list)`, `+(pat-list)`, `@(pat-list)`, `!(pat-list)`) in both `__glob_pattern_type` and `fnmatch`. |
| `<glob.h>` | `GLOB_CASEFOLD` | `(1 << 27)` | Case-insensitive filename matching (`FNM_CASEFOLD`, Bash `nocaseglob`, Tcl `-nocase`, Python `case_sensitive=False`). Scans directories case-insensitively without setting `GLOB_MAGCHAR` on purely literal patterns, preserving `GLOB_KEEP_SLASHES \| GLOB_CASEFOLD` and `GLOB_NOMAGIC \| GLOB_CASEFOLD`. |
| `<glob.h>` | `GLOB_SKIPDOTS` | `(1 << 26)` | Never emit `.` or `..` directory entries, even when `GLOB_PERIOD` is set or the pattern is `.*` (Bash `globskipdots`, Tcl/Python directory scans). |
| `<glob.h>` | `GLOB_GLOBSTAR` | `(1 << 25)` | Treat standalone path component `**` as recursive zero-or-more-directory traversal (`globstar`, Python `recursive=True`). |
| `<glob.h>` | `GLOB_DOTDOT` | `(1 << 24)` | Forward `FNM_DOTDOT` to `fnmatch`: with `GLOB_PERIOD`, match hidden `.foo` files with `*` while excluding `.` and `..` unless literally requested (Bash `dotglob`, Python `include_hidden=True`). |

`__GLOB_FLAGS` in `<glob.h>` is the symbolic OR of all standard POSIX/GNU input flags plus all seven `GLOB_*` high bits (`0x7f007eff` — note bit 8, `GLOB_MAGCHAR = 0x0100`, is an output-only `gl_flags` status bit and is never included in `__GLOB_FLAGS`).

### 3.2 Exact Behavioral Semantics

1. **`GLOB_PATHS`: search lists** *(redefined 2026-11-17; replaces the earlier bracket-, brace-, and extglob-aware colon splitting)*.
   - **One rule for every search list.** `execvp`/`execvpe`/`posix_spawnp` `PATH` search, `ld.so` library search paths, and `glob (…, GLOB_PATHS)` all follow the same rule. They are implemented by the same code, the shared walker in `fswc-read.c` (Phase 2 step 5), so they cannot drift apart. Restricting `glob()` here is acceptable because nobody had globs in search paths before (the nearest precedent, Java's `CLASSPATH` `dir/*`, likewise allows only a whole `*`), and the rule is short to document:
     1. The list is split on every `:`. An empty element, or an empty list, means `.` (POSIX.1-2024 §8.3).
     2. Inside an element, a path component that is exactly `*` matches every entry of that directory whose name does not begin with `.`. When more path follows (always true once a command or library name is appended), it matches only directories and symlinks to directories, as `glob ("<dir>/*/bin")` does. So a plain file next to the packages, such as `/sw/<pkg>.squashfs`, is never a candidate and cannot turn a failed search's `ENOENT` into `ENOTDIR`. The same rule is why systemd's `find_executable_in_element` passes `GLOB_ONLYDIR` (§5). Every other character is literal: `?`, `[`, `]`, `{`, `}`, `\`, and a `*` inside a longer component (`lib*`) included. No escapes are needed or recognised.
     3. An element has at most one `*` component (as `ld.so` has always required). An element with more is not expanded and matches nothing.
     4. Elements appear in list order. Within an element, matches are in **byte order** (`strcmp`), whatever the locale, so which program runs or which library loads never depends on `LC_COLLATE`.
   - **Finding a name in one call.** `glob ("{" + list + "}/" + name, GLOB_PATHS, …)`: when the pattern starts with `{`, the list is everything up to the **last** `}/`, and the rest, NAME, is appended literally to every element (an empty element gives `./NAME`). A command name cannot contain `/`, so the split is never ambiguous and NAME needs no quoting. Results are the existing `<element>/NAME` paths in the order above, which is exactly the order `execvp` tries them. Callers: bash command search and completion, `which`, `findprog-in.c` (`make`, `coreutils`), Tcl's `auto_execok`, Python's `shutil.which`, each dropping its own `PATH` splitter.
   - **Flags.** `GLOB_ONLYDIR` and `GLOB_MARK` keep their meanings. With no match, `GLOB_NOCHECK` keeps the element itself (`.` if empty, with `/NAME` if given), and `GLOB_NOMAGIC` does so for elements without a `*`. `GLOB_APPEND` and `GLOB_DOOFFS` keep their meanings. Caller `GLOB_ALTDIRFUNC` hooks are honored: the walker lists directories through them and, as always with caller hooks, never consults the index. Order is always byte order, so `GLOB_NOSORT` has no effect; `GLOB_ERR` and the error callback are not consulted (an unreadable directory contributes no candidates, as in `execvp`). Pattern-syntax flags (`GLOB_BRACE`, `GLOB_EXTMATCH`, `GLOB_CASEFOLD`, `GLOB_GLOBSTAR`, `GLOB_PERIOD`, `GLOB_DOTDOT`, `GLOB_SKIPDOTS`, `GLOB_NOESCAPE`, `GLOB_TILDE*`) do not apply to list elements. Without `GLOB_PATHS`, `glob()` keeps full pattern syntax.
   - **`GLOB_DOOFFS` and `GLOB_APPEND` invariants (kept).** When `!(flags & GLOB_APPEND)`, `pglob` is initialized once before the first element (`gl_offs` leading `NULL` slots under `GLOB_DOOFFS`), and every element appends.
   - **`execvp` and `posix_spawnp` specifics.** They try `execve` on each `<element>/NAME` in the order above and run the first that succeeds. With no success they fail with `EACCES` if any candidate gave `EACCES`, else `ENOENT` (upstream's rule, unchanged; `tst-fswc-oracle` checks it). The walker uses no `malloc`, no locks, and no locale, so it is safe after `vfork()`, in `posix_spawnp`'s `CLONE_VM` child, and inside `ld.so`.
   - **Consequence for consumers.** Downstream `GLOB_PATHS` callers audited 2026-11-17 (bash, coreutils, make, iproute2, groff, man-db, util-linux, readline, Tcl) only use whole-`*` elements. What changes is hand-written lists with other patterns, and Python's `GLOB_PATHS` flag.
2. **`GLOB_GLOBSTAR` (`**` Traversal) & `GLOB_PERIOD` Intermediate-Directory Rules**:
   - Consecutive `**` components (`a/**/**/b`) collapse in $O(1)$ before traversal to prevent exponential backtracking.
   - `**/X` matches `X` at depth 0 (in the base directory) as well as `<sub1>/.../<subk>/X`.
   - **Symlink & slash discipline (Bash 5.3 `shopt -s globstar` parity)**: Non-terminal `**/...` descends strictly into real directories (`DT_DIR`) *during* `**` traversal, **never** recursing through symlinked subdirectories (`DT_LNK`) encountered under `**` (avoiding infinite symlink loops and matching `bash-5.3/tests/globstar3.sub`). However, an explicit prefix directory *before* `/**/...` that is itself a symlink to a directory (e.g., `<prefix>/<sym> -> <pkg>` or `/sw/ncurses/include/ncursesw -> .`) **is** resolved as the root directory of `**` and traversed at both depth 0 and depth 1+ in every `FSWC` state. When expanding non-terminal `<dir>/**/<rest>` where `<dir>` has no trailing `/`, `"d1/**/a.txt"` yields `"d1/a.txt"` (never `"d1//a.txt"`), while terminal `"d1/**"` still emits `"d1/"` first. Terminal `**` (with no trailing `/...`) includes directory symlinks as leaf results (and resolves them when `/**/` requires a directory). *(Note: Python 3.14's `glob.glob(..., recursive=True)` instead follows symlinked directories inside `**` per `test_glob.py:test_recursive_glob`; see §5.6.)*
   - **Hidden directories (`GLOB_PERIOD`)**: Hidden directories (`.git`, `.build`) are entered by `**` if and only if `GLOB_PERIOD` is set. For non-`**` intermediate directory components, upstream `glibc` (`posix/tst-gnuglob-skeleton.c` `test("*/*/*", GLOB_PERIOD, ...)`) requires `GLOB_PERIOD` *alone* not to apply to intermediate `dirname` components (because `.` and `..` would explode `*/*/*`); when `.` and `..` are suppressed via `(flags & (GLOB_DOTDOT | GLOB_SKIPDOTS)) != 0`, `GLOB_PERIOD` **is** forwarded to non-`**` intermediate directory components uniformly in every `FSWC` state.
3. **`GLOB_EXTMATCH` Pattern-Type Isolation & Escaped-Opener Directory Scan (`posix/glob_internal.h` & `posix/glob.c` Fixes)**:
   - `__glob_pattern_type_ext(pattern, quote, extmatch)` **must** inspect `+(`, `@(`, `!(` if and only if `extmatch != 0` (`(flags & GLOB_EXTMATCH) != 0` in `__glob` and `glob_in_dir`, and `0` in two-argument `__glob_pattern_type`). Unconditionally passing `extmatch = 1` (a live bug in the current prototype) falsely sets `GLOB_MAGCHAR` and breaks `GLOB_NOMAGIC` (`glob("foo+(bar)", GLOB_NOMAGIC)` / Perl `GLOB_CSH`) when `GLOB_EXTMATCH` is unset.
   - In `posix/glob.c`, `glob_dirscan(pat, dirsep, quote)` (used when `flags & GLOB_EXTMATCH`) **must** skip escaped characters (`if (quote && *p == '\\' && p[1] != '\0' && p[1] != dirsep) { ++p; continue; }`) before testing `is_extglob(p)`, fixing a live prototype bug where escaped `\@(` / `\+(` / `\?(` / `\*(` / `\!(` were misparsed as extglob groups and hid inner `/` directory separators.
4. **`glibc` Symbol, Hidden Alias & Static `conform/*/linknamespace` Invariant**:
   - On 64-bit Linux (`XSTAT_IS_XSTAT64` where `glob` and `glob64` share `sysdeps/unix/sysv/linux/glob.c`), `glob.c` **must** emit both `libc_hidden_def (glob)` and `libc_hidden_ver (__glob, __glob64)` plus `#if IS_IN (libc)` `hidden_def_alias (__glob, __GI_glob64)` `#endif`.
   - **ISO C11 & POSIX `libc.a` Link-Namespace Isolation (`conform/*/linknamespace`)**: Internal `libc` stateless-`/etc` callers (`nss/nss_database.c`, `nss/nss_files_fopen.c`, `resolv/res_hconf.c`, `resolv/resolv_conf.c`—the last of which is pulled into ISO C11 `thrd_create` via `__pthread_create` → `__libc_resp` → `__res_vinit`) **must never** reference un-prefixed `glob64`, `globfree64`, `globfree`, or `fnmatch`, nor pull `GLOB_TILDE`'s `__getlogin_r` (`utmp_file.o` → `alarm`) or `__getpwnam_r` (`res_send.o` → `read`) into `libc.a` closures:
     1. Define `__globfree` / `__globfree64` (`weak_alias (__globfree, globfree)` and `weak_alias (__globfree, globfree64)`) in `globfree.c` and expose `libc_hidden_proto (__fnmatch)` / `libc_hidden_def (__fnmatch)` so the glob engine calls only `__fnmatch` and `__globfree`.
     2. Split the `GLOB_TILDE` home-directory lookup (`__getlogin_r` / `__getpwnam_r`) out of the core tilde-free `__glob64_notilde` TU so `nss_database.c`, `nss_files_fopen.c`, `res_hconf.c`, and `resolv_conf.c` call `__glob64_notilde` and `__globfree64` with zero `ISO11` or `POSIX` `linknamespace` pollution.

---

## 4. `FSWC` v6 Internal Architecture in `glibc`

### 4.1 The Whole Idea

`FSWC` answers one question: **what is at `<prefix>/<pkg>/<relpath>`—nothing, a file, a directory, a symlink, or "ask the kernel"?** It answers it from a per-user, per-namespace snapshot of the immutable packages under `<prefix>`, and only when it can prove the snapshot still matches the kernel.

Everything else is existing code:

| Consumer | How it uses `FSWC` |
| :--- | :--- |
| `glob()` (and `GLOB_PATHS`, stateless-`/etc` merges via `__glob64_notilde`) | When the caller did **not** pass `GLOB_ALTDIRFUNC`, `glob()` runs with `GLOB_ALTDIRFUNC` internally, supplying the real `opendir`/`readdir`/`closedir` and `FSWC`-backed `lstat`/`stat`. Upstream `glob()` does all matching, recursion, `**`, `GLOB_PERIOD`/`GLOB_MARK`/`GLOB_ONLYDIR`/`GLOB_CASEFOLD`, sorting, and error callbacks unchanged. |
| `execvpe()` / `posix_spawnp()` wildcard `PATH` elements | For each package, `fswc_lookup("bin/<file>")` (or `<relpath>/<file>`) decides whether to try `execve` on it. |
| `ld.so` wildcard search paths | For each package, `fswc_lookup("lib/<soname>")` (per `glibc-hwcaps` subdirectory) decides whether to try `open_verify` on it. |

For `/sw/*/bin/bash`, upstream `glob()` reads `/sw` with a real `getdents64`, then checks `bin` and `bin/bash` in each package with `lstat`/`stat`; those checks are answered from memory, so only packages that actually have the file survive. Wildcards deeper in the pattern (`/sw/*/lib/python3.14/site-packages/*`) use the same existence checks to prune packages, then read the surviving directories with real `readdir`. No glob semantics are reimplemented.

### 4.2 Index File

One immutable file per `(euid, user namespace, mount namespace, prefix)` (Rule 5): `/dev/shm/.fswc-<euid>-<userns_id>/idx-<mntns_id>-<prefix_dev>-<prefix_ino>`, mode `0400`, mapped `PROT_READ | MAP_SHARED`.

- `<euid>` is `geteuid()` as seen inside the process's user namespace.
- `<userns_id>` is the inode number of the process's user namespace: `pidfd_open(getpid())`, `ioctl(PIDFD_GET_USER_NAMESPACE)`, `fstat`, `close`. No `/proc`; paid only when mapping or building an index, never per lookup. It is in the directory name because `/dev/shm` is usually shared across user namespaces: without it, "root" inside an `unshare -Ur` sandbox or rootless container would look for real root's `.fswc-0`, correctly refuse it (it appears owned by the overflow UID), and be unable to create its own, so it would never get an index.

```c
struct fswc_header {
  uint32_t magic, version;      /* "FSWC", 6 */
  uint64_t total_size;
  /* What the snapshot describes (checked on every use, §4.3). */
  uint64_t mntns_id;            /* statmount(STATMOUNT_MNT_NS_ID) */
  uint64_t ns_event;            /* Mount-namespace change counter (§4.6); 0 if unavailable */
  uint64_t prefix_mnt_id;       /* statx STATX_MNT_ID_UNIQUE */
  uint64_t prefix_dev, prefix_ino;
  int64_t  prefix_ctime_sec;
  uint32_t prefix_ctime_nsec;
  uint64_t userns_id;           /* Inode of the user namespace (PIDFD_GET_USER_NAMESPACE) */
  uint32_t euid;                /* geteuid() inside that user namespace */
  uint32_t num_mounts, mounts_off;  /* Sorted unique IDs of all mounts beneath <prefix> */
  /* Contents. */
  uint32_t num_top, top_off;        /* Every name in <prefix>, strcmp order */
  uint32_t num_paths, paths_off;    /* Every relpath in every sealed package, byte order */
  uint32_t postings_off, strtab_off, strtab_size;
};

struct fswc_top {                   /* One per name in <prefix> */
  uint32_t name_off;
  uint16_t name_len;
  uint8_t  sealed;                  /* 1 = indexed package; 0 = ask the kernel */
  uint8_t  d_type;
};

struct fswc_path {                  /* e.g. "bin", "bin/bash", "lib/libz.so.1" */
  uint32_t name_off, name_len;
  uint32_t postings, count;         /* -> uint32_t[count]: top_idx << 8 | d_type */
};
```

A top-level name is **sealed** only if it is the root of a SquashFS mount with no mounts beneath it, and every directory in it is world-readable and world-searchable with no POSIX ACL. Anything else—plain directories, `*.squashfs` files, writable or bind mounts, overmounted packages, packages with unusual permissions—is unsealed and always asks the kernel. On Fluffy, every package is sealed.

The reader bounds-checks a mapping once (sizes, offsets, string termination, strictly sorted `top[]`, `paths[]`, and `mounts[]`, postings in range); any failure means "no index".

### 4.3 Lookup and Validation

**`fswc_lookup(prefix, pkg, relpath)`** returns `ABSENT`, `REG`, `DIR`, `LNK` (or other `DT_*`), or `KERNEL`:

1. If there is no valid index for `prefix` in this call (below), `pkg` is not sealed, or `relpath` is not normalized (contains `.`, `..`, or empty components): `KERNEL`.
2. Empty `relpath`: `DIR` (the package root).
3. Binary-search `paths[]` for `relpath`; if found, return this package's `d_type` from the postings (`ABSENT` if the package is not listed).
4. If not found: if an ancestor of `relpath` is listed as a symlink or non-directory in this package, `KERNEL` (the kernel decides `ENOTDIR` and symlink traversal); otherwise `ABSENT`.

The `FSWC`-backed `lstat`/`stat` hooks given to `glob()` map `ABSENT` to `ENOENT` and `REG`/`DIR` to a `struct stat` carrying only the type bits (`glob()` only tests `S_ISDIR` and success); `stat` on `LNK` and every `KERNEL` result call the real function. The hooks only exist for the duration of that `glob()` call; the caller's `glob_t` fields are restored before returning.

**Validation**, once per `glob()`/`execvpe()`/library search call, before any lookup is trusted:

1. `statx(<prefix>, AT_SYMLINK_NOFOLLOW, STATX_INO | STATX_CTIME | STATX_MNT_ID_UNIQUE)` equals the header (catches entries added, removed, or renamed in `<prefix>`, and `<prefix>` itself being replaced).
2. Mount state equals the header: `ns_event` via `NS_MNT_GET_INFO` on Fluffy's kernel (catches every mount operation, including `move_mount`); otherwise one `listmount(<prefix_mnt_id>)` equals `mounts[]` (catches mounts added, removed, replaced, or nested beneath a package). **Known, accepted gap:** a `move_mount`/`MS_MOVE` swap of two packages changes neither the mount-ID set nor `<prefix>`'s ctime, so without the counter it goes undetected and a stale index would answer wrongly. This is a deliberate, scoped exception (§2.4 item 7: "All builds are unprivileged and we control all mount behavior"), valid only for unprivileged host-side builds on the host kernel. It must not be relied on anywhere else, and the §4.8 `move_mount` row runs on Fluffy's kernel.
3. `geteuid()` equals the header. If the euid changed since the index was mapped, map the current euid's index instead of falling back (§4.5).

That is 2–3 syscalls per call. If any check fails, the call uses the plain walk; the next program start rebuilds the index.

### 4.4 Building (`__libc_early_init`, nowhere else)

`ld.so` never builds. `__libc_early_init`—run once `libc` is relocated, single-threaded, before any constructor or `main`—validates the index for each wildcard prefix in the trusted search paths and, if one is missing or stale, builds it synchronously:

1. Skip under `AT_SECURE` (§4.5), or if `/dev/shm/.fswc-<euid>-<userns_id>/` is not a `0700` directory owned by `euid` (opened `O_NOFOLLOW`).
2. `flock(LOCK_EX | LOCK_NB)` on `lock-<mntns_id>-<prefix_dev>-<prefix_ino>`; if busy, continue to `main`.
3. Record `statx(<prefix>)`, `ns_event` if available, and `listmount` IDs.
4. Read `<prefix>`; classify each name; walk each sealed package with `getdents64`, collecting `(relpath, top_idx, d_type)` into temporary anonymous `mmap` arenas; sort; write the file.
5. Repeat step 3; if anything changed, discard. On filesystems without multigrain timestamps, first wait until the coarse clock has passed the recorded ctime.
6. Write to a temporary name (`O_EXCL`, `0400`), then `renameat` into place. Never modify a published file.
7. **Sweep dead namespaces.** Unlink every `idx-<mntns_id>-*` whose mount namespace no longer exists (`listmount` on that namespace ID returns `ENOENT`), plus leftover temporary files, in the builder's own directory *and* in every other `.fswc-*` directory it may delete (same on-disk owner, so `/dev/shm`'s sticky bit allows it). Remove any such directory left empty. This also reclaims directories of dead user namespaces: every mount namespace holds a reference to its owning user namespace, so by the time a user namespace is gone, every mount namespace named in its directory is gone too and fails the `listmount` check. Only `ENOENT` deletes; `EPERM` (a live namespace the sweeper has no rights over) leaves the file alone. Every new namespace gets its own index and nothing else ever deletes one, so without this sweep `/dev/shm` (RAM, or swap) grows until reboot.

   The sweep is safe because the index is only a hint. Deleting an index costs at most a rebuild, and processes that already have it mapped keep their mapping after `unlink`.

There is **no size cap**. Size is bounded by what the administrator installed: only sealed SquashFS packages under build-configured prefixes are indexed, and the build arenas are sized dynamically. Any build failure (`ENOSPC`, a race, an interruption) just means no index this time, so lookups use the plain walk.

**Startup ordering.** In a dynamically linked program, `ld.so` resolves and maps every `DT_NEEDED` library *before* `__libc_early_init` runs. A builder in `__libc_early_init` therefore never speeds up its own process's startup, and that startup is exactly the dominant cost (§6 Phase 0: 19 ms for a 15-library exec at 100 packages, 64 ms at 300). The startup win comes entirely from `rtld` finding an index that an *earlier* process built: `rtld` must map and validate an existing index on its first wildcard library search, before loading `DT_NEEDED`. That is still "reads, never builds" (Rule 4): `open` + `fstat` + `mmap` with bounded stack and no `malloc`.

Consequences: after a namespace is created or packages change, one dynamically linked program start per user per namespace pays the build, and every later start is served from the index. The builder never runs in a thread, after `fork`, in a `vfork` child, in a signal handler, or in `rtld`. Programs that do not use `glibc`'s dynamic loader (static binaries, Go) never build and are not harmed; they get the plain walk, which is correct by Rule 1. Rebuild frequency is therefore one per *namespace creation*, not per process. On a booted Fluffy system processes inherit PID 1's namespace (NOTES.md principle 2), so rebuilds follow upgrades. But every `swctl` build phase and any sandbox that calls `unshare(CLONE_NEWNS)` starts cold (~57k inodes over 91 packages today, *unverified* cost). Phase 0 must measure this. Note also that the build lands on whichever program starts first in the namespace. If cold-build cost proves too high, **profile the build first and fix what is actually slow**; do not pre-design a remedy. Only if profiling shows the walk itself is the irreducible cost would per-package listings keyed by SquashFS image identity be worth their complexity. They would then be subject to §2.5's identity findings:
- listings must stay per-user (§4.5);
- the key must come from kernel-visible metadata ("do as git does"), not the fstab or xattrs;
- `backing_file` paths are host paths that break inside chroots;
- `SOURCE_DATE_EPOCH=0` makes mtimes useless.

### 4.5 Trust

- **Always the current euid's index.** Every call uses the index of the *current* `geteuid()`. A process that changes its euid mid-run (swctl's own bash switches between 0 and `SUDO_UID` with `setresuid`) maps the new euid's index on its next call (`open` + `fstat` + `mmap`, `rtld`-safe; the last few mappings are kept), so `seteuid()` is both correct and fast. Decided 2026-11-17.
- A process only reads index files in its euid's `0700` directory, owned by that euid, mode `0400`, opened `O_NOFOLLOW`. Another user can at most squat the directory name, forcing the plain walk.
- Index names and headers carry the mount-namespace ID, so namespaces never share an index.
- User-namespace ownership checks compare against the in-namespace `euid`, so in-namespace "root" never trusts real root's files. Because the directory name carries `<userns_id>` (§4.2), in-namespace "root" also never collides with real root's directory and gets its own index.
- `AT_SECURE` processes read their euid's index like any other process, but **never build**. The builder would otherwise run with elevated credentials (e.g. as root inside `passwd`), at a time and in an environment the invoking user controls. Setuid programs therefore use the owner's index (root's for setuid-root); `sudo` itself skips building, but what it executes is not `AT_SECURE` (sudo sets real and effective IDs before `exec`), so `swctl` and its build phases build and read normally.
- **Truncation under a mapping (found 2026-11-17).** Truncating a published index file kills every process that has it mapped with SIGBUS when it next touches the lost pages. FSWC itself never truncates (a rebuild renames a new file into place; the sweep only unlinks, and mappings survive both), and only the owner can (the file is `0400` in a `0700` directory), so it takes a user damaging their own cache. Accepted, as fontconfig's mmapped caches and the locale archive accept it; file seals, which would prevent it, exist only for `memfd`s, not for named files in `/dev/shm`.
- **Threat model (decided 2026-11-17).** An index is exactly as trustworthy as the user who owns it. A user who forges their own index only misleads lookups made under their own euid; "if a user account compromised itself, we have already lost", and the worst it gets is a bad cache: a wrong choice among real, root-owned package files. **Accepted residual risk:** setgid, file-capability, and LSM-transition programs keep the invoker's euid while holding a privilege the invoker lacks, so they read the invoker's index; a forged one could hide an aggregated configuration fragment from them or change which package's library wins. Fluffy has few such programs. Revisit if a privileged consumer of aggregated configuration appears (the fix would be: `AT_SECURE` with euid equal to the real UID takes the plain walk).
- Same-user, same-namespace sandboxes able to write the user's directory are equivalent to writing the user's dotfiles; out of scope.

### 4.6 Kernel Patch: Mount-Namespace Change Counter

`struct mnt_namespace` already keeps `event`, bumped on every mount-tree change (it is what makes `poll()` on `/proc/<pid>/mountinfo` report `POLLPRI`). `sw/linux` carries a small patch exposing it as a `__u64 event` field appended to `struct mnt_ns_info` returned by the existing size-versioned `NS_MNT_GET_INFO` `ioctl`. The reader uses it when the reported size includes it, and the `listmount` comparison otherwise. Exact layout follows upstream `nsfs` conventions at implementation time; the patch is suitable for upstream submission.

### 4.7 v5 → v6 Code Map

| v5 | v6 |
| :--- | :--- |
| `fswc.c` (~4,100 lines) + `fswc.h` (~290) | `fswc-read.c` (map, validate, `fswc_lookup`; linked into `rtld` and `libc`), `fswc-build.c` (`libc` only), small `fswc.h`. Target well under 1,500 lines total. |
| Merged Virtual Trie (hash table, `vdir`s, `vchildren`, postings) | **Delete**; replaced by the sorted `paths[]` array. |
| `fswc_glob_try` / `fswc_walk_pkg_vdir` reimplementing glob semantics | **Delete**; `glob()` uses internal `GLOB_ALTDIRFUNC` hooks. |
| `__fswc_resolve_pkg_wild_relpath` in `dl-load.c` / `execvpe.c` | **Replace** with per-package `fswc_lookup`; existing wildcard parsing, ordering, `FNM_PERIOD`, `AT_SECURE`, `DF_1_NODEFLIB`, `errno`, and fallback logic stays. |
| Per-call `fswc_hash_mount_tree` | **Replace** with §4.3 validation. |
| `ns_*` / `blob_*` / `pkg_*` tiers, `GL` slot table, cross-DSO futex, fork hooks, write-once snapshots | **Delete**; one `idx-*` file, per-process read-only mapping. |
| Builder inside `dlopen` / `glob` / `execvpe` | **Move** to `__libc_early_init`. |
| `mode=2`, `__fswc_probe_exact`, hooks in 11 single-path wrappers, 50 ms TTL, `mount`/`set*id`/`capset`/`setns` invalidation hooks | **Delete**; restore upstream. |
| Per-directory permission flags, `d_type` per posting, top-level non-SquashFS handling | Simplified to "sealed or ask the kernel" per package; `d_type` per posting kept. |
| `glibc.fswc.mode`, `glibc.fswc.max_inodes` | **Delete**; no tunables at all (`FSWC` is always on, Rule 2) and no size cap (§4.4). |

### 4.8 Tests

Every scenario compares `glob()`, `execvpe()`, and `dlopen()` against the reference walk (`glob()` with caller-supplied raw-syscall `GLOB_ALTDIRFUNC` hooks, Phase 2 step 1), in each state a real process can be in: **no index** (first process in a namespace), **valid index**, and **stale index** (`<prefix>` changed after the build). There is no off switch to compare against (Rule 2); the stale and missing states *are* the plain walk:

| Scenario | Expected |
| :--- | :--- |
| One-star and multi-star patterns, `**`, `GLOB_MARK`/`GLOB_ONLYDIR`/`GLOB_PERIOD`/`GLOB_CASEFOLD`/`GLOB_NOSORT`, non-`C` collation, caller-supplied `GLOB_ALTDIRFUNC` | Identical results; caller hooks bypass `FSWC` and are left untouched. |
| `mkdir`/`rmdir` in `<prefix>`, package unmounted, replaced, overmounted, bind-mounted writable | Validation fails or the name is unsealed; identical results. |
| `move_mount` swap of two packages (Fluffy kernel) | Counter changes; plain walk; identical results. |
| Directory symlink inside a package (`include/ncursesw -> .`), file traversed as directory | `KERNEL`; identical results and `errno`. |
| `0700`/`0111`/ACL directories inside a package | Package unsealed; `EACCES` preserved. |
| Index missing, truncated, corrupt, wrong owner/mode, symlinked, squatted | Plain walk; no crash. |
| 64 programs starting at once in a fresh namespace | Exactly one builds; all correct. |
| Mount change during a build | Build discarded. |
| `unshare -Ur` sandbox (in-namespace root) and a second user namespace reusing the same in-namespace UID, sharing the host's `/dev/shm` | Each builds and uses its own `.fswc-<euid>-<userns_id>` index; neither trusts or squats the other's or real root's; results identical. |
| Index left by a namespace that has since exited | Removed by the next build of a process with `CAP_SYS_ADMIN` in the same user namespace; an unprivileged build (to which `listmount` reports every other namespace as missing) removes it only once it is more than a day old. A live namespace's index is never removed by a privileged build, and at most once a day by an unprivileged one. |
| `unshare(CLONE_NEWUSER)` at the start of `main` right after a startup build | Succeeds. |
| `vfork()` + `execvp()`; static `libc.a` program | Never builds; correct. |
| `dlopen` on a `PTHREAD_STACK_MIN` thread | No overflow; `objdump` confirms every `FSWC` frame in `rtld` is `< 1 KiB`. |
| `AT_SECURE` program; user-namespace "root"; `seteuid()` mid-process | `AT_SECURE` reads its euid's index and never builds; namespace "root" never trusts real root's files; after `seteuid()` the next call uses the new euid's index. All results identical to the reference walker. |
| `execvpe()`/`posix_spawnp()` where the index proves every candidate absent | Returns `-1` with exactly the `errno` the plain walk produces (`ENOENT`, or a remembered `EACCES`/`ENOTDIR`), even though no `execve` was attempted (§2.7). |
| Package mounted after a process started, then `dlopen`/`glob`/`execvp` in that process | Validation fails; the new package is found (no per-process snapshot). |
| `LD_PRELOAD` interposition of `opendir`/`readdir`/`stat` (`kmod` `testsuite/path.so`) | Interposed functions still see the calls the plain walk would make, or the test suite's expectations are documented as `FSWC`-off (open question, §4.9). |

Mount scenarios run in an unprivileged user and mount namespace (`support_become_root`) with tmpfs mounts, and a test-only internal hook treats every directory of a test prefix as sealed. Only the real sealing rules need real SquashFS mounts, which no unprivileged test can create; `tst-fswc-real` checks them wherever `/sw` already holds SquashFS packages (`world`, a booted system). A Go program performing the same walk serves as an extra oracle in CI where a Go toolchain is available.

**Coverage (2026-11-17).** Checks shown to fail against a deliberately broken build: non-directory entries treated as packages, a too-long candidate ending its element, the eviction bound of the listing, mount validation disabled, the index used under `LD_DEBUG`/`LD_AUDIT`, and the sweep deleting live indexes. The other new cases have not been sabotaged one by one. One fix is exercised but not observable: `ld.so`'s overflow of its per-element buffer passes the oracle even under malloc checking, because `ld.so` allocates from libc's own malloc, which the preloaded checker does not interpose; that fix rests on review.

- `tst-fswc-oracle` (and `tst-fswc-oracle-static`, the same test linked statically): every probe against the reference walk, in fresh processes, in the states none, valid, stale, a 16-process build stampede, six damaged indexes, `LD_DEBUG=libs` and `LD_AUDIT` (the log must show every package tried, so the index was not used), 8 threads with fork while another process keeps rebuilding the index, and the mount rows (package replaced, unmounted, mounted inside, remounted unchanged, prefix mounted over). Workers run under `libc_malloc_debug.so` with `MALLOC_CHECK_=3`, so an overflow of a block from `malloc` (glob's, say; `ld.so`'s own allocations bypass the checker) aborts them. The threads state runs without it: the checker's lock is not fork-safe.
  - The prefixes: the main tree (odd names: space, colon, UTF-8, an invalid byte, `NAME_MAX` bytes; non-package entries of every kind; a package nested past the builder's 64 levels; one holding a path longer than `PATH_MAX`; FIFO, socket, dangling and looping symlinks inside packages); `wide` and `jumble` (2,800 and 600 entries, overflowing every listing buffer, the second with random name lengths and order); `deep` (candidates past `PATH_MAX`, and longer than the 256-byte prefix limit, so never indexed); a prefix that can be searched but not listed; a prefix through a symlink.
  - The elements: literal and wildcard; trailing and doubled slashes; `*` last; relative (`*/bin`, `./*/bin`); directly under `/`; two `*`s; no candidates at all. Commands are run three ways: `execvpe` after `fork`, `posix_spawnp`, and `execvpe` after `vfork`.
- `tst-fswc-startup`: in a user and mount namespace with a tmpfs over `/sw`, a static program never builds, a dynamic one builds a `0400` file owned by its euid, a valid index is left alone, a change rebuilds it, the sweep keeps live namespaces' indexes and removes dead ones (privileged: at once; unprivileged: after a day), and a read-only or full `/dev/shm` leaves no index and no temporary file.
- `tst-fswc-real`: on a real `/sw` only.

**Still untested without privileges:** `AT_SECURE` (needs a set-user-ID program owned by another uid); an index or directory owned by another user (a user namespace maps a single uid); the sealing rule that a group- or ACL-readable directory is not sealed (needs a second uid or gid); real SquashFS sealing outside `world`. These need the VM or a privileged runner.

### 4.9 Open Questions

1. **Cold-build cost per namespace** (§4.4). First measurement (2026-11-17, scratch tree): a full build over 60,602 entries in 100 test-sealed packages takes 27 ms on tmpfs with a warm cache; SquashFS with a cold cache will be slower. If it is too high, profile before choosing any remedy.
   - **Incremental rebuild, designed but deferred** (owner: "it's not like mounts change a ton"). A sealed package is a read-only mount whose unique mount ID is never reused within a boot, and a mounted SquashFS cannot change, so a package with the same name and mount ID as in the previous (stale) index has the same listing. Record each package's mount ID in its `fswc_top` entry; on rebuild, copy unchanged packages' entries from the old index and walk only new or changed ones. An upgrade of one package would then walk one package. It does not help a new mount namespace (copied mounts get new IDs); reuse across namespaces would key on the superblock and runs into the identity problems of §2.5.
2. **Long-lived processes.** v6 validates per call, so correctness holds, but nothing tells a daemon that the index was rebuilt. Arm-then-poll on mountinfo was dropped implicitly, not by decision.
3. **Reaching the namespace without `/proc`.** `PIDFD_GET_MNT_NAMESPACE` (6.11) was discussed as the path to the namespace fd for `NS_MNT_GET_INFO`; §4.6 should name the exact sequence. `NS_MNT_GET_INFO` struct extensibility is intent, not verified kernel API.
4. **Stack budget.** Rule 4 targets < 1 KiB per `rtld` frame; v5 sits at ~1.1 KiB (an earlier target was < 512 B). v6's reader should be measured against the rule, not assumed.
5. **`LD_PRELOAD` interposition.** Whether `glob()`'s internal `GLOB_ALTDIRFUNC` hooks call interposable symbols, which `kmod`'s test shim relies on.
6. *(Resolved.)* **Tcl `GLOB_MOUNTS` reversal.** The project owner once proposed a mount table of `{mountpoint, vfs ops, userdata}` behind a new flag, then rejected it (Rule 8) for three reasons: it blew out the implementation complexity; Tcl's VFS is in practice only used for zip files; and Tcl can do it itself by hooking the `GLOB_ALTDIRFUNC` callbacks for its own volumes and falling back to a plain callback-free `glob()` when a pattern falls through to the native filesystem. Recorded so it is not re-proposed.
7. **No VM harness** exists yet for Phase 3's kernel-patch gate.
8. *(Resolved 2026-11-17.)* **Brace-scoped `GLOB_PATHS` lists and the vfork-safe `execvp` route.** Settled by redefining `GLOB_PATHS` as strict search lists shared with `execvp` and `ld.so` (§3.2): `{list}/NAME` splits at the last `}/`, `GLOB_BRACE` is irrelevant, an empty element is `.` before NAME is attached, and the walker needs no `malloc`, locks, or locale. `errno` parity is the walker's job in `execvp`.

---

## 5. Per-Package Modifications & Test Suite Recommendations

*Note (2026-11-17): the per-package notes below predate the §3.2 redefinition of `GLOB_PATHS` as strict search lists. Where they describe bracket-, brace-, or escape-aware `:` splitting, the new rule supersedes them; each package is updated when its consumer moves to the shared semantics. Done so far: `bash`, `readline`, `tcl` (Phase 2, "Step 8 prepared").*

Every package below is modified from unmodified upstream source to participate in Fluffy's `<glob.h>` / `GLOB_PATHS` / late-bound `/sw/*` architecture. Each entry specifies **(1) Pre-v5 Prototype Baseline**, **(2) Target Ideal State**, and **(3) Upstream + Fluffy Test Suite Requirements** for `CHECK()`.

**Where Fluffy's tests live (2026-11-16).** Ad hoc test code no longer lives in recipe `CHECK()` functions. Each package's Fluffy tests are in its own test suite, added by `sw/<pkg>-<ver>-fluffy-test.patch`, and `CHECK()` just runs upstream's check target:

| Package | Tests |
| :--- | :--- |
| `binutils` | `ld/testsuite/ld-fluffy/fluffy.exp` |
| `coreutils` | `tests/env/env-glob-path.sh`, `tests/sort/sort-compress-glob-path.sh` |
| `man-db` | `src/tests/manpath-glob-config-path` |
| `which` | `tests/which-glob-path.sh` (new `check-local`) |
| `util-linux` | `tests/ts/misc/glob-paths` (`run.sh … misc/glob-paths`) |
| `readline` | `tests/inputrc-glob.{c,sh}` (new `check`) |
| `ncurses` | `progs/check-terminfo-dirs.sh` (`make -C progs check`) |
| `e2fsprogs` | `lib/support/tst_profile_glob.sh`, `misc/tst_conf_glob.sh` |
| `dejagnu` | `testsuite/runtest.libs/utils_which.test` |
| `sqlite` | `test/autosetup-split-path.sh`, `test/sqlite3-smoke.sh` (new `check`) |
| `iproute2` | `testsuite/unit/` (`make check-unit`) |
| `openssl` | `test/recipes/25-test_fluffy_glob.t` + `test/fluffy_glob_test.c` |
| `curl` | `tests/data/test3150`, `test3151` + `tests/test3150.pl` |
| `gcc` | `gcc.dg/fluffy/fluffy.exp` (`include-*.c`, `missing-include-dirs.c`, `zlib-zstd-run.c`), `g++.dg/fluffy/*.C`; skip list replaced by `-fno-pie`/`-fno-stack-protector` dg-options, xfails and reasoned dg-skip-ifs; `lib/g++.exp` no longer needs a hand-written `testsuite_flags` |
| `libstdcpp` | same `gcc-16.2.0-fluffy-test.patch`: `testsuite_flags.in` `-L`, standalone-build lookup in `testsuite/lib/libstdc++.exp` (no symlink) |

Rules for these tests:
- They must not depend on the host. A check that is only meaningful against a populated live prefix reports UNSUPPORTED, never a silent pass.
- Each one has been run against unpatched code and shown to fail.
- New executable test files use git-style `new file mode 100755` hunks, because a plain `-Naur` diff cannot set the exec bit, and some runners (`util-linux` `run.sh`) silently skip non-executable tests.

---

### Group A: Core C Library & Toolchain

#### 1. `glibc` (`sw/glibc`, `sw/glibc-pass1` — v2.44)
- **Current State** (`sw/glibc-2.44-fluffy-source.patch`, `sw/glibc-2.44-fluffy-test.patch`):
  - High-bit `<glob.h>` / `<fnmatch.h>` flags implemented; `__GI_glob64` hidden alias fixed in `sysdeps/unix/sysv/linux/glob.c`; NSS/DNS stateless `/sw/*/etc/...:/etc/...` fallback (`nss_database.c`, `nss_files_fopen.c`, `nss_files_data.c`, `files-*.c`, `res_hconf.c`, `res_init.c`, `resolv_conf.c`); `paths.h` `_PATH_DEFPATH = "/sw/*/bin"`.
  - `FSWC` v5 (`include/fswc.h`, `sysdeps/unix/sysv/linux/fswc.c` compiled into `rtld` and `libc`, writable `GL` slot table, three-tier `/dev/shm/.fswc-<uid>/` artifacts, `glibc.fswc.mode=0|1|2`, `__fswc_probe_exact` hooks in 11 single-path wrappers). Stack frames reduced to ~1.1 KiB via `mmap` workspaces so `elf/tst-dl-path-buf{,-mem}` pass.
- **Target Ideal State** (`FSWC` v6, §4):
  - Replace `fswc.c` with `fswc-read.c` (map, validate, `fswc_lookup`; `rtld` + `libc`) and `fswc-build.c` (`libc` only, called from `__libc_early_init`); sorted-path index per `(euid, userns, mntns, prefix)`; §4.3 validation; no tunables (always on, Rule 2) and no size cap.
  - `glob()` supplies internal `GLOB_ALTDIRFUNC` hooks (real directory reads, `FSWC`-backed `lstat`/`stat`) when the caller supplies none; delete `fswc_glob_try` and the trie.
  - **Delete** `mode=2`, `__fswc_probe_exact`, and all hooks in `open`/`open64`/`openat`/`openat64`/`*_nocancel`/`access`/`faccessat`/`fstatat64`/`statx`, the 50 ms TTL, the `mount`/`set*id`/`capset`/`setns` wrapper invalidation hooks, the `GL` slot table, and the `__libc_fork`/`_Fork` hooks.
  - Fix the 3 `GLOB_PATHS` corner cases in `posix/glob.c` (per-segment `GLOB_NOCHECK`/`GLOB_NOMAGIC` forwarding, single `GLOB_DOOFFS` initialization prior to segment `0`, and single-component-bracket + brace-aware `next_colon_sub` under `GLOB_BRACE`), non-terminal `<dir>/**/<rest>` and terminal `<literal_dir>/**` (`GLOB_CASEFOLD`) trailing-slash normalization plus symlink-to-directory root prefix traversal under `GLOB_GLOBSTAR`, `GLOB_TILDE` `"~"` `getenv("HOME")` buffer copying before any in-place `dirname` mutation, `GLOB_CASEFOLD` literal-pattern `GLOB_MAGCHAR` isolation, `GLOB_PERIOD` intermediate-directory parity in every `FSWC` state, `glob_dirscan`'s backslash-escape skip under `GLOB_EXTMATCH`, and `posix/glob_internal.h`'s unconditional `extmatch = 1` leak; guard `tst-rtld-run-static` under `ifeq (yes,$(use-ldconfig))` in `elf/Makefile`.
  - Replace `__fswc_resolve_pkg_wild_relpath` in `elf/dl-load.c` and `posix/execvpe.c` with per-package `fswc_lookup`, keeping the existing behavioral details (`FNM_PERIOD` on leading-dot top-level names, `AT_SECURE` `is_trusted_path_normalize`, `DF_1_NODEFLIB`, exact `errno` across skipped packages, escape- & bracket-aware `PATH` splitting, literal `S_ISDIR` `PATH` directories, `ENOEXEC` `scripts_argv`).
  - Make `confstr(_CS_PATH)` (`getconf PATH`) report `_PATH_STDPATH` rather than upstream's `/bin:/usr/bin`, which does not exist on Fluffy (§2.7).
- **Test Suite Recommendations** *(all tests must be host-independent and `PATH=""`-safe: synthetic prefixes in private mount namespaces, self-contained static test executables, `<paths.h>` `_PATH_DEFPATH`/`_PATH_STDPATH`, zero hardcoded `/sw`, `/snap`, `/bin/sh`, or `system()`)*:
  - **Upstream Suite (`CHECK()`)**: `TIMEOUTFACTOR=4 make -O -j$(nproc) check` (specifically gating `check-abi`, `conform/*/linknamespace` including `conform/ISO11/threads.h/linknamespace` and `conform/POSIX/*/linknamespace`, `posix/tst-gnuglob`, `posix/tst-glob-tilde`, `posix/globtest`, `posix/tst-fnmatch`, `posix/tst-execvp1..4`, `posix/tst-execveat`, `posix/tst-spawn*`, `elf/tst-dlopen*`, `elf/tst-dl-path-buf{,-mem}`, `nss/tst-fluffy-stateless-etc`).
  - **Fluffy `make check` Tests (`sw/glibc-2.44-fluffy-test.patch`)**:
    1. `posix/tst-glob-fluffy-flags.c`: Exhaustive unit tests for `GLOB_PATHS` (empty segments, escaped `\:` and `\\:`, colons inside `[a:b]`, `@(a:b)`, and `{/a:/b,/c}`, `GLOB_DOOFFS`, per-segment `GLOB_NOCHECK`/`GLOB_NOMAGIC`, per-segment `LC_COLLATE` ordering across `C` and `en_US.UTF-8`), `GLOB_KEEP_SLASHES`, `GLOB_EXTMATCH`, `GLOB_CASEFOLD`, `GLOB_SKIPDOTS`, `GLOB_GLOBSTAR`, and `GLOB_DOTDOT` / `FNM_DOTDOT`.
    2. `posix/tst-fswc-oracle.c`: the §4.8 matrix rows that need no mounts, comparing `glob`, `execvpe`, and `dlopen` against the reference walk (`glob()` with raw-syscall hooks) with no index, a valid index, and a stale index (no off switch, Rule 2) (sealed trees simulated through a test-only internal hook).
    3. `posix/tst-fswc-edge.c` (internal test, `tests-internal`): corrupt, truncated, foreign-owned, symlinked, and squatted index files; non-normalized paths; symlinked and file-as-directory components; permission-restricted packages.
    4. `posix/tst-fswc-startup.c`: 64-program startup stampede, mount change during build, `unshare(CLONE_NEWUSER)` after a startup build, `vfork()` + `execvp()` and static `libc.a` (never build), `AT_SECURE`.
    5. `elf/tst-fswc-stack`: `objdump` frame-size assertion for `rtld` and cold/warm `dlopen` on a `PTHREAD_STACK_MIN` thread.
  - **Privileged runner (`tools/test-fswc`)**: the §4.8 mount rows (real SquashFS images, `mkdir`, unmount, replace, overmount, bind mounts, and `move_mount` on Fluffy's kernel).
  - **Standalone Benchmark (`bench-fswc`)**: see Phase 0.

#### 2. `binutils` (`sw/binutils`, `sw/binutils-pass1`, `sw/binutils-pass2` — v2.47)
- **Pre-v5 Prototype Baseline** (`sw/binutils-2.47-fluffy-source.patch`):
  - Embedded 3,286-line `include/fluffy-cache.h` and called `fc_expand_dirs` / `fc_lookup_path` in `ld/ldfile.c`; recipe passes `--with-lib-path='=/sw/*/lib'` (`genscripts.sh` copies `--with-lib-path` into the default linker scripts verbatim—it only prepends `=` to its own built-in directories, and only under `--with-sysroot`—so the explicit `=` is what makes the emitted `SEARCH_DIR("=/sw/*/lib")` sysroot-relative). Also recursively called `ldfile_add_library_path` on `globbuf.gl_pathv[i]`, which would re-glob or infinite-recurse if a matched directory name contained `[`, `*`, or `?`.
- **Target Ideal State**:
  - **Delete `include/fluffy-cache.h` and `ldfile_try_open_bfd` `fc_lookup_path` hunks completely (-3,295+ LOC)**.
  - Keep `ld/ldfile.c:ldfile_add_library_path`'s `=` / `$SYSROOT` (`ld_sysroot`) prefix expansion **before** a literal `stat(name, &st) == 0 && S_ISDIR(st.st_mode)` fast check (so existing literal `-L` directories whose names contain `[1]`, `*`, or `?` are preserved intact!) followed by a ~15-line `<glob.h>` (`glob(name, GLOB_ONLYDIR, NULL, &gl)`) expansion when `strpbrk(name, "*?[") != NULL`, appending each matched directory directly to `search_tail_ptr` via a non-recursive literal helper (falling back to the literal `name` on `GLOB_NOMATCH`, never re-invoking `=`/`$SYSROOT`/glob expansion on `globbuf.gl_pathv[i]`, and using only standard `GLOB_ONLYDIR` so `binutils-pass1` compiles cleanly against any bootstrap host `<glob.h>` before `glibc-pass1` exists). `glibc` `FSWC` accelerates the startup `glob()` transparently while Linux's RCU `dcache` serves exact probes.
- **Test Suite Recommendations**:
  - **Upstream Suite (`CHECK()`)**: `make -k check` — require zero unexpected failures across all 5 DejaGnu suites (`binutils`, `gas`, `ld`, `libctf`, `libsframe`).
  - **Fluffy Regression Tests (`sw/binutils-2.47-fluffy-test.patch` or `CHECK()`)**:
    1. Verify `ld --verbose` default linker script contains `SEARCH_DIR("=/sw/*/lib")`.
    2. Link binaries **without** `-L` or `-rpath-link` verifying both direct `-l` and `ldelf.c` secondary `DT_NEEDED` resolution succeed via wildcard `SEARCH_DIR("=/sw/*/lib")`: (a) against live `/sw/*/lib` (`-lstdc++ -lz -lzstd`, resolving `libstdc++.so`'s indirect `DT_NEEDED` on `libgcc_s.so.1` in `/sw/libgcc/lib` and `libm.so.6` in `/sw/glibc/lib` without introducing a `binutils <-> readline` `BUILD_NEEDS` cycle), (b) with `--sysroot="$td"` across separate `$td/sw/pkg_top/lib/libfluffy_sysroot_top.so` → `$td/sw/pkg_dep/lib/libfluffy_sysroot_dep.so.1` directories (using unique library names absent from live `/sw/*/lib`), (c) `-L` wildcard expansion over a sysroot/directory containing `[1]`, and (d) literal `-L"$td/lit[1]/lib"` precedence over sibling `$td/lit1/lib`.

#### 3. `gcc` (`sw/gcc`, `sw/gcc-pass2` — v16.2.0)
*Superseded 2026-11-18 (the notes below are history):* gcc-pass1 is stock gcc with absolute paths (see "Nothing linked against the build host's C library…" in NOTES.md), so the patch serves only gcc-pass2 and gcc, which link Fluffy's glibc. It is now one rule in three funnels: `add_prefix` (`gcc.cc`), `do_add_prefix` (`file-find.cc`) and `add_path` (`incpath.cc`) each wrap upstream's function, renamed `*_1`, and add one entry per result of `glob (path, GLOB_PATHS | GLOB_NOMAGIC)`. Only a whole `*` component is a wildcard, so a literal `[1]` in a sysroot needs no escaping and no `stat` comes first; upstream's sysroot, `iprefix` and `PATH`-splitting code is untouched. `add_sysroot_to_chain` expands a user's `=`/`$SYSROOT` directory once the sysroot is known, and the driver finds a bare `argv[0]` with `glob ("{" PATH "}/" NAME, GLOB_PATHS)`. Gone: `escape_glob_meta`, three copies of a bracket-aware `:` splitter, the sysroot duplicates, the `cppdefault.cc` and `MD_EXEC_PREFIX` hunks (gcc-pass1 only) and the `inhibit_libc` hunk (gcc-pass1 only). The source patch went from 1,209 lines to 255.
- **Pre-v5 Prototype Baseline** (`sw/gcc-16.2.0-fluffy-source.patch`):
  - Embedded 3,282-line `include/fluffy-cache.h` and hooked `fc_lookup_path` / `fc_inc_dir_can_skip` / `fc_expand_dirs` into `gcc/incpath.cc`, `gcc/file-find.cc`, `gcc/gcc.cc`, and `libcpp/files.cc`, alongside build/config wildcard hunks in `gcc/Makefile.in`, `gcc/configure`, and `gcc/cppdefault.cc`. Also recursively called `add_path` / `add_prefix` / `do_add_prefix` on `gbuf.gl_pathv[gi]`, which would re-glob if a matched directory name contained `[`, `*`, or `?`.
- **Target Ideal State**:
  - **Delete `include/fluffy-cache.h` and all `fc_*` calls across `gcc/incpath.cc`, `gcc/file-find.cc`, `gcc/gcc.cc`, and restore `libcpp/files.cc` to 100% unmodified upstream source (-3,350+ LOC)** (avoiding post-hash `file->path` mutation in `libcpp/files.cc`, relying on `FSWC` for `glob(GLOB_ONLYDIR)` startup expansion and Linux's RCU `dcache` for `maybe_shorter_path` `lstat`s and `open_file` `open`s).
  - Retain the clean `<glob.h>` (`glob(..., GLOB_ONLYDIR, ...)`) wildcard expansions in `gcc/incpath.cc` (`add_path` + `add_sysroot_to_chain` for deferred `-I =...` / `-I $SYSROOT...`, checking `stat(path, &st) == 0 && S_ISDIR(st.st_mode)` before `glob()` — including on unescaped `iprefix`/`sysroot` candidates in `add_standard_paths` prior to `escape_glob_meta` — so existing literal `-I`/`-iprefix`/`--sysroot` directories containing `[1]`/`*`/`?` work directly, falling back to `add_literal_path` on `GLOB_NOMATCH` when `user_supplied_p` is true so `-Wmissing-include-dirs` still fires, splitting `CPATH`/`C*_INCLUDE_PATH` with escape- & single-component bracket-aware `:` scanning, and calling `update_path` on unescaped prefixes before escaping metacharacters in `iprefix`/`sysroot`/relocated prefixes), `gcc/gcc.cc` (`add_prefix`, `add_sysrooted_prefix`, `add_sysrooted_hdrs_prefix` — checking literal `S_ISDIR` before `glob()`, calling `update_path` before `escape_glob_meta` on `target_system_root`, splitting `COMPILER_PATH`/`LIBRARY_PATH`/`LPATH` with escape- & single-component bracket-aware `:` scanning, and dispatching matched/literal prefixes via `add_literal_prefix` without re-running `update_path` on `glob` matches — plus `do_spec_2` multi-word `MD_EXEC_PREFIX` used by `gcc-pass1` and `gcc-pass2`), and `gcc/file-find.cc` (`do_add_prefix` + escape-/bracket-aware `prefix_from_string`, checking literal `S_ISDIR` before `glob()` and preserving reverse `first` insertion order!), inserting matched `gbuf.gl_pathv` entries via non-recursive literal helpers (never re-globbing matched directory names, and using only standard `GLOB_ONLYDIR` so `gcc-pass1` compiles cleanly on any bootstrap host `<glob.h>` before `glibc-pass1` exists), plus the `gcc/Makefile.in`, `gcc/configure`, and `gcc/cppdefault.cc` cross/header hunks.
- **Test Suite Recommendations**:
  - **Upstream Suite (`CHECK()`)**: `make -k check` (DejaGnu `gcc`, `g++`, `libstdc++`, `libgomp`, `libatomic`, `libitm`), specifically inspecting `gcc.dg/cpp/*` (`#include_next` across multiple `/sw/<pkg>/include` mounts!) and `g++.dg/pch/*` (precompiled headers).
  - **Fluffy Regression Tests (`sw/gcc` `CHECK()`)**:
    1. Compile, link, and run C and C++ programs pulling `<iostream>`, `<zlib.h>` (`-lz`), and `<zstd.h>` (`-lzstd`) from separate SquashFS mounts with **zero `-I` and zero `-L` flags**.
    2. Add explicit `#include_next <stdlib.h>`, literal `-I"$td/lit[1]/include"` vs `$td/lit1/include`, and `-Wmissing-include-dirs -Werror` on unmatched `-I"$td/nonexistent_inc[1]"` checks verifying `libstdc++` → `glibc` header chaining and literal/diagnostic parity.

---

### Group B: Interactive Shells, Readline & Core Language Runtimes

#### 4. `bash` (`sw/bash`, `sw/bash-pass1` — v5.3)
- **Pre-v5 Prototype Baseline** (`sw/bash-5.3-fluffy-source.patch`):
  - Already deleted bundled `lib/glob/{glob.c,glob_loop.c,gmisc.c}` (-1,849 LOC)!
  - `pathexp.c` (`shell_glob_filename`, `shell_glob_path`), `findcmd.c` (`find_user_command_in_path`, `find_in_path_element`), `bashline.c` (`command_word_completion_function`), `shell.c` (`#include "pathexp.h"`, sourcing `/sw/*/etc/profile:/etc/profile`), and bundled `lib/readline/bind.c` all delegate directly to `glibc` `glob()` with `GLOB_PATHS`, `GLOB_EXTMATCH`, `GLOB_GLOBSTAR`, `GLOB_SKIPDOTS`, `GLOB_DOTDOT`, `GLOB_CASEFOLD`.
- **Target Ideal State**:
  - Keep current clean architecture, ensuring `pathexp.c` (`shell_scan_path_colon`, `shell_glob_path`, and `shell_run_path_glob`) splits `PATH` colons with single-component bracket/escape/extglob awareness matching `glibc` `next_colon_sub` (bounding unclosed `[...]` and `@(...)` groups at `'/'` and honoring nested `[:..:]`/`[...]`/`[=..=]`) and expands leading `~` per `:` segment via `bash_tilde_expand` (escaping glob metacharacters in the expanded home directory) so unexported `HOME` and `$HOME` metacharacters behave identically across literal `~/bin`, wildcard `~/*/bin`, and `compgen -c`; verify zero remaining dead prototypes from `lib/glob/glob.h` once `FSWC` lands.
- **Test Suite Recommendations**:
  - **Upstream Suite (`CHECK()`)**: `make tests` (specifically gating `run-glob-test`, `run-glob-bracket`, `run-globstar`, `run-extglob`, `run-extglob2`, `run-extglob3`, `run-type`, `run-complete`).
  - **Fluffy Regression Tests (`tests/glob.tests` & `CHECK()`)**:
    1. Command lookup (`type -P`, `hash`), `PATH=/sw/*/bin` empty-segment `:` handling (`PATH=:/sw/*/bin`), and `compgen -c` completion across `/sw/*/bin`.
    2. Login shell profile discovery order across `/sw/*/etc/profile:/etc/profile`.
    3. Interactive/script parity on `shopt -s globstar extglob dotglob nocaseglob globskipdots nullglob failglob`.

#### 5. `readline` (`sw/readline` — v8.3)
- **Pre-v5 Prototype Baseline** (`sw/readline-8.3-fluffy-source.patch`, plus `test_rl.c` `CHECK()` harness in `sw/readline`):
  - Patches `bind.c` (`_rl_read_init_file`) to expand `"/sw/*/etc/inputrc:" SYS_INPUTRC` with `glob(..., GLOB_PATHS | GLOB_NOESCAPE, ...)`, loading vendor inputrc files first so `/etc/inputrc` overrides last, and supports colon-delimited `INPUTRC` / `rl_read_init_file()` paths, but checks `strchr(filename, ':') != 0` *before* trying a literal open (which would split a literal user filename containing `:` and map leading/trailing empty `:` segments to `"."`).
- **Target Ideal State**:
  - Pass `-DSYS_INPUTRC='"/sw/*/etc/inputrc:/etc/inputrc"'` from build `CPPFLAGS` (eliminating the hardcoded `"/sw/*/etc/inputrc:"` C literal and `reading_sys_inputrc` guard in `bind.c`, and likewise in `bash`'s bundled `lib/readline/bind.c`). When `filename` contains no glob wildcards (`*?[`), try `_rl_read_init_file_single(filename, 1, include_level)` **first** so literal filenames containing `:` open directly, falling back to `glob(filename, GLOB_PATHS | GLOB_NOESCAPE | GLOB_TILDE, ...)` only when `filename` contains `*?[` or (`:` with `ENOENT` on the literal open), and skip `S_ISDIR` matches (`"."` from empty `:` segments).
- **Test Suite Recommendations**:
  - **Existing + Extended `CHECK()` in `sw/readline`**: Keep `sw/readline`'s `test_rl.c` harness asserting `rl_read_init_file("$td/sw/*/etc/inputrc:$td/etc/inputrc")` vendor-then-`/etc` override precedence, and extend it with assertions for a literal filename containing `:` (`"$td/my:inputrc"`), `~` tilde expansion (`"~/.inputrc:$td/sw/*/etc/inputrc"`), and leading/trailing empty `:` safety (`":$td/sw/*/etc/inputrc:"`).

#### 6. `python` (`sw/python`, `sw/python-pass1` — v3.14.7)
- **Pre-v5 Prototype Baseline** (`sw/Python-3.14.7-fluffy-source.patch`, `sw/Python-3.14.7-fluffy-test.patch`):
  - Exposes minimal `posix._glob(pathname)` (`GLOB_NOESCAPE | GLOB_KEEP_SLASHES`) and `_getpath.glob`; `Lib/glob.py` only fast-paths `glob.glob()` when `root_dir is None and dir_fd is None and not recursive and not include_hidden` and `isinstance(pathname, str)`.
  - Repeats 4 separate manual `:`-splitting + `glob` loops across `Lib/os.py` (`get_exec_path`), `Lib/shutil.py` (`which`), `Modules/getpath.py`, and `Lib/site.py` (using `any(c in p for c in '*?')`, which misses `[...]` character classes, and in `site.py` `glob.glob("/sw/*")` matches `/sw/*.squashfs` regular files as bogus prefixes!).
  - **Live Frozen-Module Bug**: `Modules/getpath.c` executes frozen bytecode from `Python/frozen_modules/getpath.h`. Because `sw/python` applies patches with `patch -Z -Np1`, `Modules/getpath.py` keeps the exact same `mtime` as `getpath.h`, so `make` skips `_freeze_module` (`test_getpath.py` passes by reading `getpath.py` from disk while `libpython3.14.so` runs unpatched `getpath.h`!).
- **Target Ideal State**:
  1. **Re-freeze `Modules/getpath.py` in `sw/python` & `sw/python-pass1`**:
     - Run `touch Modules/getpath.py` after `patch -Z -Np1` (or `make regen-frozen` during build) so `Programs/_freeze_module` regenerates `Python/frozen_modules/getpath.h` deterministically.
  2. **Upgrade `posix._glob(pattern, flags=0, root_dir=None)`**:
     - Accept both `str` (`PyUnicode_FSConverter` / `os.fsencode` `surrogateescape`) and `bytes`, plus `flags` (`GLOB_NOESCAPE`, `GLOB_KEEP_SLASHES`, `GLOB_PATHS`, `GLOB_ONLYDIR`, `GLOB_MARK`, `GLOB_GLOBSTAR`, `GLOB_PERIOD`, `GLOB_DOTDOT`, `GLOB_SKIPDOTS`, `GLOB_CASEFOLD`, `GLOB_BRACE`), while always firing both `sys.audit("glob.glob", pathname, recursive)` and `sys.audit("glob.glob/2", pathname, recursive, root_dir, dir_fd)` in `Lib/glob.py` prior to delegation (`test_glob` / `test_audit`).
     - When `root_dir is not None` (and `dir_fd is None` and `pathname` is relative), normalize redundant `/` runs in `root_dir` (`//tmp/dir[1]//sub///` → `/tmp/dir[1]/sub`, `///` → `/`) before prefixing and stripping the normalized `root_dir` prefix on output (so `glibc` `glob()` directory recursion or `GLOB_CASEFOLD` never mismatches `root_dir`; if `pathname` is absolute, ignore `root_dir` per Python semantics). Whenever `(flags & GLOB_NOESCAPE)` and normalized `root_dir` contains any glob metacharacter (`*`, `?`, `[`, or `:` under `GLOB_PATHS`, `(` under `GLOB_EXTMATCH`, `{`/`}` under `GLOB_BRACE`, or leading `~` under `GLOB_TILDE*`), backslash-escape `root_dir`, double literal `\` in `pattern`, and clear `GLOB_NOESCAPE` for that `glob()` call so `glibc` `glob()` treats `root_dir` as literal `GLOBPAT_BACKSLASH` (never calling `opendir()` on `0111` execute-only ancestors of `root_dir`, never invoking `fnmatch` on `surrogateescape` raw bytes in `root_dir`, and never brace-splitting `{`/`}` under `GLOB_BRACE`) while keeping `GLOB_NOESCAPE` intact for metacharacter-free `root_dir`s like `/sw` so `glob()`'s `FSWC`-backed existence checks apply directly. When `GLOB_KEEP_SLASHES` is active and `pattern` contains unclosed `[` (`pat_has_magic && !(gl_flags & GLOB_MAGCHAR)`), collapse multiple trailing slashes on matched entries to a single `'/'` to match `iglob`.
     - Delegate `Lib/glob.py:glob()` to `posix._glob` for non-empty NUL-free `str` patterns (with `root_dir` `None` or NUL-free non-`bytes`) across `root_dir` and `include_hidden=True` (`GLOB_PERIOD | GLOB_DOTDOT`) whenever `dir_fd is None`, `pathname` contains no lone surrogates (`\ud800`–`\udfff`, checked via UTF-8 encodeability plus UTF-8 filesystem encoding when non-ASCII), `?`, `[!` / `[^`, `[:` / `[.` / `[=`, or non-ASCII `[...]` bracket expressions (preventing `glibc` `fnmatch` `EILSEQ` single-byte fallback from diverging from `iglob` on `surrogateescape` patterns or filenames mixing multi-byte UTF-8 with undecodable raw bytes), the pattern does not invoke `recursive=True` on `**` (because `test_glob.py:test_recursive_glob` requires `**` to follow symlinked directories, unlike Bash's cycle-free `GLOB_GLOBSTAR`) or contain `//` in `pathname.rstrip("/")`, and any `[a-z]`/`[]-z]` bracket range runs under `C`/`POSIX` `LC_COLLATE` (`bytes` patterns likewise stay on `iglob` because CPython sets UTF-8 `LC_CTYPE` where `glibc` treats `?` as multibyte UTF-8 whereas `iglob`/`fnmatch` treats `bytes` as single ISO-8859-1 bytes, while `posix._glob` remains directly available for both `str` and `bytes`).
  3. **Clean Up the 4 Path-List Consumers Respecting Exact Python Contracts**:
     - `Lib/os.py:get_exec_path()`: Split Unix `PATH` with single-component bracket-aware `:` scanning (so `[[:alpha:]]` / `[.coll.]` are never split mid-bracket while unclosed `[:` stops at `]`) and expand wildcard segments (`*`, `?`, `[`) via `posix._glob(..., GLOB_NOESCAPE)` while **strictly preserving `''` empty segments** (`PATH=':/bin'` → `['', '/bin']`, `PATH=''` → `['']`, **not** `'.'`, which `test_os` and `shutil.which` distinguish!).
     - `Lib/shutil.py:which()`: Split Unix `PATH` with bracket-aware `:` scanning and reuse `posix._glob` for wildcard segments (`str` and `bytes`, including `[...]`) while preserving `''` vs `'.'` return prefix formatting (`'cmd'` vs `'./cmd'`).
     - `Modules/getpath.py`: Split Unix `ENV_PATH` with bracket-aware `:` scanning (matching `_split_colon_path`) and expand wildcard directory entries (`*`, `?`, `[`) via `_getpath.glob(d)` before joining literal `program_name` (`joinpath(gd, program_name)`).
     - `Lib/site.py`: Expand wildcard entries in `PREFIXES` (`"/sw/*"`) directly via `posix._glob(prefix, GLOB_ONLYDIR | GLOB_NOESCAPE)` (**never** `import glob` or `re`/`fnmatch` at interpreter startup so `test_site.test_startup_imports` passes cleanly, while pruning `/sw/*.squashfs` regular files and keeping candidate `<pkg>/lib/python3.14/site-packages` entries even when `site-packages` does not yet exist, as required by `test_site.test_getsitepackages_wildcard`), and keep `"/etc/terminfo"` ahead of `/sw/*/share/terminfo` (split with bracket-aware `:` scanning, ignoring empty `:` segments) in `Lib/_pyrepl/terminfo.py` to match `ncurses`'s stateless-`/etc` override precedence.
- **Test Suite Recommendations**:
  - **Upstream Suite (`CHECK()`)**: `unset SOURCE_DATE_EPOCH && make test TESTOPTS="--timeout 120 ..."` (with both `Lib/subprocess.py` and `Lib/test/support/__init__.py` resolving `unix_shell` to `'/sw/bash/bin/bash'` when present and falling back to `'/bin/sh'` on hosts without `/sw`), explicitly gating `test_glob`, `test_fnmatch`, `test_pathlib`, `test_site` (`test_startup_imports` & `test_getsitepackages_wildcard`), `test_getpath`, `test_os`, `test_shutil`, `test_subprocess`, `test_pyrepl`.
  - **Fluffy Regression Tests (`sw/Python-3.14.7-fluffy-test.patch`)**:
    1. Real subprocess test launching `argv[0] = "python3"` (bare name without `/`) via `executable=f"{tmpdir}/python/bin/python3"` (symlinked to `sys.executable` so it runs cleanly during pre-install `make test` when `/sw/python` is not yet mounted, as well as post-install) with `ENV={"PATH": f"{tmpdir}/*/bin"}` to verify **compiled frozen `getpath.h`** resolves `sys.executable == f"{tmpdir}/python/bin/python3"`.
    2. `[...]` bracket wildcards and `''` vs `'.'` empty segments in `os.get_exec_path` and `shutil.which`, `root_dir` containing literal `[1]` metacharacters and redundant `//` slashes, `/sw/*.squashfs` exclusion in `site.getsitepackages`, `LC_ALL=C` and `surrogateescape` (`\udcc3*`, mixed multi-byte UTF-8 + raw byte filenames) `?`/`[é]` parity, and `bytes` + `recursive=True` + `include_hidden=True` parity.

#### 7. `perl` (`sw/perl`, `sw/perl-pass1` — v5.44.0)
- **Pre-v5 Prototype Baseline** (`sw/perl-5.44.0-fluffy-source.patch`):
  - Only patches hardcoded `/bin/sh` / `/usr` test/config references (29 lines). `ext/File-Glob/bsd_glob.c` still runs Perl's bundled 1,050-line BSD glob implementation (bypassing `glibc` `glob()` and `FSWC`), and `File::Spec::Unix::path()` (`dist/PathTools/lib/File/Spec/Unix.pm`) still does raw `split(':', $ENV{PATH})` without expanding `/sw/*/bin`.
- **Target Ideal State**:
  1. **Delegate `File::Glob` (`ext/File-Glob/bsd_glob.c`) to `glibc` `<glob.h>` with Exact CSH Semantics**:
     - Keep `bsd_glob.h` and `Glob.xs` ABI-untouched (`bsd_glob.h` defines its own `glob_t` and `GLOB_*` flags including opt-in `GLOB_QUOTE` and `GLOB_ALPHASORT`, with no `BG_ALTNOT`), isolating `<glob.h>` via `sys_glob_t` / saved `BG_*` enums inside `bsd_glob.c`.
     - Preserve BSD's ~80-line brace expander (`globexp1`/`globexp2`) and `globtilde` (`PerlEnv_getenv("HOME")` / `getpwuid`) so per-branch `GLOB_NOMAGIC` (`bsd_glob('{TES*,doesntexist*,a,b}', GLOB_BRACE | GLOB_NOMAGIC)` → `['TEST', 'a', 'b']`) and per-branch `GLOB_ALPHASORT` (`ci_compare` vs locale-independent ASCII `strcmp`) match csh semantics 100%, while delegating each `glob0` leaf pattern to `glibc` `glob()` (`SYS_GLOB_NOSORT` + `GLOB_MARK` / `GLOB_ERR` / `GLOB_NOCASE` → `GLOB_CASEFOLD`, so `/sw/*/bin/...` lookups get `glob()`'s `FSWC`-backed existence checks).
     - Translate `!(flags & GLOB_QUOTE)` by backslash-escaping literal `\`/`*`/`?`/`[`, rewrite unnegated `[^...]` to `[\^...]` (and inner `[:`/`[.`/`[=` to `\[...`) since `bsd_glob` only negates `[!...]`, and enforce `GLOB_LIMIT` (`ARG_MAX` → `GLOB_NOSPACE`) in `globextend`.
  2. **Patch `File::Spec::Unix::path()` (`dist/PathTools/lib/File/Spec/Unix.pm`)**:
     - Split `$ENV{PATH}` with single-component bracket-aware `:` scanning (so `[[:alpha:]]` is never split mid-bracket) and expand wildcard `PATH` entries (`/[*?[]/`) while normalizing empty segments to `"."` (matching upstream `File::Spec::Unix::path` lines `s/^$/./`) and keeping a `miniperl`-safe pure-Perl `opendir`/`readdir` fallback before XS `File::Glob` is built (also used when an entry contains `[:` or `[^` so POSIX character classes in `PATH` behave identically to `execvp`, wrapping regex compilation in `eval` so malformed bracket classes or reversed `[z-a]` ranges in `PATH` return non-matching cleanly rather than raising fatal regex exceptions).
  3. **Wildcard `@INC` / `PERL5LIB` / `otherlibdirs` Support (`perl.c:S_incpush` & `S_incpush_use_sep`)**:
     - Split `PERL5LIB`/`PERLLIB`/`otherlibdirs` on `PERLLIB_SEP` (`:`) using single-component bracket-aware scanning in `S_incpush_use_sep` (so `[[:alpha:]]` never pushes `"alpha"` from CWD into `@INC`), and expand wildcard entries (`*`, `?`, `[`) in `S_incpush` via `glob(..., GLOB_ONLYDIR | GLOB_NOESCAPE, ...)` — intentionally omitting `GLOB_PATHS` inside `S_incpush` so literal colons in `-IFoo::Bar2` (`t/run/switchI.t`) remain intact — and configure `-D otherlibdirs="/sw/*/lib/perl5/5.44/site_perl:/sw/*/lib/perl5/5.44/vendor_perl"` in `sw/perl` and `sw/perl-pass1`.
- **Test Suite Recommendations**:
  - **Upstream Suite (`CHECK()`)**: `TEST_JOBS=$(nproc) make test_harness`, specifically gating `ext/File-Glob/t/{basic,case,global,rt114984,rt131211,taint}.t`, `t/op/glob.t`, `dist/PathTools/t/Spec.t`, `cpan/IPC-Cmd/t/01_IPC-Cmd.t`, `cpan/ExtUtils-MakeMaker/t/*.t`.
  - **Fluffy Regression Tests (`sw/perl-5.44.0-fluffy-test.patch`)**:
    1. `File::Spec->path()` and `IPC::Cmd::can_run('bash')` with `local $ENV{PATH} = ':/sw/*/bin'` under both `miniperl -Ilib` and `perl`.
    2. `<"/sw/*/bin/perl">` → `('/sw/perl/bin/perl')`, `<"/sw/*/nonexistent">` → `()`, and `<"/sw/nonexistent_literal">` → `('/sw/nonexistent_literal')`.

#### 8. `tcl` (`sw/tcl` — v8.6.18)
- **Pre-v5 Prototype Baseline** (`sw/tcl8.6.18-fluffy-source.patch`, `sw/tcl8.6.18-fluffy-test.patch`):
  - `TclpFindExecutable` (`unix/tclUnixFile.c`) already uses `glob(p, GLOB_PATHS | GLOB_NOESCAPE, NULL, &g)`; `library/init.tcl` expands `/sw/*/lib` into `auto_path` and wildcards in `auto_execok`; `generic/tclFileName.c` adds `CanUseNativeMultiGlob` + `NativeMultiGlob`.
  - However, `TclFSIsPureNative()` disables native `glob()` process-wide whenever *any* secondary `Tcl_Filesystem` (`zipfs`, `simplefs:/`) is registered, and `CanUseNativeMultiGlob` rejects all `{a,b}` braces.
- **Target Ideal State**:
  1. **Drop `GLOB_MOUNTS` & Replace `TclFSIsPureNative()` with `TclFSPatternIsNative(pathPtr, pattern)` (~20 lines in `generic/tclIOUtil.c`)**:
     - Walk Tcl's registered `FilesystemRecord` list:
       - If only `tclNativeFilesystem` is registered, return `1` in $O(1)$.
       - If any registered non-native `Tcl_Filesystem` has `listVolumesProc == NULL` (an intercept-all wrapper like `testReportingFilesystem` in `tests/fileSystem.test`!), return `0` so VFS reporting/interception callbacks receive 100% of calls.
       - Otherwise (volume-scoped VFSes like `simplefs:/` or `//zipfs:/`), reject top-level `{...}` patterns when `pathPtr == NULL` if they contain `:` or any `/`-/ `~`-rooted alternative, join the resolved native base with leading metacharacter-free components of `pattern`, and verify the effective path starts with `/` (not `//`) and has no **bidirectional** path-component prefix overlap with any slash-rooted volume returned by `Tcl_FSListVolumes()` (so `glob /sw/...` stays native even when `/vfs/app` is mounted, while VFS submounts like `/sw/vfs_pkg` under `glob -directory /sw *` or `{simplefs:/a,b}/*` always route through Tcl's VFS layer).
  2. **Enable Safe `{a,b}` `GLOB_BRACE` in `CanUseNativeMultiGlob` & Harden `init.tcl` Wildcard Loops**:
     - Allow `{...}` **only** when braces are balanced, unnested, outside `[...]`, contain **at least one unescaped `,`**, and have non-empty alternatives none starting with `.` or `~` (unmatched `{` or empty `{}` must hit `DoGlob` so unmatched `{` raises Tcl's `"unmatched open-brace in file name"` `TCL_ERROR` rather than `glibc`'s `illegal_brace` literal fallback, and `{.foo,bar}` or `{~foo,bar}` would interact with `NativeMultiGlob`'s hidden-dot and tilde rules).
     - Keep Tcl's post-glob `NativeMatchType` check when `types != NULL` (`-types d`, `-types f`, `-types l`, perms) so non-directory type filters, `lstat`-based `-types l`, and permission masks (`r`/`w`/`x`) are enforced identically, keep `generic/tclPathObj.c:TclNewFSPathObj` unmodified (`if (addStrRep[0] == '~')` `[Bug 2806250]` guard intact alongside leaf `lastSlash[1] == '~'` handling in `TclpMatchInDirectory` so multi-component matches starting with `~` under `-directory` never escape into `$HOME`), bail out to Tcl's fallback matcher when a `[...]` bracket expression uses syntax where POSIX `fnmatch` diverges from `Tcl_StringCaseMatch` (`[!...]`, `[^...]`, `[]...]`, `[:`/`[.`/`[=`, or reverse `z-a` ranges), split `$env(PATH)` with `GLOB_NOESCAPE`-faithful single-component bracket-aware `:` scanning in `library/init.tcl:auto_execok` (`\` never escapes `:` or `]`), prefer `[file isdirectory $p]` before `glob`, trigger `glob` strictly on `*`/`?`/`[` via `string first` (never `string match {*[*?\[]*}`, since `\` is literal inside `[...]` in `Tcl_StringCaseMatch`) while escaping Tcl-only glob characters (`\`, `{`, `}`, and leading `~`), and pass `--` inside `catch {glob -nocomplain -types d -- $pattern} dirs` in `library/init.tcl` (`tcl_pkgPath` and `auto_execok`) so `-`-prefixed, `{a,b}`, or `\`-containing `PATH` segments match `TclpFindExecutable` (`GLOB_PATHS | GLOB_NOESCAPE`) and never raise uncaught Tcl exceptions.
- **Test Suite Recommendations**:
  - **Upstream Suite (`CHECK()`)**: `LC_ALL=C.UTF-8 make test`, specifically gating `tests/fileName.test` (braces, unmatched `{` error, `-types d` on symlinks-to-files vs. symlinks-to-dirs, `-tails`, `-directory`, `-path`), `tests/fileSystem.test` (`simplefs:/` **and** `testReportingFilesystem`), `tests/fCmd.test`, `tests/exec.test`, `tests/init.test` (resolving `/sw/bash/bin/bash` with `/bin/sh` fallback in `chanio.test`, `exec.test`, and `io.test` so `tcltest` runs cleanly on hosts with or without `/sw`).
  - **Fluffy Regression Tests (`sw/tcl8.6.18-fluffy-test.patch`)**:
    - Test `glob -nocomplain /sw/{bash,tcl}/bin/*` while `simplefs:/` is mounted, verify `catch {glob /sw/{unclosed}` still errors identically, verify trailing-`/` and `//` non-directory pruning (`glob .../a*/`, `glob -tails -directory ... a*/`, `glob pkg_a//bin/*`, `glob {[r]egfile/}`), and verify `auto_execok` with `env(PATH)=/sw/*/bin` (with unclosed `[:` stopping at `]` in `init.tcl`).

---

### Group C: Build Systems, Command-Search Utilities & Test Frameworks

#### 9. `make` (`sw/make` — v4.4.1)
- **Pre-v5 Prototype Baseline** (`sw/make-4.4.1-fluffy-source.patch`; note `sw/make-pass1` builds unpatched upstream):
  - Expands wildcard `PATH` elements in gnulib's `lib/findprog-in.c` using a manual `:` loop calling `glob(dir, 0, NULL, &g)`, and contains hardcoded `"/sw/*/bin"` and `"/sw/bash/bin/{sh,bash}"` C strings in `src/job.c` and `src/main.c`.
- **Target Ideal State**:
  - Simplify `lib/findprog-in.c` onto `glob(path, GLOB_PATHS | GLOB_NOESCAPE | GLOB_NOCHECK, NULL, &g)` (guarded with `#ifdef GLOB_PATHS`, and omitting `GLOB_ONLYDIR` so non-directory or unreadable literal `PATH` entries still reach `eaccess()` and preserve POSIX `ENOTDIR`/`EACCES` `failure_errno`), and replace hardcoded `"/sw/..."` strings in `src/job.c` and `src/main.c` with `<paths.h>` (`_PATH_DEFPATH`, `_PATH_BSHELL`).
- **Test Suite Recommendations**:
  - **Upstream Suite (`CHECK()`)**: `make check` (`./tests/run_make_tests.pl`), specifically `features/exec`, `variables/SHELL`, `functions/wildcard`, and `features/parallelism`.
  - **Fluffy Regression Tests**: Keep and expand the `features/exec` test running `make` with `PATH=/sw/*/bin` and un-overridden `SHELL` (verifying `USE_POSIX_SPAWN` fast-path spawns both `bash` recipes and direct commands without `/bin/sh`).

#### 10. `coreutils` (`sw/coreutils` — v9.11)
- **Pre-v5 Prototype Baseline** (`sw/coreutils-9.11-fluffy-source.patch`; note `sw/coreutils-pass1` builds unpatched upstream):
  - Patches gnulib `lib/findprog-in.c` (used by `env`, `nohup`, `timeout`, `nice`, `stdbuf`, `chroot`) with a manual per-element `glob()` loop.
- **Target Ideal State**:
  - Share the exact same `#ifdef GLOB_PATHS`-guarded `GLOB_PATHS | GLOB_NOESCAPE | GLOB_NOCHECK` `lib/findprog-in.c` implementation as `make` (preserving `ENOTDIR`/`EACCES` → exit status `126` vs. `ENOENT` → exit status `127` in `tests/misc/env.sh`).
- **Test Suite Recommendations**:
  - **Upstream Suite (`CHECK()`)**: `unset SOURCE_DATE_EPOCH && make RUN_EXPENSIVE_TESTS=yes check < /dev/null`, specifically gating `tests/misc/env.sh`, `tests/misc/nohup.sh`, `tests/misc/timeout.sh`, `tests/misc/nice.sh`, and `tests/misc/chroot-*.sh`.
  - **Fluffy Regression Tests**: Verify `PATH=/sw/*/bin env true`, `PATH=:/sw/*/bin timeout 5 bash -c exit`, and exit code `126` on `PATH=/sw/bash/bin/bash env non_existent_cmd`.

#### 11. `which` (`sw/which` — v2.25)
- **Pre-v5 Prototype Baseline** (`sw/which-2.25-fluffy-source.patch`):
  - Implemented a 75-line global static `active_glob` / `active_glob_idx` iterator inside `find_command_in_path` in `which.c`.
- **Target Ideal State**:
  - Replace the static `active_glob` state machine in `which.c` with a local pre-expanded path vector built in `path_search` per `PATH` element (resetting `path_containing_separator_given` and `found_path_starts_with_dot` at the start of every `path_search` call even when `PATH` is unset) using a bracket- and `\`-escape-aware `next_path_unit` splitter (preserving `:` inside `[...]` such as `[[:alpha:]]*` / `[.coll.]` and treating `PATH=""` as a single `""` → `"."` CWD segment per POSIX.1-2024 §8.3) + `tilde_expand` + `glob(unit, GLOB_SKIPDOTS, NULL, &g)` on wildcard elements (honoring `\c` backslash escapes identically to `bash` and `execvpe`, checking `skip_tilde` prior to `tilde_expand`, keeping literal `~/bin` un-globbed, backslash-escaping `*?[\` in an **expanded** home prefix on `~/*/bin` so `$HOME` containing `[1]` never misfires while passing unexpanded unquoted `~` prefixes containing wildcards like `~*/bin` directly to `glob()`, and removing all global static `glob_t` iterator state), preserving GNU `which`'s `--show-dot`, `--skip-dot`, `--show-tilde`, and `--skip-tilde` semantics as well as unexpanded `PATH` reporting in `print_fail`.
- **Test Suite Recommendations**:
  - **Upstream + Fluffy `CHECK()` (`sw/which`)**: `sw/which` currently runs minimal sanity checks; expand `CHECK()` to test:
    1. `PATH=/sw/*/bin ./which bash` → `/sw/bash/bin/bash`,
    2. `PATH=/sw/*/bin:/sw/*/bin ./which -a bash` (all-matches deduplication/ordering),
    3. `PATH=""` and `PATH=:/sw/*/bin ./which <local-exec-in-cwd>` (empty `PATH=""`, leading `:`, middle `::`, and trailing `:` segments resolving `./<cmd>`),
    4. `PATH='/sw/[b]ash/bin'`, `PATH='/sw/[[:alpha:]]*/bin'`, and `PATH='~*/bin'` (bracket, POSIX class, and unexpanded wildcard-tilde `PATH` segments without splitting on `:` inside `[...]`),
    5. Non-executable file skipped in favor of later executable match, and exit status `1` on missing command.

#### 12. `meson` (`sw/meson` — v1.12.0)
- **Pre-v5 Prototype Baseline** (`sw/meson-1.12.0-fluffy.patch`):
  - Uses `os.get_exec_path()` and `shutil.which()` for wildcard `PATH` resolution, `HAS_CFLAGS` / `HAS_LDFLAGS` system-library lookup, and missing-shebang script invocation rewrite (note: the historical patch accidentally embedded 108 foreign `.cpython-312.pyc` binary diffs).
- **Target Ideal State**:
  - Strip all 108 `__pycache__/*.cpython-312.pyc` binary diffs from `sw/meson-1.12.0-fluffy.patch` (leaving pure text diffs on the 8 `.py` source/test files with preserved upstream timestamps); zero `.py` logic changes needed in `meson` for globbing once Python's `os.get_exec_path()` / `shutil.which()` run on `posix._glob` + `FSWC`. Note `sw/libxcrypt` (`sw/libxcrypt-4.5.2-fluffy-test.patch`) similarly expands `path()` via Perl `glob($_)` and automatically inherits Perl's `<glob.h>` delegation.
- **Test Suite Recommendations**:
  - **Upstream + Fluffy Suite (`CHECK()`)**: `python3 -B -m unittest unittests/{internal,option,tap,version,cargo,data}tests.py` (matching `sw/meson` `CHECK()`, including `ExternalProgram` lookup under `PATH=/sw/*/bin`).

#### 13. `sqlite` (`sw/sqlite` — v3530400, `autosetup`)
- **Pre-v5 Prototype Baseline** (`sw/sqlite-3530400-fluffy.patch`; **note: `sw/sqlite` previously had no `CHECK()` function!**):
  - Patches `autosetup/autosetup` (`proc split-path`) to expand `[*?\[]` wildcard elements in `$PATH` via Tcl `glob -nocomplain -types d -- $part`.
- **Target Ideal State**:
  - Split `$PATH` with `GLOB_NOESCAPE`-faithful single-component bracket-aware `:` scanning in `autosetup/autosetup` (`proc split-path`, where `\` does not escape `:` or `]`), prefer `[file isdirectory $part]` before `glob`, trigger `glob` strictly on `*`/`?`/`[` via `string first` while escaping Tcl-only glob characters (`\`, `{`, `}`, and under `$::autosetup(istcl)` leading `~`), and guard `glob -nocomplain -types d --` (under `$::autosetup(istcl)`) or `glob -nocomplain --` + `[file isdirectory]` filtering (under bootstrap `jimsh0`, which lacks `-types`) with `catch` in `proc split-path` so `[[:alpha:]]`, `{a,b}`, `\`, or unmatched `{` in `$PATH` never misfires or aborts `autosetup`, accelerated by Tcl's `NativeMultiGlob` + `FSWC`, and add a `CHECK()` phase to `sw/sqlite`.
- **Test Suite Recommendations**:
  - **New `CHECK()` for `sw/sqlite`**:
    1. Verify `autosetup`'s `cc-check-progs` resolves tools (`cc`, `ar`, `strip`) when `PATH=/sw/*/bin` and `CROSS=""`.
    2. Run SQLite CLI smoke & FTS4/FTS5/JSON regression queries (`./sqlite3 :memory: "CREATE VIRTUAL TABLE t USING fts5(x); INSERT INTO t VALUES ('fluffy glob'); SELECT * FROM t WHERE t MATCH 'fluffy';"` — note full `make test` requires the separate Fossil tree rather than `sqlite-autoconf` amalgamation tarball).

#### 14. `dejagnu` (`sw/dejagnu` — v1.6.3) & `expect` (`sw/expect` — v5.45.4)
- **Pre-v5 Prototype Baseline** (`sw/dejagnu-1.6.3-fluffy-source.patch`, `sw/expect5.45.4-fluffy-source.patch`):
  - `dejagnu`: `proc which` in `lib/utils.exp` expands wildcard `$PATH` directories via Tcl `glob -nocomplain -types d`.
  - `expect`: TEA `configure` discovers `tclConfig.sh` and `tcl.h` across `/sw/*/lib` and `/sw/*/include` and sets `STTY_BIN=stty` via `PATH`.
- **Target Ideal State**:
  - Split `$PATH` with `GLOB_NOESCAPE`-faithful single-component bracket-aware `:` scanning (`\` does not escape `:` or `]`), prefer `[file isdirectory $raw_dir]` before `glob`, trigger `glob` strictly on `*`/`?`/`[` via `string first` while escaping Tcl-only glob characters (`\`, `{`, `}`, and leading `~`), and pass `--` inside `catch {glob -nocomplain -types d -- $pat} expanded` in `dejagnu`'s `lib/utils.exp` (`proc which`) so `[[:alpha:]]`, `-`-prefixed, `{a,b}`, `\`, or unmatched-`{` `$PATH` segments never misfire or raise uncaught Tcl exceptions, and keep `expect`'s minimal patch; both automatically accelerate via Tcl `NativeMultiGlob` + `execvp` `FSWC`.
- **Test Suite Recommendations**:
  - **`dejagnu` `CHECK()`**: `make check` (`launcher`, `libdejagnu`, `report-card`, `runtest.exp`) + test `which gcc` inside `runtest` with `PATH=/sw/*/bin`.
  - **`expect` `CHECK()`**: `make test` (`all.tcl`: `cat.test`, `expect.test`, `logfile.test`, `pid.test`, `send.test`, `spawn.test`, `stty.test`).

---

### Group D: Stateless-`/etc`, Crypto Trust Store & System Daemons/Utilities

#### 15. `systemd` (`sw/systemd` — v261.2)
- **Pre-v5 Prototype Baseline** (`sw/systemd-261.2-fluffy-source.patch`):
  - Expands `/sw/*/lib/systemd/{system,user,network,...}` and `/sw/*/etc/...` across `sd-path/path-lookup.c`, `basic/conf-files.c`, `shared/conf-parser.c`, `basic/os-util.c`, `basic/path-util.c`, `shared/condition.c`, and `core/load-fragment.c` via `safe_glob()` / `glob_extend()`, keeping `/etc/systemd/system` at highest precedence and setting `99-default.preset` to `disable *`.
  - **Hidden Cache-Bypass Trap**: Upstream `systemd`'s `safe_glob_full()` (`src/basic/glob-util.c`) unconditionally passes `GLOB_ALTDIRFUNC` with `readdir_no_dot` solely because standard `<glob.h>` lacked `GLOB_SKIPDOTS`—which would force 100% of `systemd`'s `safe_glob()` and `glob_extend()` calls to bypass `FSWC`!
- **Target Ideal State**:
  - Patch `src/basic/glob-util.c:safe_glob_full` (~4 lines) so when `opendir_func == NULL`, it calls `glob(path, flags | GLOB_SKIPDOTS, NULL, &g)` **without** `GLOB_ALTDIRFUNC` (keeping `GLOB_ALTDIRFUNC` only when a caller supplies a custom `opendir_func`), and pass `GLOB_ONLYDIR` in `src/basic/path-util.c:find_executable_in_element` (`safe_glob(target, GLOB_ONLYDIR, &matches)`) so non-directory glob matches never clobber `*last_error` with `-ENOTDIR`, unlocking full `FSWC` shared-memory acceleration across PID 1 unit/generator discovery, `conf-files.c`, `conf-parser.c`, `os-util.c`, `path-util.c`, and `condition.c`!
  - Move `"/sw/..."` vendor strings (`constants.h`, `path-util.h`, `path-lookup.c`, `os-util.c`, `hwdb-util.c`, `namespace.c`) behind a Meson `-D` prefix macro, while **never** flattening `basic/conf-files.c`'s basename-deduplicating merge (where `50-foo.conf` in `/etc` masks `/sw/<pkg>/lib/.../50-foo.conf` before sorting basenames across all directories), preserving `/dev/null` main-config masking in `shared/conf-parser.c`, escaping `root`/`rfd_path` metacharacters before `safe_glob`, replacing unmatched wildcard patterns in `sd-path/path-lookup.c`, and resolving `mount` via trusted system paths (`use_path_envvar=false`) rather than `$PATH` in `storagectl.c`.
- **Test Suite Recommendations**:
  - **Upstream + Fluffy Suite (`CHECK()`)**: `meson test -C build --print-errorlogs`, specifically gating the 5 Fluffy-patched unit tests: `test-path-util`, `test-path-lookup`, `test-condition`, `test-conf-files`, and `test-conf-parser` (verifying `/etc` overrides `/sw/<pkg>/etc` and `/sw/<pkg>/lib`, basename masking across directories, `.wants/` symlinks across `/sw/*/lib/systemd/system`, and `ConditionPathExistsGlob=` over `/sw/*`).

#### 16. `kmod` (`sw/kmod` — v34.2)
- **Pre-v5 Prototype Baseline** (`sw/kmod-34.2-fluffy.patch`, `sw/kmod-34.2-fluffy-test.patch`):
  - Patched `libkmod/libkmod-config.c` and `tools/depmod.c` to expand `/sw/*/{etc,lib}/{modprobe,depmod}.d` via `glob(path, GLOB_ALTDIRFUNC, ...)` unconditionally (so `kmod`'s `LD_PRELOAD` `testsuite/path.so` intercepts `opendir`/`stat` during `meson test`, at the cost of forcing production `modprobe`/`depmod` to bypass `FSWC`!), and hardcoded `"/sw/*/{etc,lib}/modprobe.d"` in `libkmod/libkmod.c`.
- **Target Ideal State**:
  - Configure `sw/kmod` with `--sysconfdir=/etc` (removing Meson's empty `$DESTDIR/etc` directories in `INSTALL()` so `/sw/kmod` ships zero `/etc` paths) and order `default_config_paths` (`libkmod/libkmod.c`) and `default_cfg_paths` (`tools/depmod.c`) per UAPI drop-in hierarchy: `SYSCONFDIR "/{modprobe,depmod}.d"` (`/etc/...`) → `"/run/{modprobe,depmod}.d"` → `VENDOR_PKG_PREFIX "/*/etc/{modprobe,depmod}.d"` → `"/usr/local/lib/{modprobe,depmod}.d"` → `DISTCONFDIR "/{modprobe,depmod}.d"` → `VENDOR_PKG_PREFIX "/*/lib/{modprobe,depmod}.d"` → `"/lib/{modprobe,depmod}.d"`.
  - Call standard `glob(path, GLOB_NOESCAPE, NULL, &gl)` in `libkmod/libkmod-config.c` and `tools/depmod.c` (omitting `GLOB_ONLYDIR` so explicit `-C '/etc/modprobe.d/*.conf'` file globs work, and falling back to literal `path` on `GLOB_NOMATCH` so explicit `-C` paths with unclosed `[` still load; production `modprobe`/`depmod` get full `FSWC` acceleration), add a ~15-line `glob`/`glob64` `ROOTFS`-prefix wrapper to `testsuite/path.c` (`LD_PRELOAD` test-only shim), and pass vendor config directories via Meson `-DCFLAGS` defines rather than C `"/sw"` literals (while still preserving `FSWC`'s `GLOB_ALTDIRFUNC` bypass for genuine callback callers).
- **Test Suite Recommendations**:
  - **Upstream + Fluffy Suite (`CHECK()`)**: `meson test -C build` (all 16/16 suites, specifically `test-blacklist` [`blacklist_fluffy_glob`, verifying `/etc` > `/run` > `/sw/*/etc` > `/sw/*/lib` precedence and `-C` single-file/wildcard configs] and `test-depmod` [`depmod_search_order_fluffy_sw`]).

#### 17. `dbus` (`sw/dbus` — v1.16.2)
- **Pre-v5 Prototype Baseline** (`sw/dbus-1.16.2-fluffy-source.patch`):
  - Expands `<include>` / `<includedir>` and `/sw/*/share/dbus-1/{system,session}.d` + `/sw/*/share/dbus-1/{system-services,services}` via `glob(..., 0, ...)` in `bus/config-parser.c` and `_dbus_split_glob_paths_and_append` in `dbus/dbus-sysdeps-util-unix.c` (currently contains hardcoded `"/sw/"` strings in `dbus-sysdeps-util-unix.c`).
- **Target Ideal State**:
  - Split `dirs` with single-component bracket-aware `:` scanning in `_dbus_split_glob_paths_and_append` in `dbus-sysdeps-util-unix.c` (skipping empty `:` segments in `XDG_DATA_DIRS` per the XDG Base Directory Specification—never mapping `""` to `"."`—and preserving `[[:alpha:]]` segments intact before appending `suffix` `"/dbus-1/services"`), pass `GLOB_ONLYDIR | GLOB_NOESCAPE` to the post-suffix `glob()` calls in `dbus-sysdeps-util-unix.c` and `<includedir>`/`<servicedir>` in `bus/config-parser.c`, deduplicate `<includedir>` and `<servicedir>` directories by `(st_dev, st_ino)` in `conf_dirs_find_dir()` and `service_dirs_find_dir()` so symlinked/relative aliases are not scanned or watched twice, and move Fluffy default search paths into Meson `-DDBUS_SYSTEM_CONFIG_DIRS` / build configuration rather than C literals.
- **Test Suite Recommendations**:
  - **Upstream + Fluffy Suite (`CHECK()`)**: `meson test -C build` (including the dedicated Fluffy test `test/internals/fluffy-config.c` verifying multi-package `/sw/<pkg>/share/dbus-1` service & policy merging, empty `XDG_DATA_DIRS` segment skipping, and `/etc/dbus-1` precedence).

#### 18. `util-linux` (`sw/util-linux` — v2.42.2)
- **Pre-v5 Prototype Baseline** (`sw/util-linux-2.42.2-fluffy-source.patch`; note `sw/util-linux-pass1` builds unpatched upstream):
  - Uses `GLOB_PATHS | GLOB_NOCHECK` in `disk-utils/fsck.c` (`fsck_path`), `libmount/src/context.c` (`search_path`), and `lib/configs.c` (`ul_configs_file_list`), plus `glob()` in `lib/logindefs.c` (`"/sw/*/etc/login.defs"`) and a 2-pattern `glob()` loop in `term-utils/agetty.c` (`"/sw/*/etc/os-release"`, `"/sw/*/lib/os-release"`). Note that in `lib/configs.c`, passing `GLOB_PATHS` on `usrdir` maps accidental empty `:` segments (`":/sw/*/etc"`) to `"."` (CWD).
- **Target Ideal State**:
  - Pass `GLOB_NOESCAPE` alongside `GLOB_PATHS` across `fsck.c`, `context.c`, `configs.c`, `logindefs.c`, and `agetty.c` (collapsing `agetty.c`'s 2-element loop onto a single `GLOB_PATHS | GLOB_NOESCAPE` call), strip empty `:` segments per-segment prior to `glob(GLOB_PATHS | GLOB_NOESCAPE | GLOB_NOCHECK)` in `lib/configs.c`, `disk-utils/fsck.c`, and `libmount/src/context.c` (preserving `:` inside `[...]` and preserving explicit `.` strictly at its own segment index, so `":/sw/*/bin:."` never injects CWD at index 0), and move default vendor search paths (`lib/configs.c`, `lib/logindefs.c`, `agetty.c`, `include/pathnames.h`) into configure/`CPPFLAGS` macros (zero `"/sw"` C literals).
- **Test Suite Recommendations**:
  - **Existing + Extended `CHECK()` in `sw/util-linux`**: Keep `sw/util-linux`'s `test_pathnames`, `fsck -T -N`, and `test_configs` (`--etc` / `--usr` precedence) assertions, add CWD-isolation checks (`--usr ":$td/sw/*/etc"` and `--usr ":$td/sw/*/etc:."` ignoring `./issue` ahead of `/sw/*/etc` while explicit `--usr ".:$td/sw/*/etc"` honors it), and run non-root `bash ./tests/run.sh --nonroot login findmnt` (note upstream `configure.ac` gates `BUILD_LIBMOUNT_TESTS` static-archive unit helpers on `--enable-static`, whereas `findmnt`'s 6 suites / 39 sub-tests exercise `libmount.so` directly under `--disable-static`).

#### 19. `shadow` (`sw/shadow` — v4.20.2)
- **Pre-v5 Prototype Baseline** (`sw/shadow-4.20.2-fluffy-source.patch`, plus multi-step `chpasswd`/`useradd`/`usermod` `-P` `CHECK()` in `sw/shadow`):
  - Globs vendor files across 4 files—`VENDOR_LOGINDEFS` (`"/sw/*/etc/login.defs"`) in `lib/getdef.c`, `VENDOR_GROUP_FILES` (`"/sw/*/etc/group"`) in `lib/groupio.c`, `VENDOR_PASSWD_FILES` (`"/sw/*/etc/passwd"`) in `lib/pwio.c`, and `vendor_{passwd,group}_glob` (`"%s/sw/*/etc/{passwd,group}"`) in `lib/prefix_flag.c`—plus sets `PATH=/sw/*/bin` in `lib/setupenv.c` and implements CoW initialization for `/etc/passwd`, `/etc/group`, and `/etc/shadow`.
- **Target Ideal State**:
  - Pass `VENDOR_LOGINDEFS`, `VENDOR_GROUP_FILES`, and `VENDOR_PASSWD_FILES` via `sw/shadow` `CPPFLAGS` and use `<paths.h>` `_PATH_DEFPATH` in `lib/setupenv.c` so zero `"/sw"` literals remain in C source; escape `*?[` glob metacharacters in the `--root` / `--prefix` `<pfx>` string before appending `VENDOR_*` and call `glob(pat, GLOB_NOESCAPE, NULL, &gl)` across all 4 files (`getdef.c`, `groupio.c`, `pwio.c`, `prefix_flag.c`) while keeping `def_load_file(def_fname)` literal (so `:` or `[1]` inside `--prefix <pfx>` never splits or misfires); allow `ENOENT` empty-open in `lib/commonio.c:commonio_open` strictly for `O_CREAT`, default system DBs (`!db->setname`), or `--prefix` system DBs (`db->prefix_db`), preserving `E_CANTOPEN` / `E_CANT_OPEN` (`exit 3`) on explicit nonexistent CLI file arguments in `pwck` and `grpck`; and CoW-materialize existing vendor `/sw/*/etc/group` supplementary group memberships (`gr_materialize_member`) before `gr_next()` in `src/usermod.c` (`update_group_file`) and `src/userdel.c` (`update_groups`) so removing, renaming, or deleting a user cleanly updates vendor-defined supplementary groups in `/etc/group`.
- **Test Suite Recommendations**:
  - **Existing + Extended `CHECK()` in `sw/shadow`**: Keep `sw/shadow`'s `chpasswd` / `useradd` / `usermod` `-P "$pfx"` CoW and `login.defs` override suite, verify `usermod -G ""`, `usermod -l`, and `userdel` CoW-materialize and update vendor-defined supplementary group memberships, verify `pwck -r` and `grpck -r` return `E_CANTOPEN` / `E_CANT_OPEN` (`exit 3`) on explicit nonexistent CLI paths while stateless `-P "$pfx"` read-only queries (`chage -l`, `pwck -r` without file args) succeed, and run it against a temp directory path containing `:` and `[1]` (e.g. `mktemp -d /tmp/shd_test_[1]:XXXXXX`) to verify prefix metacharacter safety across `getdef.c`, `groupio.c`, `pwio.c`, and `prefix_flag.c`.

#### 20. `e2fsprogs` (`sw/e2fsprogs` — v1.47.4)
- **Pre-v5 Prototype Baseline** (`sw/e2fsprogs-1.47.4-fluffy-source.patch`, plus `test_profile` `CHECK()` in `sw/e2fsprogs`):
  - Uses `glob(*fs, GLOB_PATHS, ...)` in `lib/support/profile.c` (`profile_init`), with `{"/etc/mke2fs.conf", "/sw/*/etc/mke2fs.conf", ...}` in `misc/mke2fs.c` and `e2fsck/unix.c` listed `/etc` **before** `/sw/*/etc` because `libprofile` uses **first-seen-wins** key semantics.
- **Target Ideal State**:
  - Change `glob(*fs, GLOB_PATHS, ...)` in `lib/support/profile.c:profile_init` to `glob(*fs, GLOB_NOESCAPE, ...)` (`profile_init_path` already splits colon-delimited path lists into `files[]`; passing `GLOB_PATHS` on single `files[]` elements like `MKE2FS_CONFIG` turns empty `:` segments into `"."`, causing `get_dirlist(".")` to parse every file in CWD as `mke2fs.conf`!), split path lists with single-component bracket-aware `:` scanning and skip empty `:` segments (`ent_len == 0`) in `lib/support/profile_helpers.c:profile_init_path` (upstream `PROFILE_LAST_FILESPEC` treats `""` as an array terminator and aborts before subsequent path entries!), pass vendor config paths via configure/`CPPFLAGS` defines rather than C `"/sw/*/etc/..."` literals, strictly preserve `libprofile`'s `/etc` → `/sw/*/etc` first-seen-wins ordering, and ensure `scrub/e2scrub{,_all}.in` prepend `/sw/*/bin:` to their fixed root `PATH`, `scrub/e2scrub_fail.in` sets `PATH=/sw/*/bin${PATH:+:${PATH}}` (never appending a trailing `:` when `PATH` is unset/empty), and all three source `@root_sysconfdir@/e2scrub.conf` before `/sw/*/etc/e2scrub.conf` and `/etc/e2scrub.conf`.
- **Test Suite Recommendations**:
  - **Existing + Extended `CHECK()` in `sw/e2fsprogs`**: Keep `sw/e2fsprogs`'s `test_profile` `/etc`-over-`/sw/*` assertions, add an empty-`:` CWD-isolation assertion (`test_profile ":$td/sw/*/etc/mke2fs.conf"` in a directory containing an invalid-syntax decoy file), verify end-to-end `MKE2FS_CONFIG="$td/sw/*/etc/mke2fs.conf" ./build/misc/mke2fs` + `E2FSCK_CONFIG="$td/sw/*/etc/e2fsck.conf" ./build/e2fsck/e2fsck -fn` on a scratch image, and run `make -C build/$d check` across all chroot-clean C unit suites (`lib/et`, `lib/ss`, `lib/e2p`, `lib/ext2fs`, `misc`, `e2fsck`, `debugfs`, `resize`; note `build/tests` hardcodes `#!/bin/sh`, `/bin/cat`, and `#!/usr/bin/env perl`, which is outside `sw/e2fsprogs`'s `/bin`-less, `perl`-free `BUILD_NEEDS`).

#### 21. `man-db` (`sw/man-db` — v2.13.1) & `groff` (`sw/groff` — v1.24.1)
- **Pre-v5 Prototype Baseline** (`sw/man-db-2.13.1-fluffy-source.patch`, `sw/groff-1.24.1-fluffy-source.patch`):
  - `man-db`: Uses `GLOB_PATHS | GLOB_NOESCAPE` in `lib/pathsearch.c` (`pathsearch` and `directory_on_path`) and `src/manp.c` (`"/sw/*/etc/man_db.conf:/etc/man_db.conf"`). Note `directory_on_path(dir)` compares `STREQ(gl.gl_pathv[i], dir)` against an absolute `dir`, which currently misses `"."` emitted by `GLOB_PATHS` for empty `:` segments (`xgetcwd()` needed) and drops non-existent literal `PATH` entries without `GLOB_NOCHECK`.
  - `groff`: Uses `GLOB_PATHS | GLOB_NOESCAPE` in `src/libs/libgroff/relocate.cpp` (`searchpath`) for executable/prefix relocation.
- **Target Ideal State**:
  - In `man-db`, pass `GLOB_PATHS | GLOB_NOESCAPE | GLOB_NOCHECK` in `directory_on_path()` while resolving `"."` via `xgetcwd()` before `STREQ`, and move `"/sw/*/etc/man_db.conf"` in `src/manp.c` into a `CPPFLAGS` macro. `FSWC` newly indexes `share/man` and `share/groff`, making `man <page>` instant without `mandb` cache regeneration.
- **Test Suite Recommendations**:
  - **`man-db` `CHECK()`**: `make check`, `manpath -g` `MAN_SYSTEM_CONFIG_PATH` vendor/override checks, and `MAN_SYSTEM_CONFIG_PATH="$PWD/src/man_db.conf" MANPATH=/sw/*/share/man ./src/man -w ls` (plus `MANPATH=` via `src/man_db.conf`'s `MANDATORY_MANPATH /sw/*/share/man`; passing `MAN_SYSTEM_CONFIG_PATH` since `/sw/man-db/etc/man_db.conf` is not yet installed during `CHECK()`) verifying late-bound manpage resolution across mounted packages.
  - **`groff` `CHECK()`**: `make check` (all ~190 `tmac`/`roff`/`preproc` tests).

#### 22. `iproute2` (`sw/iproute2` — v7.1.0)
- **Pre-v5 Prototype Baseline** (`sw/iproute2-7.1.0-fluffy-source.patch`; `sw/iproute2` `CHECK()` currently only runs `./ip/ip -V`!):
  - Uses `GLOB_PATHS | GLOB_NOESCAPE` across `lib/rt_names.c`, `lib/bpf_legacy.c`, `tc/tc_util.c`, `tc/m_ematch.c`, and `tc/e_bpf.c` to resolve `/sw/*/etc/iproute2:...:/etc/iproute2` (`rt_tables`, `rt_protos`, `rt_scopes`, `ematch_map`, `group`).
- **Target Ideal State**:
  - Pass `-DCONF_VENDOR_DIR='"/sw/*/etc/iproute2"'` via build `CFLAGS` (removing hardcoded `"/sw/*/etc/iproute2"` C literals across `lib/*.c` and `tc/*.c`), and upgrade `CHECK()` in `sw/iproute2` beyond `-V` so patched `rt_names.c` and `tc` config paths are actually exercised!
- **Test Suite Recommendations**:
  - **Upgraded `CHECK()` for `sw/iproute2`**: Test `ip` / `tc` table-name resolution (`rtnl_rttable_n2a(255, ...)` → `"local"`) against vendor `etc/iproute2/rt_tables` when `/etc/iproute2` is absent, and verify `/etc/iproute2` override precedence without requiring `CAP_NET_ADMIN`.

#### 23. `openssl` (`sw/openssl`, `sw/openssl-pass1` — v4.0.1) & `curl` (`sw/curl`, `sw/curl-pass1` — v8.23.0)
- **Pre-v5 Prototype Baseline** (`sw/openssl-4.0.1-fluffy-source.patch`, `sw/curl-8.23.0-fluffy-source.patch`):
  - `openssl`: Expands wildcards in `X509_LOOKUP_file` (`crypto/x509/by_file.c`, currently only on `X509_FILETYPE_DEFAULT` `SSL_CERT_FILE`, missing explicit `-CAfile` `X509_FILETYPE_PEM` loads!) and `X509_LOOKUP_hash_dir` (`crypto/x509/by_dir.c`) for `--openssldir=/etc/ssl` / `/sw/*/etc/ssl/certs/ca-certificates.crt` and `/sw/*/etc/ssl/certs`.
  - `curl`: Expands `ssl_cafile` and `ssl_capath` via `glob()` in `lib/vtls/openssl.c` (`ossl_load_trust_anchors`).
- **Target Ideal State**:
  - In `openssl` `crypto/x509/by_dir.c` (`add_cert_dir`), split colon-delimited lists with single-component bracket-aware `:` scanning and **preserve upstream's `if (len == 0) continue;` empty-segment skip** (**never** use `GLOB_PATHS` on `SSL_CERT_DIR`, which would map empty `:` segments to `"."` and inject CWD into the X.509 root CA trust store, and never split `[[:alpha:]]` mid-bracket!) while passing `GLOB_NOESCAPE | GLOB_ONLYDIR` on non-empty wildcard segments; extend `apps/lib/opt.c` (`case '/'` on `*CApath` options, where upstream `opt_isdir(arg)` rejected `:`-separated or wildcard `-CApath` CLI arguments before `libcrypto` saw them) to split with bracket-aware `:` scanning and validate wildcard `*CApath` arguments via `GLOB_NOESCAPE | GLOB_ONLYDIR` while skipping empty `:` segments; extend `crypto/x509/by_file.c` (`by_file_ctrl_ex`, `X509_load_cert_file_ex`, and `X509_load_crl_file`, plus CLI `apps/lib/apps.c:load_crls` for `-CRLfile`) so explicit `X509_FILETYPE_PEM` (`-CAfile` / `X509_STORE_load_file` / `X509_load_cert_file` **and** `curl` `--crlfile` / `--proxy-crlfile` via `X509_load_crl_file` + `openssl verify -CRLfile`, with literal regular-file precedence and `GLOB_NOMATCH` literal fallback) wildcard paths expand with `GLOB_NOESCAPE` just like `X509_FILETYPE_DEFAULT`; and extend `crypto/conf/conf_mod.c` (`CONF_get1_default_config_file`) so when `OPENSSL_CONF` is unset, `/etc/ssl/openssl.cnf` overrides first and `--openssldir='/sw/*/etc/ssl'` expands `OPENSSLDIR "/openssl.cnf"` via `glob(..., GLOB_NOESCAPE, ...)`.
  - Once `libcrypto`'s `X509_STORE_load_file`, `X509_load_crl_file`, and `X509_STORE_load_path` handle wildcards directly in `by_file.c` / `by_dir.c` (in both `openssl-pass1` and `openssl`), delete the redundant 65-line `glob()` wrapper in `curl`'s `lib/vtls/openssl.c` and bypass `src/tool_getparam.c`'s literal `existingfile()` `stat()` pre-check when `--cacert`/`--crlfile`/`--proxy-cacert`/`--proxy-crlfile` contain `*?[` (`-53 net LOC`, zero `<glob.h>` in `curl`, preserving `curl`'s `CURLE_SSL_CACERT_BADFILE` / `CURLE_SSL_CRL_BADFILE` error reporting when zero files match). `FSWC` newly indexes `etc/ssl/certs/*`.
- **Test Suite Recommendations**:
  - **`openssl` `CHECK()`**: `HARNESS_JOBS=$(nproc) make test` + self-contained CA/leaf/CRL + `<hash>.0` fixture check (`sw/openssl` builds before `sw/ca-certificates` and `/sw/ca-certificates` ships bundle PEMs rather than `<hash>.0` hash-dir links) running `./util/wrap.pl ./apps/openssl verify` with `-CApath ":$td/sw/*/etc/ssl/certs:$td/etc/ssl/certs"` (asserting wildcard vendor discovery **and** asserting an untrusted `<hash>.0` cert in CWD is rejected despite the leading `:`), `-CAfile "$td/sw/*/etc/ssl/certs/ca-certificates.crt"`, `-CRLfile "$td/sw/*/etc/ssl/crl/*.pem" -crl_check`, `SSL_CERT_FILE`/`SSL_CERT_DIR`, non-matching `-CAfile` failure, and default `CONF_get1_default_config_file()` wildcard/override resolution when `OPENSSL_CONF` is unset.
  - **`curl` `CHECK()`**: `make test-nonflaky TFLAGS="-n -j$(nproc)"` + loopback `openssl s_server` HTTPS verification smoke check exercising wildcard `--cacert "$td/sw/*/etc/ssl/certs/ca-certificates.crt"`, `--crlfile "$td/sw/*/etc/ssl/crl/*.pem"`, `--capath ":$td/sw/*/etc/ssl/certs"` (including leading-`:` CWD untrusted-cert rejection), non-matching `--cacert` `CURLE_SSL_CACERT_BADFILE` failure, and mounted `/sw/*/etc/ssl/certs/ca-certificates.crt` bundle loading.

#### 24. *Recommended New `GLOB_PATHS` Consumer*: `ncurses` (`sw/ncurses`, `sw/ncurses-pass1` — v6.6)
- **Current Gap**:
  - Python's `Lib/_pyrepl/terminfo.py` globs `/sw/*/share/terminfo`, but `sw/ncurses` is configured without `--with-terminfo-dirs`, so `libncursesw.so` only checks `/etc/terminfo` and `/sw/ncurses/share/terminfo`—missing third-party terminal definitions (`foot`, `kitty`, `alacritty`, `tmux`) mounted at `/sw/<pkg>/share/terminfo`.
- **Target Ideal State**:
  - Configure `sw/ncurses` (and `sw/ncurses-pass1`'s target build) with `--with-terminfo-dirs="/etc/terminfo:/sw/*/share/terminfo"` and expand wildcard segments in `ncurses/tinfo/db_iterator.c` (`_nc_first_db`, before `check_existence` filters `my_list`) directly into NUL-separated `my_blob` / `my_list` entries using single-component bracket-aware `:` splitting + `glob(..., GLOB_NOESCAPE | GLOB_ONLYDIR | GLOB_NOCHECK, ...)` (never re-joining/re-splitting expanded `gl_pathv` entries on `:`, so both `[[:alpha:]]` patterns and matched directory names containing `:` work cleanly while preserving `terminfo(5)`'s empty-`:` $\to$ `TERMINFO` mapping so leading/empty `:` never injects CWD), guarded with `#ifdef GLOB_PATHS` so `ncurses-pass1`'s host `tic` tool compiles cleanly on any unpatched host `<glob.h>`.
- **Test Suite Recommendations**:
  - **New `CHECK()` for `sw/ncurses`**: With `LD_LIBRARY_PATH="$PWD/lib"` (since `sw/ncurses` runs `CHECK()` before `INSTALL()` without `/sw/ncurses` mounted), compile `xterm-256color` via `./progs/tic -x -o "$td/default" -e xterm-256color misc/terminfo.src` and run `TERMINFO="$td/default" ./progs/infocmp xterm-256color >/dev/null`, then test `TERMINFO_DIRS="$td/etc/terminfo:$td/sw/*/share/terminfo" ./progs/infocmp custom-fluffy-term` against compiled `tic` fixtures under `$td/sw/pkgA/share/terminfo` and `$td/etc/terminfo` (plus leading-`:` `TERMINFO_DIRS=":$td/sw/*/share/terminfo"` from a CWD containing an untrusted terminfo tree), asserting vendor discovery, `/etc/terminfo` override precedence, and leading-`:` CWD isolation.

---

## 6. Phased Implementation Plan & Execution Gates

When executing this plan, follow these stages in strict order.

Phases 4–6 were completed against `FSWC` v5 and are independent of the v6 redesign; they remain listed for their gates and audit criteria. Phases 0–3 are the v6 work, followed by Phase 7. Item 2 of Phase 4 (auditing for upstream-changing "defensive" fallbacks) is still open.
- **Workflow rules**: Never run `sudo` directly from the agent (provide `sudo --preserve-env=FLUFFY,CROSS ./swctl build <pkg>` commands), always apply patches with `patch -Z -Np1`, and keep recipe `*_NEEDS` arrays alphabetically sorted, 4-space indented, with a blank line between `NEEDS` and `BUILD_NEEDS`.
- **Companion Bootstrap Recipe Checksum & Host-Build Rule**: Whenever a shared `*-fluffy-*.patch` file changes, update its SHA-256 checksum in **every** recipe that references it in `ARCHIVES=(...)` (`sw/glibc` + `sw/glibc-pass1`; `sw/binutils` + `sw/binutils-pass{1,2}`; `sw/gcc` + `sw/gcc-pass2` (+ `sw/libstdcpp` for the test patch); `sw/bash` + `sw/bash-pass1`; `sw/python` + `sw/python-pass1`; `sw/perl` + `sw/perl-pass1`; `sw/openssl` + `sw/openssl-pass1`; `sw/curl` + `sw/curl-pass1`; `sw/ncurses` + `sw/ncurses-pass1`; `sw/gawk` + `sw/gawk-pass1`; `sw/zlib` + `sw/zlib-pass1`). *Revised 2026-11-18:* code compiled against the bootstrap host's C library gets no Fluffy glob patches and uses absolute paths instead (gcc-pass1 now; `binutils-pass1` and `ncurses-pass1`'s host `tic` tool still carry standard-`glob()` code and are next). Everything else links Fluffy's glibc and uses `GLOB_PATHS` unconditionally, without `#ifdef` fallbacks.
- **Spec discipline**: if reality diverges from this document, stop and revise it before continuing. Review adversarially and revise "until you can't find any more flaws". Periodically rebuild from scratch "instead of assuming all our logic fixes are valid". Never disable a failing test; "brainstorm a proper fix at the proper place". Any patched behavior gets a test.
- **Sequencing**: finish a fully tested `world` build on the current implementation "before we rip the wiring out again". Every `glibc` patch change rebuilds everything downstream, so v6 phases land after the build converges.
- **Eventual patch form**: each package's changes become a clean, rebased commit series on the local upstream clones under `~/Source/github.com/fluffy-linux/` (`git format-patch`), reading as a coherent series rather than "initial impl, fix, fix, fix". Not started; patches remain the source of truth until then.
- **Patch regeneration**: regenerate patches with a pinned locale and timezone (`LC_ALL=C TZ=UTC`, except where an existing patch's file order was produced under another collation—keep each patch's established order) so regeneration never reorders hunks.

### Phase 0: Baseline Benchmark Harness (`bench-fswc`)
1. Build `bench-fswc` measuring, with the cache off and on (v5's `glibc.fswc.mode`; for v6, see the **off** state below):
   - Per-exec cost: syscalls and wall time from `execve` to `main` for a dynamically linked binary with 1, 7, and 15 `DT_NEEDED` libraries over a 100- and 300-package synthetic prefix.
   - **`make -j` storm**: a synthetic project compiling 500 translation units with the in-tree `gcc`, total wall time.
   - In-process latencies: `glob` (`/sw/*/bin/bash`, `/sw/*/bin/missing`, `/sw/*/{bin,include,lib}` with `GLOB_ONLYDIR`, `/sw/*/lib/python3.14/site-packages/*`, `/sw/*/share/terminfo/*/*`), `execvpe` `PATH` search, and `dlopen`, each as the plain walk (cache off), with a valid index, and with a missing or stale index.
   - Cold build time and index size.
2. Record baselines for the current v5 implementation and the plain walk.

**Harness** (`tools/bench-fswc.sh` driving `tools/bench-fswc.c`). It builds a synthetic `<prefix>` of N packages with 600 filler files each, never touching the host's `/sw`. Targets sit in the last packages, so every lookup crosses the whole prefix. It runs each measurement in three states:
- **off:** `glibc.fswc.mode=0`. This is v5's tunable. v6 has no off switch (Rule 2). Its "off" baseline is the same measurement run against upstream `glibc` through `--ldso`/`--libpath`, and its stale-index state comes from changing `<prefix>` after the build.
- **warm:** enabled, with the index pre-built.
- **cold:** the index directory is removed before each process.

It works with any FSWC version, through public interfaces only. Per-exec runs go through `--ldso`/`--libpath` with `<prefix>/*/lib` appended. With `--squashfs` (root, private mount namespace) each package becomes a mounted SquashFS image. Without it no package is sealed, so every state measures the plain walk plus FSWC's own overhead. `--storm` adds the 500-TU `make -j` storm and needs a compiler that expands `-I'<prefix>/*/include'`, which means Fluffy's `gcc`.

**Baseline 1: v5, unprivileged, plain directories** (2026-11-16, host kernel 7.0, glibc 2.44 + current patches built with host gcc 13; one run per cell, so treat differences under ~20% as noise):

| Measurement | 100 pkgs: off | 100 pkgs: v5 on (unsealed) | 300 pkgs: off | 300 pkgs: v5 on (unsealed) |
| :--- | ---: | ---: | ---: | ---: |
| `glob <prefix>/*/bin/bench-true` | 471 µs | 723 µs | 1,844 µs | 2,022 µs |
| `glob <prefix>/*/bin/missing` | 457 µs | 743 µs | 1,821 µs | 1,974 µs |
| `glob <prefix>/*/{bin,include,lib}` (`ONLYDIR\|BRACE`) | 953 µs | 1,279 µs | 3,272 µs | 3,498 µs |
| `glob …/lib/python3.14/site-packages/*` | 1.8 ms | 2.2 ms | 4.8 ms | 7.2 ms |
| `glob …/share/terminfo/*/*` (15k / 45k matches) | 16.1 ms | 16.8 ms | 35.7 ms | 59.4 ms |
| exec, 1 `DT_NEEDED` | 2.2 ms | 2.5 ms | 4.8 ms | 5.3 ms |
| exec, 7 `DT_NEEDED` | 9.7 ms | 12.9 ms | 31.4 ms | 30.6 ms |
| exec, 15 `DT_NEEDED` | 19.0 ms | 25.6 ms | 63.6 ms | 65.7 ms |
| syscalls, exec with 15 `DT_NEEDED` | 6,186 | 7,405 | 18,276 | 19,495 |
| `posix_spawnp` with `PATH=<prefix>/*/bin` | 716 µs | 996 µs | 2.6 ms | 1.4 ms |
| cold `dlopen` of a library in the last package | 3.1 ms | 1.9 ms | 4.2 ms | 6.1 ms |

What it shows:
1. **The plain walk is far outside the budget.** A 15-library exec costs 19 ms at 100 packages and 64 ms at 300, about 40–130× a normal exec. It grows linearly with packages × libraries, because `ld.so` probes every package for every `DT_NEEDED`. This is the workload FSWC exists for.
2. **v5 on a prefix it cannot seal is slower than off**, by roughly 10–50% at 100 packages. It pays the per-call mount-tree hash and still walks (§2.3 cost 2). v6's validation must cost about nothing when no package is sealed.
3. **Missing:** v5 *engaged*. That needs `sudo tools/bench-fswc.sh --squashfs …`, and it is the number v6 must beat.

### Phase 1: Remove Single-Path Hooks (`glibc`, `glibc-pass1`)
1. Delete `mode=2`, `__fswc_probe_exact`, its hooks in all 11 wrappers, the 50 ms TTL, `inval_gen`, and the `mount`/`set*id` wrapper invalidation hooks; restore those files to upstream.
   - *As implemented:*
     - **Restored to upstream:** the open/stat/access family (`access`, `faccessat`, `fstatat64`, `statx`, `open`, `open64`, `open_nocancel`, `open64_nocancel`, `openat`, `openat64`, `openat_nocancel`, `openat64_nocancel`), plus `umount2` and `nptl/setxid.h`.
     - **Deleted:** the added wrappers `capset`, `chroot`, `fsmount`, `mount`, `mount_setattr`, `move_mount`, `pivot_root`, `setfsgid`, `setfsuid`, `setns` and `unshare`. Their `syscalls.list` and `Makefile` entries are restored too. The `execve` line stays removed, because it belongs to the separate wildcard-`execve` feature.
     - **The 50 ms window was not `mode=2`-only.** `fswc_revalidate_snap` skipped revalidation within it for any non-forced call. It is replaced by "a slot already validated earlier in the *same* call (its seen-slot mask) is reused; everything else revalidates in full". Snapshots are immutable, so answers remain the plain walk at that earlier instant.
     - **The invalidation hooks were redundant once nothing skips revalidation.** Per-call `statx` of every ancestor (dev, ino, mount ID, ctime) plus the mount-tree hash and euid/ruid already catch `chroot`, `setns`, `unshare(CLONE_NEWNS)`, and `set*id`.
     - **Tests:** the tunable's maximum is now 1. The oracle, edge, and concurrency tests drop their `mode=2` passes and keep the `open`/`statx`/`access` `ENOENT` and cancellation-point checks, which now verify upstream behavior. `tools/test-fswc` asserts that single-path calls see external mounts *immediately* instead of "within 65 ms".
     - **Local pre-gate** (host gcc 13, `-Werror`, unprivileged user namespaces enabled):
       - `posix` 194 PASS and `elf` 546 PASS, identical to the unmodified v5 tree.
       - Every `tst-fswc-*` passes.
       - 9 failures occur identically in v5. They are host-build artifacts: `ldconfig`/cache tests exec `/sw/glibc/bin/ldconfig` inside the test container, plus `tst-vfork3` and `tst-tunconf1`.
       - Gate 1 proper is still `swctl build glibc` `CHECK()`.
     - **Pre-existing v5 race, out of scope for Phase 1:** a build racing a mount change may publish a snapshot that mixes states; v6's build re-check (§4.4 step 5) addresses it.
2. **Gate 1**: `glibc` `CHECK()` passes; `tst-fswc-oracle` passes unchanged (results were identical by design, so this is pure removal).

### Phase 2: `FSWC` v6 (`glibc`, `glibc-pass1`)

Order is tests first, then a reader, a builder, and consumers one at a time, deleting v5 code as each consumer moves. After each step the tree builds with `-Werror`, `posix` and `elf` match the Phase 1 results, and `tools/bench-fswc.sh` is re-run.

1. **Oracle first; the sealing hook comes with the reader and builder.** *(Revised 2026-11-17: the original step compared against an `enable=0` switch that Rule 2 rules out, and asked for a sealing hook in v5, which has no notion of "sealed".)*
   - Rewrite `tst-fswc-oracle` around a **reference walk** (decided 2026-11-17): the real `glob()` called with *caller-supplied* `GLOB_ALTDIRFUNC` hooks backed by raw syscalls (`syscall(SYS_openat)`, `SYS_getdents64` keeping `d_type`, `SYS_statx` with and without `AT_SYMLINK_NOFOLLOW`). Caller hooks bypass `FSWC` (v5's `fswc_glob_try` returns immediately; v6 by §4.1 and §4.8 row 1), and every Fluffy extension passes them down. Production is the same `glob()` with `FSWC`'s internal hooks (step 4), so the test compares **one matcher with two hook sets**: any difference is `FSWC`'s.
     - Why not a hand-written walker: reproducing `glob()`'s results needs a second matcher (ordering, `GLOB_PATHS`, `**`, `GLOB_PERIOD`, collation), i.e. failure mode R6 inside the test, which can disagree with `glob()` for reasons unrelated to `FSWC`.
     - The hooks count their calls and each reference walk asserts they ran, so a regression that routed caller hooks through `FSWC` cannot turn the reference into `FSWC` compared with itself.
     - Scope: the oracle checks only that `FSWC` never changes an answer. Whether `glob()`'s semantics are right is `tst-glob-fluffy-flags`'s job, with hand-written expectations.
     - Probes: `glob` patterns and flags under `C` and `en_US.UTF-8`, and `GLOB_PATHS` lists, comparing return value, every path, and `gl_flags` (minus `GLOB_ALTDIRFUNC`); `execvpe` and `posix_spawnp` `PATH` search; `dlopen` hits and misses with `LD_LIBRARY_PATH=<tree>/*/lib`.
     - Which file `execvpe` ran is observed through a tiny **static** helper that prints `getauxval(AT_EXECFN)`; every candidate is a hard link to it (static, so no host `ld.so`). Expected: the first executable regular file in reference order; misses expect `EACCES` if a non-executable candidate existed, else `ENOENT`. Which library `dlopen` loaded is `dlinfo(RTLD_DI_LINKMAP)->l_name`; expected is the first reference match in byte order (`ld.so` has no locale).
   - The walker runs over a **fixed synthetic tree** the test builds itself. No host prefix discovery from `/proc/self/mountinfo` (Rule 10, failure mode R2).
   - Drop the `open`/`stat`/`access` probes. Phase 1 made those calls upstream again, and `tst-fswc-vfork` plus `tst-glob-fluffy-flags` §10 already guard that single-path calls stay literal.
   - Against v5 this compares the walker with whatever state v5 happens to be in. On tmpfs that is always the plain walk, so it checks the oracle and our glob extensions, which is new coverage. It must pass before any v5 code is removed.
   - The test-only sealing hook (an internal `libc` entry point for `tests-internal`; not a tunable, not a public symbol) lands with steps 2–3. It builds an index for an arbitrary prefix and treats a tmpfs tree as sealed. From then on the oracle runs every probe in three states: no index, valid index (via the hook), and stale index (the tree changed after the hook built it).
2. **`fswc-read.c` (`rtld` + `libc`).**
   - Index format of §4.2. A bounds-checked map, done once per process.
   - Validation of §4.3: `statx(<prefix>)`, `listmount(<prefix_mnt_id>)`, `geteuid`. The counter comes in Phase 3.
   - `fswc_lookup(prefix, pkg, relpath)` returning `ABSENT/REG/DIR/LNK/KERNEL`.
   - Locating the index needs the mount-namespace ID, through `statmount(STATMOUNT_MNT_NS_ID)` on `<prefix>`'s mount, without `/proc`. Then `open` + `fstat` + `mmap`, about 5 syscalls once per process.
   - In `SHARED` builds, `rtld` owns the mapping and `libc` reaches it through one writable `GL()` pointer. This replaces v5's 16-slot table. Static `libc` maps its own copy.
   - Every frame stays under 1 KiB (`tst-fswc-stack`).
3. **`fswc-build.c` (`libc` only, `__libc_early_init`).** The §4.4 steps:
   - `flock` non-blocking;
   - record the state;
   - classify `<prefix>` entries as sealed or unsealed;
   - walk sealed packages with `getdents64` into `mmap` arenas;
   - sort;
   - re-check the state;
   - write to a temporary name, then `rename`.

   Prefixes come from build configuration (`user-defined-trusted-dirs`, `_PATH_DEFPATH`), never literals. The cold build cost and index size are measured here (§4.9 item 1); if the cost is too high, profile and fix the actual hot spot.
4. **`glob()` consumer.**
   - When the caller passed no `GLOB_ALTDIRFUNC`, `glob()` installs internal hooks: real `opendir`/`readdir`/`closedir`, and `lstat`/`stat` answered by `fswc_lookup` where it can (`KERNEL` falls through to the real call). The caller's `glob_t` fields are restored on return.
   - For `<prefix>/*/bin/bash` that is one `getdents64` of `<prefix>` plus 2–3 validation syscalls, instead of one `stat` per package.
   - Optional, gated on Phase 0 numbers: serve `readdir(<prefix>)` from `top[]` too, since validation already proves `<prefix>` unchanged.
   - Delete `fswc_glob_try`, the Merged Virtual Trie, and the `glob.c` Case A/B/C paths.
5. **The shared search-list walker; `execvpe()`/`posix_spawnp()` and `GLOB_PATHS` on it** *(decided 2026-11-17)*.
   - One walker in `fswc-read.c`, compiled into `libc` now and into `rtld` in step 6 (one source, as libgcc is one library linked everywhere; no copies). It expands one search-list element by the §3.2 rule and calls back for each candidate in order.
   - With a valid index it reads no directory and sorts nothing: the index's top-level names are already in byte order, and validation has just proved the prefix unchanged. Each candidate is one in-memory lookup (`<name>/<subpath>/<file>`), then the consumer acts on the hits. Without one it is the plain walk: `getdents64` of the prefix, drop dot names, byte-sort, probe in order.
   - No `malloc`, locks, or locale. Sorting without an index uses caller-provided memory: the stack in `execvp`/`posix_spawnp` (an `mmap` in a `vfork` child would leak into the parent), `mmap` in `rtld`.
   - `execvpe()`/`posix_spawnp()`: v5's private matcher, arena, and sort (about 1,000 lines of `execvpe.c`, failure mode R6) are deleted; `PATH` splitting becomes a plain `:` split. `errno` parity as §3.2.
   - `glob (…, GLOB_PATHS)`: elements go through the same walker; `glob.c` loses its bracket-, brace-, and extglob-aware colon scanner. The `GLOB_PATHS` cases in `tst-glob-fluffy-flags` are rewritten to the new rule; `tst-fswc-oracle` compares `execvpe` with `glob ("{" PATH "}/" name, GLOB_PATHS)` directly.
   - Measure `posix_spawnp` and `glob ("{PATH}/name")` at 100 packages before and after.
6. **`dl-load.c` consumer.**
   - Same replacement inside `rtld`. Keep `AT_SECURE`, `DF_1_NODEFLIB`, hwcaps subdirectories, and `errno` behavior.
   - Delete the `GL` slot table, mount-tree hashing, the `_Fork`/`fork.c` hooks, the cross-DSO futex, and the `rtld` builder (`dl-fswc.c`).
7. **Rework tests** per §4.8 and §5 `glibc`:
   - drop the v5-specific tier tests;
   - add `tst-fswc-startup` (64-program stampede, a mount change during the build, `unshare(CLONE_NEWUSER)` after a build, `vfork`/static never build, `AT_SECURE`);
   - add the privileged mount rows to `tools/test-fswc`, except `move_mount`, which waits for Phase 3.
8. **Gate 2:**
   - `glibc` `CHECK()` passes 100% under `swctl`;
   - `tools/test-fswc` mount rows pass on the host kernel;
   - `tst-fswc-stack` passes;
   - `bench-fswc` (sealed, `--squashfs`) shows at most 3 validation syscalls per call with a valid index;
   - a 15-library exec at 100 and 300 packages lands within an order of magnitude of a normal exec;
   - the `make -j` storm is faster than the plain walk;
   - `FSWC` totals under 1,500 lines.

**Progress (2026-11-17), in the scratch tree, not yet landed in `sw/`:**
- **Step 1 done.** `tst-fswc-oracle` rewritten: reference walk = `glob()` with raw-syscall caller hooks; fixed synthetic tree; `glob`, `execvpe`, `posix_spawnp` (static `AT_EXECFN` helper `tst-fswc-oracle-exec`), and `dlopen` (`tst-fswc-oracle-mod.so`, `RTLD_DI_LINKMAP`) probes; three states (no index, valid, stale) each in a fresh process, each *proved* through the test hook before probing. A guard exempts only the documented case where `glob()` never looks (`GLOB_NOCHECK`/`GLOB_NOMAGIC` on a pattern without metacharacters).
- **Steps 2–4 done for `glob()`.** New `include/fswc-index.h`, `fswc-internal.h`, `fswc-read.c`, `fswc-build.c` (about 1,100 lines with comments). `glob.c`'s v5 fast path (`fswc_glob_try`, `fswc_glob_on_snap`, the seen-mask threading; about 1,460 lines) is deleted; `glob.c` is 2,721 lines (v5: 4,185). `posix` check: 194 PASS, 1 FAIL (`tst-vfork3`, the known host artifact). Oracle passes in all three states.
- **Measured** (100 test-sealed packages × 600 files, median of 500): `glob <prefix>/*/bin/<hit>` 327 µs → 92 µs; `<prefix>/*/bin/missing` 325 → 90 µs; a 2,800-match walk 4.6 → 4.3 ms (readdir-bound, as expected).
- **Deviations from the text above, adopted:**
  - The namespace IDs come from `NS_GET_ID` (64-bit, never reused) on namespace fds reached through `pidfd_open` + `PIDFD_GET_USER_NAMESPACE`, and from `statmount(STATMOUNT_MNT_NS_ID)`; inode numbers can be reused, which would confuse the sweep.
  - Bounds: the header and section extents are checked once per mapping; each entry is bounds-checked when a lookup touches it. A whole-index pass (sortedness of 57k paths) would cost about a millisecond per process start. A corrupt or forged index can therefore give wrong answers but never read out of bounds; wrong answers from one's own index are already accepted (§4.5).
  - `glob()` does not swap hooks into the caller's `glob_t`. Its four internal stat points (`glob_lstat`, `is_dir`, `glob_testdir`, and the literal check) call one helper, `glob_fstatat`, that asks FSWC first when the caller gave no `GLOB_ALTDIRFUNC` hooks. Same behavior, nothing to restore. A per-thread context validates each prefix at most once per `glob()` call.
  - The builder declines (no index this time) when the prefix's ctime falls in the current tick of `CLOCK_REALTIME_COARSE`, instead of waiting.
  - The test hook is `__fswc_test_prefix (prefix, op)` with `op` check/build/remove, exported `GLIBC_PRIVATE` and reached by the oracle through `dlsym`, so the oracle stays an ordinary test.
  - Mounts: `mounts[]` lists every mount beneath the *prefix's own mount*. When the prefix is a plain directory on `/` (as in tests), unrelated mount changes anywhere invalidate the index; on Fluffy `/sw` is its own mount.
- **Step 5 done** (decided and built 2026-11-17). `GLOB_PATHS` redefined as strict search lists (§3.2). One walker, `__fswc_walk` in `fswc-read.c`, expands search-list elements for `execvpe`/`posix_spawnp` and for `glob (…, GLOB_PATHS)`, and will serve `ld.so` in step 6.
  - `execvpe.c` is upstream (204 lines) plus one branch for elements with a `*` component: 1,205 → about 300 lines. v5's private matcher, arena, sort, backslash unescaping, and raw `execve` are gone.
  - The mapping table is now write-once slots published with release semantics, so `execvp` after `vfork` and `posix_spawnp`'s child read indexes lock-free through `__fswc_index_peek` (never maps, never locks).
  - The walker reports candidates the index proves absent (hint `FSWC_ABSENT`), so `execvp` ends with exactly the plain walk's `errno`: `EACCES` if any candidate gave it, else the last candidate's error (`ENOENT` when an element has no candidates). Non-directory entries were candidates at first, so a search that missed ended in `ENOTDIR` whenever a plain file sorted last. The first v6 `world` caught it: upstream `tst-dlopenfail`, `tst-dlopenfail-2` and `tst-dlmopen-dlerror`, and Fluffy's `tst-glob-bz30635`, all failed under a real `/sw`. Now only directories are packages (§3.2), and the oracle's model and its new `dlopen`-miss check say so. A stale-`errno` bug (no candidates left `errno` untouched) was found by the rewritten `tst-fswc-edge`; the oracle now covers it with zero-candidate `PATH`s and a sentinel `errno`, and fails with the bug reintroduced.
  - Caller `GLOB_ALTDIRFUNC` hooks are honored under `GLOB_PATHS` through `struct fswc_lister`; `tst-gnuglob` exercises it.
  - Tests rewritten to the new rule: `tst-fswc-edge` 5c and 6b, `tst-glob-fluffy-flags` §2–6 and §10, the Fluffy cases in `tst-gnuglob-skeleton.c`. `tst-fswc-oracle` checks that `glob ("{PATH}/name", GLOB_PATHS)` lists exactly the candidates `execvpe` considers, in the same order. `posix` check: 194 PASS, 1 FAIL (`tst-vfork3`, known).
  - Measured (100 test-sealed packages, a name in none of them, median of 300): `posix_spawnp` 252 µs → 63 µs (mostly process creation now); `glob ("{PATH}/name", GLOB_PATHS)` 164 µs → 22 µs.
- **Step 6 done** (2026-11-17). `ld.so` searches elements with a `*` component through the same walker: every package in byte order, each with its `glibc-hwcaps` subdirectories, asking the index about each candidate. `dlinfo (RTLD_DI_SERINFO)` lists the existing package directories the same way (the filling pass never writes beyond what the counting pass measured). Under `LD_AUDIT` or `LD_DEBUG=libs` the index is not used (`no_index`), so they see every candidate the plain walk would.
  - `dl-load.c` is upstream plus 237 lines (v5: plus 841). The two trust checks (a library in `/sw/<pkg>/lib` is in the trusted `/sw/*/lib`, and the same for `ld.so.cache` entries under `DF_1_NODEFLIB`) share one helper, `in_system_dir`. Upstream's setuid preload check moved into `refuse_unsafe_preload` so both search branches use it.
  - **State is shared:** prefixes, mapped slots, and misses live in `_rtld_global` (`GL (dl_fswc)`, `struct fswc_shared`), so the index `ld.so` maps for startup also serves `glob` and `execvp`; static programs have their own. `dl-fswc.c` is one line, `#include "fswc-read.c"`: one source in both.
  - **Never blocks:** the one lock is only ever try-locked. A busy lock means that call takes the plain walk, so `fork` in another thread mid-mapping cannot deadlock a child. v5's fork hooks, `_Fork.c`/`fork.c` changes, `__fswc_init` call in `csu/libc-start.c`, and `glibc.fswc.*` tunables are gone (those files are upstream again).
  - **v5 deleted:** `include/fswc.h`, `sysdeps/unix/sysv/linux/fswc.c` (about 4,200 lines). The glibc source patch went from 12,073 to 6,900 lines.
  - **Stack:** every `FSWC` frame in `ld.so` is under 1 KiB (largest: `__fswc_walk`, 728 bytes). The walker's path buffer and listing scratch for library search are static (used under `dl_load_lock` or before threads exist).
  - **Tests:** `elf` 544 PASS with exactly the 8 Phase 1 baseline failures (container `ldconfig`/cache tests, `tst-tunconf1`); `posix` 194 PASS, 1 FAIL (`tst-vfork3`, known). `check-localplt` caught a PLT call (`strchrnul` instead of `__strchrnul`), fixed.
  - **Measured** (15 libraries in the last 15 of 100 test-sealed packages, `dlopen` in one process; a true program start needs real SquashFS and root, the VM run): plain walk 8.6 ms and 4,645 syscalls; with the index 2.05 ms and 479; floor (the same libraries in one literal directory) 0.89 ms and 389. A `dlopen` of a library in the last package: 300 file probes without the index, 1 with it.
  - **Prepared queries (done):** a search list asks every package the same question, so the path and its ancestors are looked up once per search (`__fswc_query_prepare`) and each package is answered by a small search in that path's posting list (`__fswc_query_answer`, by the package's position, which the walker knows). `ld.so` prepares one query per hwcaps variant. `__fswc_lookup` is prepare-then-answer, so the logic exists once. Result: the 15 `dlopen`s above 2.05 → about 1.26 ms (overhead over the floor 1.16 → 0.37 ms); `posix_spawnp` miss 63 → 47 µs; `glob ("{PATH}/name", GLOB_PATHS)` miss 22 → 9.4 µs.
  - **Remaining known cost:** validation pages through every mount beneath the prefix's mount with `listmount` (about 3 calls per search here); Phase 3's counter replaces that with one `ioctl`.
  - **Size against the budget:** `fswc-read.c` 884 code lines (budget about 500; it now includes the shared walker, about 300, which the budget predates), `fswc-build.c` 692 (budget about 600), headers 220 (budget about 150): about 1,800 code lines, over the 1,500 target. v5 was about 4,400.
- **Step 7 (most of it) done.** `tst-fswc-oracle` gained a 16-process build stampede and six damaged-index states, each run in a fresh process: truncated to zero, cut in half, header overwritten, wrong mode (`0644`), replaced by a symlink (all rejected: the hook must report no index, and every probe must equal the plain walk), and a scribbled body behind an intact header and mount list (accepted, so lookups run over garbage: answers may be wrong by design, but the process must not crash; it does not). `tst-fswc-edge` lost its v5-only parts (the `max_inodes` tunable run, v5 SHM artifact corruption, the v5 artifact counter, the `mode={0,1}` loop).
  - **Found while writing them: SIGBUS.** A process that has an index mapped dies with SIGBUS if the file is truncated under it. Rebuilds never truncate (they rename a new file over the old one), and the sweep only unlinks, so this needs the index's owner to truncate their own file; accepted, like fontconfig's caches and the locale archive (see §4.5). The test's parent therefore never maps an index it is about to damage; a child builds it.
  - Still open from step 7: `tst-fswc-startup` (the early-init builder itself: static and `AT_SECURE` never build) and the privileged mount rows of `tools/test-fswc`; the remaining v5-era tests discover a host SquashFS prefix from `/proc/self/mountinfo` (failure mode R2) and so exercise only the plain walk under v6.
- **Step 8 prepared** (2026-11-17; landed in `sw/`, not yet built by `world`). The `glibc` patches were regenerated from the v6 tree (source 12,073 → 7,009 lines; test 4,695) and apply cleanly on both recipe bases. Their checksums are updated in `sw/glibc` and `sw/glibc-pass1`. Downstream consumers moved to the §3.2 rule, each built and checked locally against the v6 `glibc`:
  - **`bash`** (`sw/bash`, `sw/bash-pass1`): command search and completion make one `glob ("{" PATH "}/" name, GLOB_PATHS)` call through `shell_path_candidates`. `pathexp.c` lost its colon scanner, bracket scanner, and per-segment tilde and glob helpers; the source patch went from 3,106 to 2,748 lines. `tests/glob.tests` was rewritten to the strict rule. `CHECK` gives the same environmental diffs as the old patch (tests that expect `/bin`), except that the old patch fails the strict-rule glob tests.
  - **`readline`** (`sw/readline`, and its copy bundled in `bash`): `GLOB_TILDE` no longer applies inside `GLOB_PATHS`, so a `~/.inputrc` element was silently dropped. `_rl_tilde_expand_list` now expands a leading `~` in each element before the `glob()` call; readline's own `tilde_expand` would not do it, because by default it expands only after a space or tab, not after `:`. The existing `~` case in `tests/inputrc-glob.sh` fails with the old patch and passes with the new one.
  - **`tcl`** (`sw/tcl`): `auto_execok` lost its bracket-aware splitter and follows the §3.2 rule in plain Tcl (split on `:`, one whole-`*` component expanded with `glob -tails -directory` plus `lsort`). `Tcl_FindExecutable` drops the no-op `GLOB_NOESCAPE`. `unixFile-1.8`, `1.9`, and `1.15` now test the strict rule: `pkg_*` is literal, `*` skips dot-directories, two `*` components match nothing, `:` always splits, and brackets are literal.
  - Audited and unchanged, because they use only whole-`*` elements or their own self-consistent splitters: `coreutils`, `make`, `man-db`, `groff`, `iproute2`, `util-linux`, `ncurses`, `which`, Python's `getpath`, `os.get_exec_path` and `shutil.which`, `gcc`'s include-path scanner, and `perl`. Moving the self-splitters onto `{list}/NAME` is later work (§3.2 "Callers").
- **First `world` with v6 (2026-11-17): 4 `glibc` test failures, then a test overhaul.** `tst-dlopenfail`, `tst-dlopenfail-2`, `tst-dlmopen-dlerror` and `tst-glob-bz30635` failed: a missed search ended in `ENOTDIR`, because the image files beside the packages in `/sw` (`zstd-pass1-1.5.7.squashfs` sorts last) were treated as packages. Fixed by the directories-only rule (§3.2). The local tests had missed it because their prefix did not look like `/sw`, so the tests were rebuilt to (§4.8), and they found more:
  - **Walker:** a candidate longer than `PATH_MAX` ended the whole element, where the plain walk notes `ENAMETOOLONG` and goes on; such candidates are now reported as `FSWC_TOOLONG`. Without an index, the old fallback reread the directory once per package when the listing did not fit its buffer: on the real `/sw`, about 230 reads in every `execvp` (execvp has 4 KiB for names, `/sw` needs about 5 KiB). It now keeps as many of the smallest remaining names as fit per pass (two passes on `/sw`).
  - **`ld.so`:** a wildcard candidate was built in a buffer sized for the element as written, but a package name is longer than the `*` it replaces, so a long element (say, a deep `LD_LIBRARY_PATH` entry) overflowed it; candidates now get their own `PATH_MAX` buffer. An index-proven missing `lib` directory also left `errno` untouched where `open` would have set `ENOENT`, `ENOTDIR`, or `ENAMETOOLONG`.
  - **Sweep:** an unprivileged build deleted the index of every other live mount namespace of its user, since without `CAP_SYS_ADMIN` `listmount` reports them all as missing. Services in private mount namespaces and the same user's login session would have deleted each other's indexes on every start. Now only a privileged build trusts that answer, and an unprivileged one waits a day.
- **`world` passed with v6 (2026-11-18)**, every package's tests included. On the real `/sw` in swctl's sandbox, `tst-fswc-real` found 233 entries, 36 of them SquashFS package mounts, and the index sealed exactly those 36. The sandbox has no user namespaces, so `tst-fswc-startup` is UNSUPPORTED there and the oracle skips its mount rows (both pass locally). One more test-only fix on the way: the static oracle's `.out` rule lacked `tst-fswc-oracle-mod.so`.
- **Next: the rest of step 8**, the `--squashfs` benchmark in the VM, then Phase 3.

**Budget and checkpoints:**
- Size targets: `fswc-read.c` about 500 lines, `fswc-build.c` about 600, `fswc.h` about 150. The consumer changes should *shrink* `glob.c`, `execvpe.c`, and `dl-load.c` relative to v5.
- Rough local timing: one `glibc` rebuild plus `posix`/`elf` checks takes about 45 minutes on the 8-core host.
- Every step ends with patches regenerated through the round-trip-verified regenerator and checksums synced in `sw/glibc` and `sw/glibc-pass1`, but steps are landed in `sw/` only at the user's checkpoints. Each `glibc` patch change rebuilds the world.

**Decisions (2026-11-16):**
- The optional `top[]` readdir step (step 4) is decided by benchmark: measure step 4 with and without it, and keep it only if the difference is significant.
- `fswc_lookup` also serves `ld.so`'s `glibc-hwcaps` subdirectory probes (step 6). These are `DIR` lookups answered from the index, which removes most of the remaining startup probes.

### Phase 3: Kernel Namespace Counter (`linux`, `linux-headers`)
1. Add the §4.6 `NS_MNT_GET_INFO` `event` patch to `sw/linux` (and its UAPI header to `sw/linux-headers`), with a kernel selftest.
2. Teach `fswc-read.c` to prefer the counter when the reported struct size includes it.
3. **Gate 3**: on Fluffy's kernel (VM boot in CI), the full §4.8 matrix passes, including `move_mount` swap; per-exec validation is 2 syscalls.

### Phase 4: Strip Leaked Cache Headers from `binutils` & `gcc` (-6,665+ LOC) — *done (v5 era)*
1. Strip `include/fluffy-cache.h` and all `fc_*` hooks from `sw/binutils-2.47-fluffy-source.patch` and `sw/gcc-16.2.0-fluffy-source.patch` (restoring `libcpp/files.cc` to unmodified upstream, checking literal `S_ISDIR` before `glob()` across `ldfile_add_library_path`, `add_path`, `add_prefix`, `add_sysrooted_prefix`, `add_sysrooted_hdrs_prefix`, and `do_add_prefix` while making them non-recursive on matched `gl_pathv` entries with `target_system_root`/relocated-prefix metacharacter escaping, and syncing SHA-256 across `binutils-pass{1,2}` and `gcc-pass{1,2}`).
2. Audit both patches for "defensive" fallbacks that change upstream semantics (e.g. the `relocated_prefix ? relocated_prefix : ""` pattern that turned a skipped include directory into a CWD-relative `include`).
3. **Gate 4**:
   - Rebuild `binutils` and `gcc`; pass full DejaGnu `CHECK()` suites (`binutils`, `gas`, `ld`, `libctf`, `libsframe`, `gcc`, `g++`, `libstdc++`).
   - Verify `sw/gcc` `CHECK()` zero-`-I`/zero-`-L` C/C++ compile+link assertions (`<iostream>`, `<zlib.h>`, `<zstd.h>`, and `#include_next <stdlib.h>`) and the `bench-fswc` `g++` + `ld` macrobenchmark against the plain walk (upstream `glibc` via `--ldso`; there is no off switch, Rule 2) and with a valid index, matching or beating inline `fluffy-cache.h` wall time.

### Phase 5: Language Runtime Glob Unification (`python`, `perl`, `tcl`) — *done (v5 era)*
1. **`python` (+ `python-pass1`)**: Re-freeze `Modules/getpath.py` (globbing `ENV_PATH` `d` prior to `joinpath`), upgrade `posix._glob` (`str|bytes`, all flags, escaped `root_dir` including `GLOB_NOESCAPE | GLOB_BRACE`), fast-path `str` patterns in `Lib/glob.py` (preserving `bytes` ISO-8859-1 single-byte, `LC_ALL=C` multi-byte UTF-8 `?`/`[é]`, and `[a-z]` codepoint-range `iglob` parity), clean up `os.py`, `shutil.py`, `getpath.py`, and `site.py` (`GLOB_ONLYDIR` prefix expansion), and expand `sw/Python-3.14.7-fluffy-test.patch` (with `/bin/sh` fallback for `unix_shell` when `/sw/bash/bin/bash` is absent).
2. **`perl` (+ `perl-pass1`)**: Delegate `ext/File-Glob/bsd_glob.c` leaf patterns to `<glob.h>` (`GLOB_NOMAGIC`, `GLOB_BRACE`, `GLOB_LIMIT`, `SvUTF8`), patch `File::Spec::Unix::path()` (`miniperl`-safe with `eval`-guarded regex compilation), wire `@INC`/`PERL5LIB`/`otherlibdirs` wildcard directory expansion in `perl.c:S_incpush` (`GLOB_ONLYDIR | GLOB_NOESCAPE`), and add tests to `sw/perl-5.44.0-fluffy-test.patch`.
3. **`tcl`**: Replace `TclFSIsPureNative()` with `TclFSPatternIsNative()` (honoring `listVolumesProc == NULL` interceptors, top-level `{...}` VFS/root guards, and bidirectional VFS volume overlap checks), enable balanced `{a,b}` `GLOB_BRACE` in `CanUseNativeMultiGlob` (preserving `NativeMatchType`), split `$env(PATH)` with `GLOB_NOESCAPE` parity and guard `init.tcl` wildcard `glob` loops with `catch` and `--`, and expand `sw/tcl8.6.18-fluffy-test.patch`.
4. **Gate 5**:
   - Full `CHECK()` suites pass 100% in `python` (`test_glob`, `test_site`, `test_os`, `test_shutil`, `test_getpath` + frozen subprocess test), `perl` (`make test_harness`), and `tcl` (`make test` including `fileSystem.test`).

### Phase 6: CLI & System `GLOB_PATHS` Consolidation, C-Literal Cleanup & `CHECK()` Gap Closure — *done (v5 era)*
1. Simplify `which` (`which.c`, bracket/escape-aware `PATH` splitting, per-call flag reset when `PATH` is unset, `PATH=""` → `"."`, `GLOB_SKIPDOTS`, preserving `--show-dot` / `--show-tilde`, unexpanded wildcard `~*/...` expansion, and `$HOME` metacharacter safety), `make` & `coreutils` (`lib/findprog-in.c` with `GLOB_PATHS | GLOB_NOESCAPE | GLOB_NOCHECK`), `systemd` (`src/basic/glob-util.c` `GLOB_SKIPDOTS` when `opendir_func == NULL` instead of `GLOB_ALTDIRFUNC` + `GLOB_ONLYDIR` in `find_executable_in_element`), `kmod` (`--sysconfdir=/etc`, `/etc` → `/run` → `/sw/*/etc` → `/sw/*/lib` order, `GLOB_NOESCAPE` + literal `-C` fallback in `libkmod-config.c`/`depmod.c` + `testsuite/path.c` `glob` wrapper), `dbus` (bracket-aware `:` split + `GLOB_ONLYDIR | GLOB_NOESCAPE` post-suffix + `(st_dev, st_ino)` `<includedir>` dedup), `readline` (`-DSYS_INPUTRC`, literal-first open before `GLOB_PATHS | GLOB_NOESCAPE | GLOB_TILDE`, `S_ISDIR` skip), `man-db` (`directory_on_path` `"."` `xgetcwd` + `GLOB_NOCHECK`), `util-linux` (`GLOB_NOESCAPE` + per-segment empty-`:` filtering in `configs.c`/`fsck.c`/`context.c` + `agetty.c` `GLOB_PATHS`), `shadow` (`getdef.c`/`groupio.c`/`pwio.c`/`prefix_flag.c` prefix metacharacter escaping + `GLOB_NOESCAPE` + `commonio_open` `!db->setname || db->prefix_db` `ENOENT` guard + `gr_materialize_member` CoW in `usermod.c`/`userdel.c`), `e2fsprogs` (`profile_helpers.c` bracket-aware `:` split + `profile.c` `GLOB_NOESCAPE` fixing CWD `get_dirlist(".")`), `dejagnu` & `sqlite` (`GLOB_NOESCAPE` bracket-aware `:` split + Tcl metacharacter escaping + `catch {glob -nocomplain -types d -- ...}`), `meson` (strip 108 foreign `.pyc` binaries from `sw/meson-1.12.0-fluffy.patch`), and `openssl` (+ `openssl-pass1`) / `curl` (+ `curl-pass1`) (`by_dir.c` & `apps/lib/opt.c` bracket-aware `:` split + empty-segment skip + `by_file.c` explicit `-CAfile` & `X509_load_crl_file` globbing + removing `curl` `openssl.c` wrapper); add bracket-aware direct `my_list` `TERMINFO_DIRS` glob expansion to `ncurses` (+ `ncurses-pass1`); ensure zero-initialized `glob_t` and unconditional `globfree()` across all `glob()` callsites; move remaining C/C++ `"/sw/..."` default literals (`bash`, `readline`, `make`, `kmod`, `dbus`, `man-db`, `util-linux`, `shadow`, `e2fsprogs`, `iproute2`, `systemd`, plus `<paths.h>` `_PATH_BSHELL` in `gawk` + `gawk-pass1`, `libcap`, `ninja`, and `tar` — keeping `argv[0] = "sh"` where POSIX `/bin/sh` compatibility mode is expected) into build/config macros (`paths.h` / `CFLAGS` / Meson `-D`).
2. Add missing `CHECK()` blocks to `sw/ncurses` and `sw/sqlite`, upgrade `sw/iproute2` and `sw/which` `CHECK()` suites, and extend existing `CHECK()` assertions in `sw/readline`, `sw/shadow`, `sw/util-linux`, and `sw/e2fsprogs`.
3. **Gate 6**:
   - Every package modified from upstream source has an automated `CHECK()` test exercising its Fluffy wildcard/stateless-`/etc` code paths and passes cleanly.

### Phase 7: End-to-End `world` Convergence & Final Audit
1. Run `sudo --preserve-env=FLUFFY,CROSS ./swctl build world` (and verify `CROSS=1` checksum consistency), confirming `git grep fluf''fy-cache -- sw/` returns 0 hits, zero C logic files hardcode `"/sw"`, no `glibc` single-path wrapper references `fswc`, and all `world` `CHECK()` suites pass.
