# Fluffy Linux Globbing & `FSWC` Design and Implementation Plan

This document is the authoritative specification and phased execution plan for universal wildcard path resolution (`<glob.h>`, `<fnmatch.h>`, `GLOB_PATHS`), language runtime glob delegation, and the internal `glibc` Fluffy SquashFS Wildcard Cache (`FSWC` v5). It supersedes the prototype notes previously kept in [NOTES.md](NOTES.md) and defines the path from the current `FSWC` v4 prototype to Fluffy's target architecture, including per-package test suite requirements for every package modified from upstream source.

---

## 1. Architectural Vision & Non-Negotiable Principles

In a traditional FHS distribution, packages pour files into mutable shared directories (`/usr/bin`, `/usr/lib`, `/usr/include`, `/etc`), then paper over the resulting lookup and collision problems with subsystem-specific caches and generators (`ldconfig` / `/etc/ld.so.cache`, `pkg-config`, `update-ca-certificates`, symlink farms, post-install triggers).

Fluffy Linux mounts each package as an independent, read-only SquashFS image at `/sw/<pkg>` with zero symlink farms and zero install hooks. Consequently, **every** subsystem shares the exact same discovery primitive: lexicographically ordered wildcard expansion over `/sw/*/...` (combined with ordered colon-delimited search paths such as `/sw/.build/*/bin:/sw/*/bin` or `/sw/*/etc/foo.conf:/etc/foo.conf`).

Rather than inventing bespoke directory scanners or leaking custom cache libraries across userland, Fluffy elevates POSIX `<glob.h>` and `<fnmatch.h>` in `glibc` into the **single universal lookup primitive**, backed by an invisible, POSIX-transparent shared-memory SquashFS index inside `glibc`.

### Non-Negotiable Design Rules

1. **Zero Implementation Leakage (`FSWC` Strictly Private to `glibc`)**:
   - No downstream package (`binutils`, `gcc`, `bash`, `python`, `perl`, `tcl`, `systemd`, `kmod`, etc.) may include `fluffy-cache.h`, parse `/dev/shm` blobs, or know `FSWC` exists.
   - Downstream packages call standard `<glob.h>` (`glob()`, `globfree()`), `<fnmatch.h>` (`fnmatch()`), `<dlfcn.h>` (`dlopen()`), `<unistd.h>` (`execvp()`, `execvpe()`, `access()`, `open()`, `stat()`), and `<spawn.h>` (`posix_spawnp()`).
2. **Zero Hardcoded `"/sw"` Literals in C Source**:
   - Upstream C/C++ patches implement general-purpose wildcard expansion (`glob()`, `GLOB_PATHS`) over configured paths.
   - Fluffy paths (`/sw/*/bin`, `/sw/*/lib`, `/sw/*/include`, `/sw/*/etc/...`) enter strictly through build configuration (`configparms` `user-defined-trusted-dirs`, `./configure` flags, `paths.h`, `STANDARD_STARTFILE_PREFIX`, `NATIVE_SYSTEM_HEADER_DIR`, default environment variables).
3. **Preserve `glob_t` ABI — No `GLOB_MOUNTS` Flag**:
   - `sizeof(glob_t)` and `sizeof(glob64_t)` remain 100% upstream ABI-compatible.
   - The experimental `GLOB_MOUNTS` mount-table union concept is **dropped**: `glibc` deals strictly with OS paths (plus upstream's existing `GLOB_ALTDIRFUNC` callback interface used by tools like `kmod`'s test suite). Language runtimes with in-process virtual filesystems (e.g., Tcl `//zipfs:/` / Starkits) check whether a pattern touches a registered non-OS mount prefix (~15 lines in Tcl) and delegate native OS patterns directly to `glibc` `glob()`.
4. **Strict POSIX & VFS Observational Equivalence**:
   - Caching must never alter observable return codes, `errno` values (`ENOTDIR` vs. `ENOENT`, `EACCES`, `ELOOP`, `ENAMETOOLONG`), symlink traversal (`stat` vs. `lstat`, `O_NOFOLLOW`, `GLOB_MARK`), `LC_COLLATE` ordering, `errfunc` / `GLOB_ERR` callbacks, or per-UID permission enforcement. Any ambiguous or non-immutable case falls through cleanly to the kernel.
5. **High-Bit Custom Flags & Timestamp-Preserving Patch Hygiene**:
   - Custom `<glob.h>` and `<fnmatch.h>` flags are allocated downward from `(1 << 30)` so future upstream `glibc` additions at low bit positions never collide.
   - All patches preserve upstream file modification timestamps (`TZ=UTC0`, applied with `patch -Z -Np1`) so `autoconf`/`automake`/`help2man` rebuild rules are never falsely triggered.
   - Every behavioral modification to an upstream package must be verified by automated tests executed in that recipe's `CHECK()` phase.

### LOC & Duplication Scorecard (Current Prototype → Target State)

| Component | Current Patch State | Target State | Net LOC Delta |
| :--- | :--- | :--- | :--- |
| `binutils` (`include/fluffy-cache.h` + `ldfile.c`) | 3,379 lines (3,286-line leaked cache header) | ~25-line `glob(GLOB_ONLYDIR)` in `ld/ldfile.c` | **-3,315 LOC** |
| `gcc` (`include/fluffy-cache.h` + `gcc/*.cc`) | 3,676 lines (3,282-line leaked cache header) | ~150 lines using `glob(GLOB_ONLYDIR)` (`libcpp/files.cc` unmodified) | **-3,380+ LOC** |
| `glibc` (`posix/glob_fluffy_cache.h` + `glob.c`) | 3,285-line static header compiled into 3 TUs + 450 lines of `Case A/B/C` & `glob_literal_suffix_try` | Single `fswc.c` (~1,100 lines, compiled once per lib) + ~130-line unified `fswc_glob_walk` | **-2,505 LOC** |
| `bash` (`lib/glob/*` deleted + `<glob.h>` wiring) | Deleted `lib/glob/*` (-1,849 lines); delegates 100% to `glibc` | Keep + minor `shell.c` / `bind.c` polish | *(Already -1,849 LOC)* |
| `perl` (`ext/File-Glob/bsd_glob.c` + `File::Spec`) | Unmodified 1,050-line BSD glob + unpatched `File::Spec->path()` | ~70-line `<glob.h>` shim in `bsd_glob.c` + `File::Spec::Unix::path()` + `@INC` `GLOB_PATHS` | **~-900 LOC active** |
| `python` (`posixmodule.c`, `glob.py`, `os.py`, `site.py`, `getpath.py`, `shutil.py`) | Partial `posix._glob` + 4 separate `:`-splitting glob loops | Full-featured `posix._glob` (`str\|bytes`, all flags) + shared `posix._glob` path helpers | **~-120 LOC** |
| `tcl` (`tclFileName.c`, `init.tcl`) | Coarse `TclFSIsPureNative` bailout; `GLOB_BRACE` disabled | ~20-line `TclFSPatternIsNative` prefix check + `GLOB_BRACE` enabled + `GLOB_PATHS` | **~-40 LOC** |
| `make`, `coreutils`, `util-linux`, `which`, `curl` | 75-line `active_glob` in `which.c`; 65-line `curl` wrapper; manual loops in `findprog-in.c` & `util-linux` | `GLOB_PATHS` in `findprog-in.c` & `util-linux`; local `glob()` in `which.c`; `curl` wrapper deleted | **~-180 LOC** |

---

## 2. Audit of Current Prototype (`FSWC` v4) & Gap Analysis

Auditing `sw/glibc-2.44-fluffy-source.patch`, `sw/binutils-2.47-fluffy-source.patch`, `sw/gcc-16.2.0-fluffy-source.patch`, and language runtime patches revealed six structural issues to resolve:

1. **Header Triplication & Leaked Implementation**:
   - `glob_fluffy_cache.h` (3,285 lines) is copy-pasted verbatim into `glibc`, `binutils` (`include/fluffy-cache.h`, 97% of patch), and `gcc` (`include/fluffy-cache.h`, 89% of patch), and compiled separately into `dl-load.os`, `execvpe.os`, and `glob.os` (`glob` + `glob64`) inside `glibc`.
2. **Hardcoded 5-Subdirectory Whitelist & Depth Cap**:
   - `FSWC` v4 hardcodes `FSWC_NUM_SUBDIRS = 5` (`bin`, `lib`, `etc`, `include`, `libexec`) and `FSWC_INC_MAX_SLASHES = 4`.
   - Lookups into `/sw/*/share/terminfo/*/*` (Python PyREPL, `ncurses`), `/sw/*/lib/python3.14/site-packages/*` (every Python startup), `/sw/*/lib/systemd/system/*` (`systemd`), `/sw/*/etc/systemd/system/*`, `/sw/*/etc/modprobe.d/*` (`kmod`), `/sw/*/share/man` (`man-db`), and `/sw/*/etc/ssl/certs/*` (`openssl`/`curl`) miss the v4 index or fall back completely.
3. **`MAP_PRIVATE` CoW Page Dirtying, 16-Slot Collisions & Dead `/tmp/.fluffy_ns_sealed`**:
   - `fswc_try_acquire_sealed` maps `/dev/shm/fluffy_sw_v4_<slot>` with `MAP_PRIVATE`, temporarily calls `mprotect(..., PROT_READ | PROT_WRITE)` to patch `mnt_id` and `mnt_hash` into page 0, and `mprotect`s back—dirtying a 4 KiB anonymous CoW page in every process and defeating pure shared clean pages.
   - `FSWC_SHM_SLOTS = 16` (`mix64(mnt_id) & 15`) suffers birthday collisions across concurrent `swctl build` sandboxes and multi-prefix namespaces.
   - `swctl` already removed `touch /tmp/.fluffy_ns_sealed`, leaving ~150 lines of dead `FSWC_HDR_SEALED` logic in `glibc`.
4. **Brittle `Case A/B/C` Pattern Fast-Paths in `posix/glob.c`**:
   - `fc_glob_try` handles only three rigid shapes (`<prefix>/*`, `<prefix>/*/<sub1>`, `<prefix>/*/<sub1>/<tail>`) and bails out whenever `GLOB_PERIOD`, `GLOB_CASEFOLD`, `GLOB_KEEP_SLASHES`, `GLOB_ERR`, or multi-wildcard components appear; `glob_literal_suffix_try` adds a second overlapping 210-line special case in `posix/glob.c`.
5. **Naive Per-Package `(parent_id, basename)` Degrades Cross-Package Probes to $O(N_{\text{pkgs}})$**:
   - If a full-tree index keys nodes on `(pkg_parent_node_id, basename)`, then resolving `/sw/*/lib/libz.so.1` or `/sw/*/bin/gcc` still has to probe `libz.so.1` separately across all 90+ package `lib` node IDs ($O(N_{\text{pkgs}})$ hash lookups).
   - **Solution (`FSWC` v5 Merged Virtual Trie)**: Assign virtual directory IDs (`vdir_id`) to unique *relative* directory paths across `<prefix>/*` (`vdir_id = 0` is `<prefix>/*`, `vdir_id = 1` is `<prefix>/*/bin`, `vdir_id = 2` is `<prefix>/*/lib`, etc.) with compact sorted `pkg_idx` posting lists (inlined when `count == 1`, which covers ~90% of files). Any `<prefix>/*/<relpath>` lookup becomes strictly $O(\text{depth})$—2 hash probes for `/sw/*/bin/gcc` regardless of whether 10 or 1,000 packages are mounted.
6. **Why Removing `fluffy-cache.h` from `gcc` & `binutils` Needs `mode=2` Opportunistic Negative Filtering**:
   - Once `gcc` (`incpath.cc`) and `binutils` (`ldfile.c`) expand `/sw/*/include` (52 dirs) and `/sw/*/lib` (65 dirs) via `glob(GLOB_ONLYDIR)` at startup, `cc1plus` issues `openat(AT_FDCWD, "/sw/<pkg>/include/<hdr>.h", O_RDONLY | O_NOCTTY)` across each `-I` directory in turn, and `ld` probes `open("/sw/<pkg>/lib/libfoo.so", ...)` across each `SEARCH_DIR`.
   - Without negative filtering in `libc.so`, 200 `#include` directives generate ~5,000 kernel `ENOENT` syscalls per translation unit. With a lock-free ~15 ns negative lookup in `libc.so` against the **already-mapped** `GL` view (`mode=2`), `gcc` and `binutils` lose 6,572 lines of custom cache code while keeping $O(1)$-style compile and link speed.

---

## 3. Public `<glob.h>` & `<fnmatch.h>` Specification

### 3.1 High-Bit Flag Allocation Table

All Fluffy extensions are guarded by `#ifdef __USE_GNU` (with internal `__GLOB_*` / `__FNM_*` aliases inside `glibc`) and occupy bits `30` downward:

| Header | Macro | Value | Purpose |
| :--- | :--- | :--- | :--- |
| `<fnmatch.h>` | `FNM_DOTDOT` | `(1 << 30)` | Never match `.` or `..` via wildcards (`*`, `?`, `[...]`, `!(...)`), even when `FNM_PERIOD` is absent (leading `.` matched on `.foo`, but `.` and `..` require literal pattern). |
| `<glob.h>` | `GLOB_KEEP_SLASHES` | `(1 << 30)` | Preserve redundant trailing slashes on completely literal directory patterns (`"dir//"` → `"dir//"`) while normalizing wildcard matches (`"d*//"` → `"dir/"`). Required for Python `glob.glob()` parity. |
| `<glob.h>` | `GLOB_PATHS` | `(1 << 29)` | Parse unescaped top-level `:` as ordered path-list alternation; normalize empty segments (`""`) to `"."`; sort strictly within each segment `[oldcount, gl_pathc)`. |
| `<glob.h>` | `GLOB_EXTMATCH` | `(1 << 28)` | Enable ksh/Bash extended globs (`?(pat-list)`, `*(pat-list)`, `+(pat-list)`, `@(pat-list)`, `!(pat-list)`) in both `__glob_pattern_type` and `fnmatch`. |
| `<glob.h>` | `GLOB_CASEFOLD` | `(1 << 27)` | Case-insensitive filename matching (`FNM_CASEFOLD`, Bash `nocaseglob`, Tcl `-nocase`, Python `case_sensitive=False`). |
| `<glob.h>` | `GLOB_SKIPDOTS` | `(1 << 26)` | Never emit `.` or `..` directory entries, even when `GLOB_PERIOD` is set or the pattern is `.*` (Bash `globskipdots`, Tcl/Python directory scans). |
| `<glob.h>` | `GLOB_GLOBSTAR` | `(1 << 25)` | Treat standalone path component `**` as recursive zero-or-more-directory traversal (`globstar`, Python `recursive=True`). |
| `<glob.h>` | `GLOB_DOTDOT` | `(1 << 24)` | Forward `FNM_DOTDOT` to `fnmatch`: with `GLOB_PERIOD`, match hidden `.foo` files with `*` while excluding `.` and `..` unless literally requested (Bash `dotglob`, Python `include_hidden=True`). |

`__GLOB_FLAGS` in `<glob.h>` is the symbolic OR of all standard POSIX/GNU input flags plus all seven `GLOB_*` high bits (`0x7f007eff` — note bit 8, `GLOB_MAGCHAR = 0x0100`, is an output-only `gl_flags` status bit and is never included in `__GLOB_FLAGS`).

### 3.2 Exact Behavioral Semantics

1. **`GLOB_PATHS` (`:`-Alternation)**:
   - Splits `pattern` on top-level `:` characters that are outside character classes `[...]` (respecting `[:class:]`, `[.coll.]`, `[=equiv=]`, and leading `]`/`!`/`^`), outside `GLOB_EXTMATCH` parenthesized groups `@(...)` / `!(...)` / etc., and (when `flags & GLOB_BRACE`) outside balanced `{...}` brace groups (so both `"{/a:/b,/c}"` and `"/sw/*/{bin,sbin}:/usr/bin"` parse unambiguously).
   - When `!(flags & GLOB_NOESCAPE)`, `next_colon_sub` advances past `\c` escape pairs without mutating the segment slice, passing `\:` verbatim into recursive `__glob()` so `__glob` / `fnmatch` unescapes `\c` in a **single pass** (preventing double-unescaping on `\\:` and preserving verbatim unexpanded segment patterns on `GLOB_NOCHECK` non-matches).
   - **Empty-segment & empty-pattern POSIX `PATH` rule**:
     - Matching POSIX.1-2024 §8.3 (`PATH=""` denotes current working directory) and existing Fluffy consumers (`bash` `shell_glob_path`, `man-db`, `which`, `findprog-in.c`), `pattern == ""` and any empty colon-delimited segment (`":/sw/*/bin"`, `"/a::/b"`, `"/sw/*/bin:"`) evaluate as `"."`. Callers expanding optional config lists where `""` means "none" check `*list != '\0'` before calling `glob()` (as `util-linux/lib/configs.c` already does).
   - **Per-segment ordering**: Unless `GLOB_NOSORT` is set, `collated_compare` sorts **only** the slice `[seg_start_idx, gl_pathc)` produced by each segment. Matches from segment $i$ always precede matches from segment $i + 1$.
   - **`GLOB_NOCHECK`, `GLOB_NOMAGIC` & `GLOB_DOOFFS` invariants (fixing 3 live prototype bugs in `posix/glob.c`)**:
     1. `GLOB_NOCHECK` and `GLOB_NOMAGIC` **must** be forwarded into each segment's recursive `__glob()` call (never stripped per segment, and never jumping to `goto no_matches` on the unsplit colon-delimited `pattern`, which previously emitted `["/no1:/no2"]` with a literal `:` when zero segments matched or silently dropped missing literal segments when an earlier segment matched).
     2. When `!(flags & GLOB_APPEND)`, `pglob` (`gl_pathc = 0`, `gl_pathv = NULL`, and `gl_offs` leading `NULL` slots under `GLOB_DOOFFS`) **must** be initialized once before segment `0`, and subsequent segments pass `(flags & ~GLOB_DOOFFS) | GLOB_APPEND` (preserving `pglob->gl_offs` without re-reserving offset slots or reading uninitialized `pglob` fields).
2. **`GLOB_GLOBSTAR` (`**` Traversal)**:
   - Consecutive `**` components (`a/**/**/b`) collapse in $O(1)$ before traversal to prevent exponential backtracking.
   - `**/X` matches `X` at depth 0 (in the base directory) as well as `<sub1>/.../<subk>/X`.
   - **Symlink discipline (Bash 5.3 & Python 3.14 parity)**: Non-terminal `**/...` descends strictly into real directories (`DT_DIR`), **never** recursing through symlinked directories (`DT_LNK`), avoiding infinite symlink loops and duplicate trees. Terminal `**` (with no trailing `/...`) includes directory symlinks as leaf results (and resolves them when `/**/` requires a directory).
   - **Hidden directories**: Hidden directories (`.git`, `.build`) are entered by `**` if and only if `GLOB_PERIOD` is set.
3. **`GLOB_EXTMATCH` Pattern-Type Isolation & Escaped-Opener Directory Scan (`posix/glob_internal.h` & `posix/glob.c` Fixes)**:
   - `__glob_pattern_type_ext(pattern, quote, extmatch)` **must** inspect `+(`, `@(`, `!(` if and only if `extmatch != 0` (`(flags & GLOB_EXTMATCH) != 0` in `__glob` and `glob_in_dir`, and `0` in two-argument `__glob_pattern_type`). Unconditionally passing `extmatch = 1` (a live bug in the current prototype) falsely sets `GLOB_MAGCHAR` and breaks `GLOB_NOMAGIC` (`glob("foo+(bar)", GLOB_NOMAGIC)` / Perl `GLOB_CSH`) when `GLOB_EXTMATCH` is unset.
   - In `posix/glob.c`, `glob_dirscan(pat, dirsep, quote)` (used when `flags & GLOB_EXTMATCH`) **must** skip escaped characters (`if (quote && *p == '\\' && p[1] != '\0' && p[1] != dirsep) { ++p; continue; }`) before testing `is_extglob(p)`, fixing a live prototype bug where escaped `\@(` / `\+(` / `\?(` / `\*(` / `\!(` were misparsed as extglob groups and hid inner `/` directory separators.
4. **`glibc` Symbol, Hidden Alias & Static `conform/*/linknamespace` Invariant**:
   - On 64-bit Linux (`XSTAT_IS_XSTAT64` where `glob` and `glob64` share `sysdeps/unix/sysv/linux/glob.c`), `glob.c` **must** emit both `libc_hidden_def (glob)` and `libc_hidden_ver (__glob, __glob64)` plus `#if IS_IN (libc)` `hidden_def_alias (__glob, __GI_glob64)` `#endif`.
   - **ISO C11 & POSIX `libc.a` Link-Namespace Isolation (`conform/*/linknamespace`)**: Internal `libc` stateless-`/etc` callers (`nss/nss_database.c`, `nss/nss_files_fopen.c`, `resolv/res_hconf.c`, `resolv/resolv_conf.c`—the last of which is pulled into ISO C11 `thrd_create` via `__pthread_create` → `__libc_resp` → `__res_vinit`) **must never** reference un-prefixed `glob64`, `globfree64`, `globfree`, or `fnmatch`, nor pull `GLOB_TILDE`'s `__getlogin_r` (`utmp_file.o` → `alarm`) or `__getpwnam_r` (`res_send.o` → `read`) into `libc.a` closures:
     1. Define `__globfree` / `__globfree64` (`weak_alias (__globfree, globfree)` and `weak_alias (__globfree, globfree64)`) in `globfree.c` and expose `libc_hidden_proto (__fnmatch)` / `libc_hidden_def (__fnmatch)` so the glob engine calls only `__fnmatch` and `__globfree`.
     2. Split the `GLOB_TILDE` home-directory lookup (`__getlogin_r` / `__getpwnam_r`) out of the core tilde-free `__glob64_notilde` TU so `nss_database.c`, `nss_files_fopen.c`, `res_hconf.c`, and `resolv_conf.c` call `__glob64_notilde` and `__globfree64` with zero `ISO11` or `POSIX` `linknamespace` pollution.

---

## 4. `FSWC` v5 Internal Engine Architecture in `glibc`

### 4.1 Single Internal Module & Runtime State

Delete `posix/glob_fluffy_cache.h` completely and replace it with a single internal Linux module:

- **`include/fswc.h`**: Internal function prototypes, `struct fswc_cursor`, and `_rtld_global` (`GL`) slot definitions (~100 lines).
- **`sysdeps/unix/sysv/linux/fswc.c`**: Shared-memory builder, validator, Merged Virtual Trie reader, and exact/posting-list query primitives (~1,150 lines), compiled once into `rtld`, `libc.so`, and `libc.a`.
  - **Zero `malloc`/`free` Rule**: Because `fswc.c` runs inside `ld.so` prior to `libc.so` relocation (where `dl-minimal-malloc.c`'s `free()` is a no-op) as well as in `libc.so` and `libc.a`, `fswc.c` **never** calls `malloc`, `realloc`, or `free`. All cold-build scratch buffers allocate via temporary `mmap(..., MAP_PRIVATE | MAP_ANONYMOUS, -1, 0)` arenas and `munmap` immediately upon publishing or aborting.
- **`elf/dl-tunables.list`**: Add `fswc` namespace (`SXID_IGNORE` so `AT_SECURE` binaries ignore unprivileged caller overrides):
  - `glibc.fswc.mode` (`int32_t`, min `0`, max `2`, default `2`):
    - `0`: Bypass `FSWC` completely (pure kernel syscall baseline for differential testing and A/B benchmarking).
    - `1`: Enable `FSWC` in `ld.so` (`dl-load.c`), `glob()`/`glob64()` (`posix/glob.c`), and `execvpe()` (`posix/execvpe.c`).
    - `2` *(default)*: Enable `mode=1` **plus** opportunistic lock-free negative lookup in `libc.so` read-only path-probing wrappers (`open`/`openat` strictly when `(oflag & (O_ACCMODE | O_CREAT | __O_TMPFILE | O_TRUNC | O_EXCL)) == O_RDONLY` and—if `oflag & O_PATH`—`(oflag & ~(O_PATH | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)) == 0`, `stat`/`lstat`/`fstatat` when `(flag & ~(AT_SYMLINK_NOFOLLOW | AT_NO_AUTOMOUNT | AT_EMPTY_PATH)) == 0`, `statx` when `statxbuf != NULL && !(mask & STATX__RESERVED) && (flags & ~(AT_SYMLINK_NOFOLLOW | AT_NO_AUTOMOUNT | AT_EMPTY_PATH | AT_STATX_SYNC_TYPE)) == 0 && (flags & AT_STATX_SYNC_TYPE) != AT_STATX_SYNC_TYPE`, and `access`/`faccessat` strictly when `(mode & ~(R_OK | W_OK | X_OK)) == 0 && (flag & ~(AT_EACCESS | AT_SYMLINK_NOFOLLOW | AT_EMPTY_PATH)) == 0`) against already-mapped views.
  - `glibc.fswc.max_inodes` (`uint32_t`, default `1048576`, `0` = unlimited): Safety cap per prefix; if exceeded (or if `num_pkgs > 65534` or blob size would exceed `1 GiB`), `fswc` skips indexing that prefix and falls through cleanly to kernel syscalls.

#### Unified Writable `_rtld_global` (`GL`) Multi-Prefix Table (No `GLRO` Split)

- **Why All Slots Live in Writable `GL` (`_rtld_global._dl_fswc_state`)**: `_dl_protect_relro` hardware-protects `_rtld_global_ro` (`GLRO`) as `PROT_READ`. Keeping prefix slots in `_rtld_global_ro` would either `SIGSEGV` (`SEGV_ACCERR`) when updating `last_check_ns` / invalidating a view or strand long-running daemons like PID 1 (`systemd`) on a permanently stale boot view after `swctl install` mounts new packages. Storing all 16 slots in writable `_rtld_global` (`GL`, exported under `GLIBC_PRIVATE` so `ld.abilist` is unaffected, and backed by static BSS in `libc.a` via `dl-support.c`) allows `ld.so` to seed `/sw` during `_dl_init_paths` *and* allows `libc.so` to revalidate `last_check_ns` or atomically swap `slot->snap` across live mount or credential changes.
- **Single Cross-DSO Futex Lock & Deterministic `_Fork` Child Reset**: Because `fswc.c` is compiled into both `ld.so` (`dlopen`) and `libc.so` (`glob`, `execvpe`), a file-`static` lock in `fswc.c` would instantiate two separate locks racing on the same `GL(_dl_fswc_state)` slots. Instead, the writer futex word (`uint32_t lock`) resides **inside `GL(_dl_fswc_state)` itself** (operated via `INTERNAL_SYSCALL_CALL(futex, ...)`) and is reset to `0` deterministically inside `glibc`'s single-threaded `_Fork` / `__libc_fork` child path before `fork()` returns—avoiding both uncached `getpid()` syscalls and post-`fork` multi-threaded lazy-reset races.
- **Torn-Read-Free `struct fswc_slot_snap` Publication & `vfork` Safety**: Multi-word namespace metadata (`prefix_dev`, `prefix_ino`, `prefix_ctime_ns`, `prefix_mtime_ns`, `mnt_list_hash_lo/hi`, ancestor `(dev, ino)` chain, top-level `ns_*` table, and `blob_*` view pointer) live in a `PROT_READ | PROT_WRITE` anonymous-`mmap`'d `struct fswc_slot_snap` whose tuple/pointer fields are **write-once** prior to `atomic_store_release(&slot->snap, new_snap)`; the only post-publication writes on `snap` are its `_Atomic uint64_t last_check_ns` and `_Atomic uint32_t stale` words (so invalidating an old `snap` never clobbers a newly published `snap`, and wait-free/signal-handler readers loading `atomic_load_acquire(&slot->snap)` never observe torn tuples). Writers never `munmap` previously published `snap`s or `MAP_SHARED` views while the process runs, and **never** acquire locks or build blobs inside a `vfork()` (`CLONE_VM`) child.
- **`AT_SECURE` & Credential Guard**: If `__libc_enable_secure` is nonzero (setuid/setgid/file-capability transition), `FSWC` is disabled (`mode = 0`) unless `euid == 0 && ruid == 0` reading `/dev/shm/.fswc-0/`.

### 4.2 Merged Virtual Trie (`vdir_id`) Binary Schema (`FSWC` v5)

All blobs are position-independent, 8-byte aligned, little-endian, immutable once published (`chmod 0400`), and mapped `PROT_READ | MAP_SHARED` (`Private_Dirty == 0 KiB`).

```c
#define FSWC_BLOB_MAGIC   0x43575346u /* "FSWC" */
#define FSWC_BLOB_VERSION 5u
#define FSWC_VDIR_ROOT    0u          /* Virtual union root: <prefix>/* */
#define FSWC_VDIR_PKGS    0xffffffffu /* Sentinel key space for <pkg> names */
#define FSWC_NONE         0xffffffffu
#define FSWC_MAX_PKGS     65534u      /* Fits uint16_t counts & 24-bit inline idx */

/* Every posting uint32_t (both inline ref when cnt == 1 AND every element of
 * postings[] when cnt > 1) encodes BOTH pkg_idx and that package's exact d_type:
 * word = pkg_idx | ((uint32_t) d_type << 24) */
#define FSWC_POSTING_PACK(pkg, dt) (((uint32_t) (pkg) & 0x00ffffffu) | ((uint32_t) (dt) << 24))
#define FSWC_POSTING_PKG(word)     ((word) & 0x00ffffffu)
#define FSWC_POSTING_DTYPE(word)   (((word) >> 24) & 0xffu)

/* Per-package flags: */
#define FSWC_PKG_IMMUTABLE         (1u << 0) /* SQUASHFS_MAGIC & zero child overmounts */
#define FSWC_PKG_ALL_WORLD_SEARCH  (1u << 1) /* Every dir in pkg has (mode & 0111)==0111 & no ACL */
#define FSWC_PKG_ALL_WORLD_RX      (1u << 2) /* Every dir in pkg has (mode & 0555)==0555 & no ACL */

struct fswc_header {
  uint32_t magic;            /* FSWC_BLOB_MAGIC */
  uint32_t version;          /* FSWC_BLOB_VERSION (5) */
  uint64_t total_size;       /* Exact byte length of blob */
  uint64_t pkgset_hash_lo;   /* 128-bit order-sensitive hash of immutable pkg set */
  uint64_t pkgset_hash_hi;
  uint32_t num_pkgs;         /* Immutable SquashFS pkgs sorted in strcmp(<pkg>) order */
  uint32_t num_vdirs;        /* Number of unique relative directory paths */
  uint32_t ht_mask;          /* Power-of-two minus 1 (>= 15, load factor <= 0.65) */
  uint32_t num_postings;     /* uint32_t words in postings[] */
  uint32_t num_vchildren;    /* struct fswc_vchild entries in vchildren[] */
  uint32_t strtab_size;      /* >= 1; strtab[strtab_size - 1] == '\0' */
  uint32_t global_flags;     /* FSWC_GF_ALL_WORLD_SEARCH | FSWC_GF_ALL_WORLD_RX */
  uint32_t pkgs_off;         /* 8B-aligned offset to struct fswc_pkg[num_pkgs] */
  uint32_t vdirs_off;        /* 8B-aligned offset to struct fswc_vdir[num_vdirs] */
  uint32_t ht_off;           /* 8B-aligned offset to struct fswc_ht_entry[ht_mask + 1] */
  uint32_t postings_off;     /* 8B-aligned offset to uint32_t postings[num_postings] */
  uint32_t vchildren_off;    /* 8B-aligned offset to struct fswc_vchild[num_vchildren] */
  uint32_t strtab_off;       /* 8B-aligned offset to char strtab[strtab_size] */
  uint32_t reserved;
};

struct fswc_pkg {
  uint32_t name_off;         /* Offset in strtab (e.g. "bash", "glibc") */
  uint16_t name_len;
  uint16_t flags;            /* FSWC_PKG_* */
};

struct fswc_vdir {
  uint32_t children_start;   /* Slice in vchildren[] sorted by strcmp(basename) */
  uint32_t children_count;
  uint32_t dir_postings_ref; /* Inline FSWC_POSTING_PACK if cnt==1, else index in postings[] */
  uint16_t dir_postings_cnt; /* Packages possessing this vdir as a real DT_DIR */
  uint16_t flags;            /* FSWC_VDIR_ALL_WORLD_RX | FSWC_VDIR_ALL_WORLD_SEARCH */
};

/* 32-byte open-addressed entry: Key = (parent_vdir_id, basename).
 * Hash canonicalization: if raw 64-bit hash == 0, canonicalize to 1 so 0 == empty.
 * Also stores <pkg> names under parent_vdir_id = FSWC_VDIR_PKGS with
 * all_cnt = 1 and all_ref = FSWC_POSTING_PACK(pkg_idx, DT_DIR). */
struct fswc_ht_entry {
  uint64_t hash;             /* Canonicalized non-zero 64b hash; 0 = empty slot */
  uint32_t parent_vdir_id;   /* 0 = <prefix>/*, 1..num_vdirs-1 = subdir, UINT32_MAX = pkg */
  uint32_t name_off;         /* Component string in strtab */
  uint16_t name_len;
  uint16_t flags;            /* FSWC_ENT_HAS_LNK | FSWC_ENT_RESTRICTED_SEARCH | ... */
  uint32_t child_vdir_id;    /* Valid vdir_id (< num_vdirs) whenever >=1 pkg has DT_DIR
                              * here (even if empty, children_count==0); else FSWC_NONE */
  uint32_t all_ref;          /* Inline FSWC_POSTING_PACK if all_cnt==1, else index in postings[] */
  uint16_t all_cnt;          /* Number of packages containing this (parent_vdir, name) */
  uint16_t dir_cnt;          /* Subset count with DT_DIR (or DT_LNK for GLOB_ONLYDIR hint) */
};

struct fswc_vchild {
  uint32_t ht_slot;          /* Direct index into ht[] (<= ht_mask) for wildcard scan */
};
```

#### Handling Top-Level Non-SquashFS Siblings in `<prefix>` (`/sw/*.squashfs` & Unmounted Dirs)

On a real Fluffy system, `/sw` contains 91 `/sw/<pkg>-<ver>.squashfs` regular files (`DT_REG`) alongside `/sw/<pkg>` SquashFS mountpoints, and during `swctl build` sandboxes or after partial unmounts `/sw` may also contain empty/mutable non-SquashFS directories (`DT_DIR`). `FSWC` v5 handles both **without** disabling the cache:

- The content-addressed `blob_<pkgset_hash>` indexes strictly the `N` immutable `SQUASHFS_MAGIC` child mounts (`pkgs[0..num_pkgs-1]`).
- The lightweight per-namespace binding `ns_<prefix_mnt_id>_<prefix_ino>` (validated against `statx(prefix)` `ctime_ns`/`mtime_ns`) records `<prefix>`'s own non-SquashFS top-level entries:
  1. **Top-level non-directories (`DT_REG` `*.squashfs` files, `DT_LNK`)**: Cannot have path children (`*.squashfs/bin/bash` is `ENOTDIR`), so they have **zero** effect on 2+-component queries (`/sw/*/bin/...`, `/sw/*/lib/...`), while 1-component `glob("/sw/*.squashfs")` or `glob("/sw/*")` merges them directly from the `ns_*` top-level table.
  2. **Mutable / unmounted `DT_DIR` siblings (`mutable_dirs[0..M-1]`)**: Instead of bailing out on all $N=91$ SquashFS mounts when $M > 0$, `fswc` performs a **hybrid merge**: all $N$ immutable SquashFS mounts resolve in $O(\text{depth})$ from `blob_<pkgset_hash>`, and only the $M$ mutable directories (typically $M=0$ in `swctl` lockdown, or empty mountpoints) are probed via the kernel and merged in `strcmp` `<pkg>` order ($O(M)$ graceful degradation).

#### Reader Corruption & Bounds Validation

Before `fswc_map_blob()` exposes any SHM mapping, it verifies with 64-bit overflow-checked arithmetic:
1. `st.st_size >= sizeof(struct fswc_header)` and `hdr->total_size == (uint64_t) st.st_size && hdr->total_size <= (1u << 30)` (1 GiB cap so 32-bit offsets never wrap), `num_pkgs <= FSWC_MAX_PKGS`, `(ht_mask & (ht_mask + 1)) == 0 && ht_mask >= 15`.
2. Every section (`pkgs`, `vdirs`, `ht`, `postings`, `vchildren`, `strtab`) is 8-byte aligned and `off + count * elem_sz <= total_size`, and `strtab_size >= 1 && strtab[strtab_size - 1] == '\0'`.
3. Every open-addressed lookup loop bounds iterations to `step <= ht_mask` so a malformed/full table with zero `hash == 0` slots can never infinite-loop `ld.so` or `libc.so`.

### 4.3 Internal Allocation-Free Query Primitives

1. **`fswc_match_pkg_wild_relpath(slot, relpath, rel_len, want_dir_only, &cursor)`**:
   - Walks `/` components of `relpath` from `vdir_id = 0` with **zero heap allocation** and **zero locks**.
   - If any intermediate component has `FSWC_ENT_HAS_LNK` (e.g., `/sw/ncurses/include/ncursesw -> .`), those specific `DT_LNK` packages (plus any `mutable_dirs[0..M-1]`) are flagged in `cursor` for kernel probe in `<pkg>` `strcmp` order rather than silently dropped.
   - **Used by `elf/dl-load.c` (`_dl_init_paths` & `open_path`)**:
     - `_dl_init_paths` populates `rtld_search_dirs.dirs[]` in `strcmp(<pkg>)` order by merging `(0, sub)` `DT_DIR` postings with kernel-`stat`ted `DT_LNK` postings and any `mutable_dirs[0..M-1]` (tagging `DT_LNK`/mutable entries `pkg_idx = FSWC_NONE` so `open_path` probes them via kernel `open_verify()`, while keeping `dlinfo(RTLD_DI_SERINFO)`, `LD_DEBUG=libs`, and `AT_SECURE` `is_trusted_path_normalize` 100% intact!).
     - `open_path` bypasses `FSWC` skipping when `GLRO(dl_debug_mask) & DL_DEBUG_LIBS` (preserving exact `"trying file=..."` diagnostics), queries `fswc_match_pkg_wild_relpath` for each `(capstr, soname)` combination (`glibc-hwcaps` preserved), and iterates **all** matching postings through `open_verify()` (so if an earlier package holds a linker script or wrong-ELF-class file rejected by `open_verify()`, search continues seamlessly to later postings).
   - **Used by `posix/execvpe.c` (`__execvpe_common`)**:
     - Detects `*`, `?`, and `[` wildcards in `PATH` elements (`CLONE_VM | CLONE_VFORK` safe): uses `fswc_match_pkg_wild_relpath` on already-mapped `GL` views for `<prefix>/*/<relpath>` of arbitrary depth (with stack `__getdents64` + `fnmatch` fallback for unmapped views in a `vfork` child or non-`<prefix>/*` wildcards like `/sw/[b]ash/bin`), iterates matching `<pkg>` postings and any `mutable_dirs` in `strcmp` order, invokes `__execve`, routes `ENOEXEC` through upstream's `scripts_argv` (`_PATH_BSHELL`) fallback for `#!`-less `+x` scripts, and preserves sticky `got_eacces = true` → `errno = EACCES`.
2. **`fswc_glob_walk(prefix, prefix_len, slot, rel_pattern, flags, errfunc, pglob)`**:
   - Replaces both `fc_glob_try` (Cases A/B/C) and `glob_literal_suffix_try` in `posix/glob.c` (~130 lines vs. ~450 lines).
   - Walks `rel_pattern` component by component across `(vdir_id, comp)` (`O(1)` hash jump on literal components, `vchildren[]` `fnmatch` scan on wildcards, cycle-free `child_vdir_id` recursion on `GLOB_GLOBSTAR` `**`), kernel-probing only `DT_LNK` branches or `mutable_dirs[0..M-1]` when present, and sorting `[oldcount, gl_pathc)` with `collated_compare`.
   - Matches `glibc`'s exact `GLOB_ONLYDIR` hint semantics (`DT_DIR` and `DT_LNK` kept; `DT_REG` pruned) and `GLOB_MARK` semantics (`'/'` appended to `DT_DIR` leaf matches; `DT_LNK` leaf matches kernel-`stat`ted when `GLOB_MARK` is set), and falls back to `glob_in_dir` on `GLOB_ALTDIRFUNC` or `!WORLD_READ_SEARCH` directories (so `errfunc` / `GLOB_ERR` callbacks fire identically on unreadable directories).
3. **`fswc_probe_exact(path, syscall_kind, flags)` (`mode=2` Read-Only VFS Negative Filter)**:
   - Hooked into read-only `open`/`openat` (`(oflag & (O_ACCMODE | O_CREAT | __O_TMPFILE | O_TRUNC | O_EXCL)) == O_RDONLY`, plus `(oflag & ~(O_PATH | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)) == 0` when `oflag & O_PATH`), `stat`/`fstatat`/`lstat` (`(flag & ~(AT_SYMLINK_NOFOLLOW | AT_NO_AUTOMOUNT | AT_EMPTY_PATH)) == 0`), `statx` (`statxbuf != NULL && !(mask & STATX__RESERVED) && (flags & ~(AT_SYMLINK_NOFOLLOW | AT_NO_AUTOMOUNT | AT_EMPTY_PATH | AT_STATX_SYNC_TYPE)) == 0 && (flags & AT_STATX_SYNC_TYPE) != AT_STATX_SYNC_TYPE`, preserving `io/tst-statx` `-EINVAL` on `AT_STATX_FORCE_SYNC | AT_STATX_DONT_SYNC`), and `access`/`faccessat` (`(mode & ~(R_OK | W_OK | X_OK)) == 0 && (flag & ~(AT_EACCESS | AT_SYMLINK_NOFOLLOW | AT_EMPTY_PATH)) == 0`) when `path != NULL && path[0] == '/'` (where Linux `path_init` ignores `dfd`).
   - **100% POSIX Async-Signal-Safe (`man 7 signal-safety`)**: Wait-free, lock-free, and allocation-free—never acquires `GL(_dl_fswc_state).lock` and never `mmap`s/builds blobs (safe even if invoked from a signal handler interrupting a `fswc` writer!). Positive leaf hits **always** fall through to the kernel (`open` needs an `fd`, `stat` needs inode metadata, `access` needs mode bits); only negative (`-ENOENT`) and non-directory traversal (`-ENOTDIR`, including trailing `/` on `DT_REG`/`DT_FIFO`/`DT_SOCK`/`DT_CHR`/`DT_BLK`) return directly from user space.
   - **Per-package `d_type`, granular `WORLD_SEARCH` & bounded `vdir_stack[32]` `..` walk**:
     1. Loads `snap = atomic_load_acquire(&slot->snap)` and checks `!snap->stale && (snap->flags & FSWC_SLOT_ANCESTORS_WORLD_SEARCH)`. If `CLOCK_MONOTONIC_COARSE - last_check_ns > 50_000_000` (50 ms), runs **inline lock-free stack-only revalidation**: `statx(AT_FDCWD, prefix, AT_SYMLINK_NOFOLLOW, ...)` (plus `statx(..., AT_SYMLINK_NOFOLLOW, ...)` on each intermediate ancestor when `<prefix>` has depth $\ge 2$, verifying `(dev, ino)` and `(mode & 0111) == 0111` haven't changed) + a **paginated** `listmount(prefix_mnt_id)` loop over `uint64_t mnt_ids[256]` (`req.param = mnt_ids[255]`). If the `(prefix_dev, prefix_ino, prefix_ctime_ns, prefix_mtime_ns, mnt_list_hash128)` tuple still matches `snap`, atomically stores `last_check_ns = now` (~4.1 µs per 50 ms = 0.008% overhead, keeping multi-second `cc1plus` compiles fast indefinitely!); if it mismatches, sets `snap->stale = 1` and falls through to the kernel.
     2. Resolves `<pkg>` via `(FSWC_VDIR_PKGS, pkg_name)`. If absent (e.g., mutable dir or `*.squashfs` file) or `!(pkg.flags & FSWC_PKG_IMMUTABLE)`, falls through immediately to the kernel (avoiding any stale `-ENOTDIR` vs. `-ENOENT` window if a top-level `/sw/*.squashfs` file is unlinked between 50 ms revalidations).
     3. Maintains `vdir_stack[32]` (`depth = 0` at `vdir_id = 0`, requiring `(pkg.flags & FSWC_PKG_ALL_WORLD_SEARCH) || (vdir[cur].flags & FSWC_VDIR_ALL_WORLD_SEARCH)` at every directory step so one `0700` dir in `pkg_B` never pessimizes `pkg_A` or sibling trees). At **every** component `c`:
        - Empty `//` or `.`: valid no-op *only* because current `vdir` is already verified `DT_DIR` on `pkg` with `WORLD_SEARCH`.
        - `..`: if `depth == 0`, falls through to kernel (escapes `<prefix>/<pkg>`); otherwise pops `vdir_stack[--depth]`—100% POSIX-legal because every pushed `vdir` on the stack was verified to exist on `pkg` as a real non-symlink `DT_DIR` with `WORLD_SEARCH`! (Accelerates GCC's `lib/gcc/.../../../../../include` paths safely.)
        - Normal component `c`: looks up `pkg` in `(cur_vdir, c)`'s postings (binary search when `all_cnt > 8`, linear scan when `<= 8`). If `pkg` is absent → returns `-ENOENT` (~15 ns)! If `pkg`'s `d_type == DT_LNK` (e.g., `include/ncursesw -> .` or `lstat("link/")`) → **falls through to kernel**! If more slash/components follow and `pkg`'s `d_type != DT_DIR` → returns `-ENOTDIR`! If more components follow and `depth == 32` (deep path `< PATH_MAX`) or child `vdir` lacks `WORLD_SEARCH` → **falls through to kernel**; otherwise pushes `child_vdir_id` (`< num_vdirs`, guaranteed allocated even for empty `DT_DIR`s) onto `vdir_stack`.
     4. Uses `INTERNAL_SYSCALL_CALL` internally so `fswc` never clobbers thread-local `errno` before a kernel fallback.

### 4.4 Content-Addressed `MAP_SHARED` Storage, Tier-1 Subtree Cache & Live Coherence

All shared-memory artifacts live inside a per-UID isolated directory `/dev/shm/.fswc-<euid>/`:

1. **Per-UID `0700` Directory, `SIGBUS`-Free Eviction & Symlink Hardening**:
   - Created with `mkdir("/dev/shm/.fswc-<euid>", 0700)` and opened with `open(..., O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)`.
   - Verified via `fstat(dirfd)`: `S_ISDIR(st.st_mode) && st.st_uid == euid && (st.st_mode & 07777) == 0700`. If verification fails, `FSWC` runs uncached without error.
   - All file operations (`openat`, `unlinkat`, `renameat`) use `dirfd` directly (zero `/proc` dependency). Writers publish immutable `0400` files atomically via `renameat` and **never** `ftruncate` or overwrite an existing published file in place (which would `SIGBUS` concurrent `MAP_SHARED` readers).
   - **Bounded SHM Footprint across Ephemeral `swctl` Sandboxes**: When `fstatfs(dirfd)` reports `< 32 MiB` free or directory entry count exceeds `512` files, a writer acquiring non-blocking `flock(dirfd, LOCK_EX | LOCK_NB)` evicts the oldest `ns_*` and `blob_*` entries via `unlinkat(dirfd, name, 0)` (safe while mapped on `tmpfs`), preferentially retaining compact `pkg_*` Tier-1 files (~6 MiB total across all 91 packages); if `< 16 MiB` remains after eviction, writes are skipped cleanly.
2. **Three Artifact Types (Decoupling Namespace Identity from Content)**:
   - **`pkg_<128b_pkg_id>` (Tier-1 Per-Package Subtree Cache)**:
     - Keyed by Git-style `statx(STATX_BASIC_STATS)` tuple `(dev_major, dev_minor, ino, size, ctime_sec, ctime_nsec, mtime_sec, mtime_nsec)` of the `.squashfs` backing file from `/sys/dev/block/<maj>:<min>/loop/backing_file` (falling back to `<prefix>/<basename>`—e.g. `/sw/bash-5.3.squashfs`—when `swctl` loop-mounted `$ON` outside `chroot "$FLUFFY"`).
     - Novel `BUILD_NEEDS` subsets assemble `blob_<pkgset_hash>` in memory from `pkg_*` files in ~1–2 ms with **zero `getdents64` syscalls**, immune to `/dev/loopN` churn. If `/sys` is unmounted or inaccessible, `fswc` skips Tier-1 `pkg_*` persistence and keys `blob_*` directly on `(mnt_id_unique, sb_dev, root_ino, root_mtime_ns)` so Tier-2 `blob_*` sharing still works without `/sys`.
   - **`blob_<128b_pkgset_hash>` (Merged Virtual Trie)**:
     - Pure function of the sorted `(pkg_name, pkg_id_128, pkg_flags)` vector. Mapped `PROT_READ | MAP_SHARED` (`0 KiB` CoW dirtying).
   - **`ns_<prefix_mnt_id>_<prefix_ino>` (Namespace Binding)**:
     - Keyed by `(prefix_mnt_id, prefix_dev, prefix_ino, prefix_ctime_ns, prefix_mtime_ns, mnt_list_hash128)` → `pkgset_hash128` + `<prefix>`'s top-level non-SquashFS `*.squashfs` / `mutable_dirs[]` list (or `NO_SQUASHFS_CHILDREN` bit).
3. **Mountpoint-Filtered `listmount` + `statmount`, Kernel `< 6.8` Fallback & Live Coherence**:
   - **Graceful Kernel `< 6.8` Fallback (`--enable-kernel=5.10`)**: If `statx` lacks `STATX_MNT_ID_UNIQUE` or `listmount`/`statmount` returns `-ENOSYS` (e.g., `CROSS=1` host builds on older host kernels), `fswc` disables caching (`mode = 0`) cleanly with zero error.
   - **Handling shared parent mounts (`/` hosting `/sw`, `/tmp`, `/home`) & `chroot`**: On a booted system, `/sw`, `/tmp`, and `/home` may all reside as plain directories on root Btrfs `/` (sharing `/`s `stx_mnt_id`). On a cold `ns_*` build, `fswc` calls `statmount(mnt_id, STATMOUNT_SB_BASIC | STATMOUNT_MNT_BASIC | STATMOUNT_MNT_POINT)` (which Linux resolves relative to `current->fs->root`, matching `chroot` paths automatically) and filters strictly to mounts whose `mnt_point` is `<prefix>/<pkg>` (or descendant `<prefix>/<pkg>/...` for overmount checks). If zero `SQUASHFS_MAGIC` mounts sit under `<prefix>/`, `fswc` records `NO_SQUASHFS_CHILDREN` in memory (keyed on `(prefix_mnt_id, prefix_ino, mnt_list_hash128)`) so `glob("/tmp/*")` and `glob("/home/*")` bail out in ~4 µs (`statx` + `listmount`) without repeating `statmount` or creating `blob_*` files.
   - **`mode=1` (`glob`, `execvpe`)**: Revalidates `statx(AT_FDCWD, prefix, AT_SYMLINK_NOFOLLOW, ...)` + paginated `listmount(prefix_mnt_id)` (~4.1 µs) on every call (amortized once per prefix within a `GLOB_PATHS` call).
   - **`mode=2` (single-path VFS negative filter)**:
     1. Verifies every ancestor directory from `/` through `<prefix>` via `O_PATH | O_NOFOLLOW` is a real non-symlink directory **and** has `(st_mode & 0111) == 0111` with no POSIX access ACL (`getxattr("system.posix_acl_access") == -ENODATA`), setting `FSWC_SLOT_ANCESTORS_WORLD_SEARCH` (preventing `ENOENT`-instead-of-`EACCES` DAC leaks when a `0700` parent directory like `mkdtemp("/tmp/fswc.XXXXXX")` is warmed as `root` before `setresuid` privilege drop!).
     2. Hooks `mount`, `umount2`, `move_mount`, `fsmount`, `chroot`, `pivot_root`, `unshare`, `setns`, `set*uid`/`set*gid`, `setfsuid`/`setfsgid`, and `capset` in `glibc` to bump an atomic invalidation counter forcing immediate revalidation.
     3. Re-runs wait-free stack-only `statx` + `listmount` inline whenever `CLOCK_MONOTONIC_COARSE - last_check_ns > 50_000_000` (50 ms).

### 4.5 Strict POSIX & Security Invariants Checklist

| Edge Case | Required `FSWC` v5 Behavior |
| :--- | :--- |
| Read-only bind mount of mutable dir (`mount --bind -o ro`) | `sb_magic != SQUASHFS_MAGIC` → **not** marked `FSWC_PKG_IMMUTABLE`; queries probe via kernel. |
| Child overmount inside SquashFS (`/sw/foo/include` tmpfs) | Detected via `listmount` + `statmount` (`mnt_point` under `<prefix>/foo/...`) → `foo` excluded from `FSWC_PKG_IMMUTABLE` (moved to `mutable_dirs[]`). |
| `/sw/*.squashfs` files & unmounted/mutable `/sw/local` dirs | `*.squashfs` (`DT_REG`) stored in `ns_*` top-level table; `mutable_dirs[]` hybrid-merged via kernel in `strcmp` order while all 91 SquashFS mounts stay cached! |
| Internal directory symlink (`/sw/ncurses/include/ncursesw -> .`) | Per-package `d_type == DT_LNK` stored in `postings[]` → `fswc_probe_exact` and `fswc_glob_walk` fall through to kernel for that package (never false `ENOENT`). |
| `..` component (`/sw/gcc/lib/gcc/.../../../../../include/x.h`) | Walked on `vdir_stack` *only* across verified real `DT_DIR`s on `pkg` with `WORLD_SEARCH`; `DT_LNK` or `depth == 0` falls through to kernel. |
| File traversed as directory (`/sw/bash/bin/bash/` or `.../bash/x`) | Target `pkg` posting has `d_type == DT_REG` ≠ `DT_DIR` → returns `ENOTDIR`, **never** `ENOENT`. |
| `0111` execute-only / `0700` root-only / ACL dirs + `setfsuid` | Unconditional kernel fallthrough (even for `uid == 0`!) whenever `!WORLD_SEARCH` (`0111` + `ENODATA` ACL) or `!WORLD_READ_SEARCH` (`0555` + `ENODATA` ACL); immune to `setfsuid`/`capset`/`access()` `ruid` differences. |
| Component `> 255` bytes (`NAME_MAX`) or path `>= PATH_MAX` | Immediate bailout prior to hash probe → kernel returns exact `ENAMETOOLONG`. |
| Non-`C` `LC_COLLATE` (e.g., `en_US.UTF-8`) | `fswc_glob_walk` sorts each segment's output slice using `glibc`'s `collated_compare`, matching uncached `glob()` byte-for-byte. |

---

## 5. Per-Package Modifications & Test Suite Recommendations

Every package below is modified (or scheduled for modification) from unmodified upstream source to participate in Fluffy's `<glob.h>` / `GLOB_PATHS` / late-bound `/sw/*` architecture. Each entry specifies **(1) Current State**, **(2) Target Ideal State**, and **(3) Upstream + Fluffy Test Suite Requirements** for `CHECK()`.

---

### Group A: Core C Library & Toolchain

#### 1. `glibc` (`sw/glibc`, `sw/glibc-pass1` — v2.44)
- **Current State** (`sw/glibc-2.44-fluffy-source.patch`, `sw/glibc-2.44-fluffy-test.patch`):
  - High-bit `<glob.h>` / `<fnmatch.h>` flags implemented; `__GI_glob64` hidden alias fixed in `sysdeps/unix/sysv/linux/glob.c`; NSS/DNS stateless `/sw/*/etc/...:/etc/...` fallback (`nss_database.c`, `files-init.c`, `res_hconf.c`, `resolv_conf.c`, `getusershell`, `localtime`); `paths.h` `_PATH_DEFPATH = "/sw/*/bin"`.
  - Carries prototype `posix/glob_fluffy_cache.h` (3,285 lines) + `fc_glob_try` / `glob_literal_suffix_try` in `posix/glob.c`.
- **Target Ideal State**:
  - Replace `posix/glob_fluffy_cache.h` with `include/fswc.h` + `sysdeps/unix/sysv/linux/fswc.c` (`FSWC` v5 Merged Virtual Trie, unified writable `GL` `_rtld_global._dl_fswc_state` multi-prefix table + futex word reset on `_Fork`, `GLIBC_TUNABLES=glibc.fswc.{mode,max_inodes}`, per-UID `/dev/shm/.fswc-<uid>/` `0400` `MAP_SHARED` blobs + Tier-1 `pkg_*` cache).
  - Fix the 3 `GLOB_PATHS` corner cases in `posix/glob.c` (per-segment `GLOB_NOCHECK`/`GLOB_NOMAGIC` forwarding, single `GLOB_DOOFFS` initialization prior to segment `0`, and brace-aware `next_colon_sub` under `GLOB_BRACE`), `glob_dirscan`'s backslash-escape skip on `\@(` / `\+(` / etc. under `GLOB_EXTMATCH`, and `posix/glob_internal.h`'s unconditional `extmatch = 1` leak (`__glob_pattern_type_ext` gated on `flags & GLOB_EXTMATCH`), and restore `tst-rtld-run-static` in `elf/Makefile`.
  - Wire `fswc_match_pkg_wild_relpath` into `elf/dl-load.c` and `posix/execvpe.c`; wire `fswc_glob_walk` into `posix/glob.c` (deleting `fc_glob_try` and `glob_literal_suffix_try`); wire `fswc_probe_exact` into `mode=2` read-only VFS wrappers (`open`/`openat`, `stat`/`lstat`/`fstatat`/`statx`, `access`/`faccessat`).
  - Optional enhancement from [NOTES.md](NOTES.md): wildcard executable path resolution when `file` contains `/` and glob metacharacters in `execvpe` / `execve` / `posix_spawn` (first lexicographical match wins).
- **Test Suite Recommendations**:
  - **Upstream Suite (`CHECK()`)**: `TIMEOUTFACTOR=4 make -O -j$(nproc) check` (specifically gating `check-abi`, `conform/*/linknamespace` including `conform/ISO11/threads.h/linknamespace` and `conform/POSIX/*/linknamespace`, `posix/tst-gnuglob`, `posix/tst-glob-tilde`, `posix/globtest`, `posix/tst-fnmatch`, `posix/tst-execvp1..4`, `posix/tst-spawn*`, `elf/tst-dlopen*`, `nss/tst-fluffy-stateless-etc`).
  - **Tier-1 Fluffy `make check` Tests (`sw/glibc-2.44-fluffy-test.patch`)**:
    1. `posix/tst-glob-fluffy-flags.c`: Exhaustive unit tests for `GLOB_PATHS` (empty segments `":a"`, `"a::b"`, `"a:"`, `""` → `"."`, escaped `\:` and `\\:`, colons inside `[a:b]`, `@(a:b)`, and `{/a:/b,/c}`, `GLOB_DOOFFS`, per-segment `GLOB_NOCHECK`/`GLOB_NOMAGIC`, per-segment `LC_COLLATE` ordering across `C` and `en_US.UTF-8`), `GLOB_KEEP_SLASHES`, `GLOB_EXTMATCH` (including `glob_dirscan` on escaped `\@(` / `\+(` with `/` and `GLOB_NOMAGIC` when `GLOB_EXTMATCH` is unset), `GLOB_CASEFOLD`, `GLOB_SKIPDOTS`, `GLOB_GLOBSTAR` (`**` cycle-free symlink rules, `**/**` collapse), and `GLOB_DOTDOT` / `FNM_DOTDOT`.
    2. `posix/tst-fswc-oracle.c`: Differential oracle spawning workers with `GLIBC_TUNABLES=glibc.fswc.mode={0,1,2}` across live `/sw/*` queries (`glob`, `execvpe`, `dlopen`, `openat`, `statx`, `faccessat`), asserting identical return values, `errno`s, `statx` fields, and `glob_t` vectors.
    3. `posix/tst-fswc-edge.c`: `ENOTDIR` on `/sw/bash/bin/bash/` and `/sw/bash/bin/bash/x`, `ENAMETOOLONG` (256-byte component & `PATH_MAX`), `.`/`..`/`//` normalization, symlinked prefix (`ln -s /sw /tmp/sym` → retarget to `/tmp/empty`), `O_CREAT`/`O_DIRECTORY`/`O_NOFOLLOW`/`AT_SYMLINK_NOFOLLOW`/`dfd != AT_FDCWD`, `glibc.fswc.max_inodes=16` fallback, non-SquashFS `/tmp` 0-blob bailout, and corrupted/truncated SHM blob rejection without `SIGBUS`.
    4. `posix/tst-fswc-concurrency.c` & `posix/tst-fswc-vfork.c` & `posix/tst-fswc-static.c`: 16-thread post-`RELRO` prefix stampede, cold-prefix `vfork()`+`execvpe()` heap/lock safety, `EACCES` preservation across non-executable candidates, and `libc.a` static linking.
  - **Tier-2 Standalone Privileged Torture Runner (`test-fswc`) & Benchmark Suite (`bench-fswc`)**:
    - Isolated `CLONE_NEWNS` runner building synthetic `.squashfs` images (`0700`, `0111`, `0005`, POSIX ACL xattrs, relative/external/dangling/`ELOOP` symlinks, 16-deep dirs, 255-byte names), testing live in-process and external-process `mount`/`umount2`/grandchild-overmount/`chroot`/`/dev/loopN` churn + `setresuid` privilege drop across `mode={0,1,2}`, plus `bench-fswc` verifying `Private_Dirty == 0 KiB` via `/proc/self/smaps_rollup`.

#### 2. `binutils` (`sw/binutils`, `sw/binutils-pass1`, `sw/binutils-pass2` — v2.47)
- **Current State** (`sw/binutils-2.47-fluffy-source.patch`):
  - Embeds 3,286-line `include/fluffy-cache.h` and calls `fc_expand_dirs` / `fc_lookup_path` in `ld/ldfile.c`; recipe passes `--with-lib-path='/sw/*/lib'` (which `genscripts.sh` emits into default linker scripts as `SEARCH_DIR("=/sw/*/lib")`). Also recursively calls `ldfile_add_library_path` on `globbuf.gl_pathv[i]`, which would re-glob or infinite-recurse if a matched directory name contained `[`, `*`, or `?`.
- **Target Ideal State**:
  - **Delete `include/fluffy-cache.h` and `ldfile_try_open_bfd` `fc_lookup_path` hunks completely (-3,295+ LOC)**.
  - Keep `ld/ldfile.c:ldfile_add_library_path`'s `=` / `$SYSROOT` (`ld_sysroot`) prefix expansion **before** a ~15-line `<glob.h>` (`glob(name, GLOB_ONLYDIR, NULL, &gl)`) check when `strpbrk(name, "*?[") != NULL`, appending each matched directory directly to `search_tail_ptr` via a non-recursive literal helper (never re-invoking `=`/`$SYSROOT`/glob expansion on `globbuf.gl_pathv[i]`, and using only standard `GLOB_ONLYDIR` so `binutils-pass1` compiles cleanly against any bootstrap host `<glob.h>` before `glibc-pass1` exists). `glibc` `FSWC` (`mode=2`) accelerates both the startup `glob()` and `ld`'s subsequent `bfd_openr()` library probes transparently.
- **Test Suite Recommendations**:
  - **Upstream Suite (`CHECK()`)**: `make -k check` — require zero unexpected failures across all 5 DejaGnu suites (`binutils`, `gas`, `ld`, `libctf`, `libsframe`).
  - **Fluffy Regression Tests (`sw/binutils-2.47-fluffy-test.patch` or `CHECK()`)**:
    1. Verify `ld --verbose` default linker script contains `SEARCH_DIR("=/sw/*/lib")`.
    2. Link a binary with `-lreadline` (which has an indirect `DT_NEEDED` on `libncursesw.so.6` in a separate `/sw/ncurses/lib` mount) **without** `-L` or `-rpath-link`, verifying both direct `-l` and `ldelf.c` secondary `DT_NEEDED` resolution succeed via wildcard `SEARCH_DIR` (both with default sysroot and `--sysroot`), plus `-L` wildcard expansion over a directory containing `[1]`.

#### 3. `gcc` (`sw/gcc`, `sw/gcc-pass1`, `sw/gcc-pass2` — v16.2.0)
- **Current State** (`sw/gcc-16.2.0-fluffy-source.patch`):
  - Embeds 3,282-line `include/fluffy-cache.h` and hooks `fc_lookup_path` / `fc_inc_dir_can_skip` / `fc_expand_dirs` into `gcc/incpath.cc`, `gcc/file-find.cc`, `gcc/gcc.cc`, and `libcpp/files.cc`, alongside build/config wildcard hunks in `gcc/Makefile.in`, `gcc/configure`, and `gcc/cppdefault.cc`. Also recursively calls `add_path` / `add_prefix` / `do_add_prefix` on `gbuf.gl_pathv[gi]`, which would re-glob if a matched directory name contained `[`, `*`, or `?`.
- **Target Ideal State**:
  - **Delete `include/fluffy-cache.h` and all `fc_*` calls across `gcc/incpath.cc`, `gcc/file-find.cc`, `gcc/gcc.cc`, and restore `libcpp/files.cc` to 100% unmodified upstream source (-3,380+ LOC)** (avoiding post-hash `file->path` mutation in `libcpp/files.cc` while `FSWC` `mode=2` accelerates both `maybe_shorter_path` `lstat`s and `open_file` `open`s inside `libc.so`).
  - Retain the clean `<glob.h>` (`glob(..., GLOB_ONLYDIR, ...)`) wildcard expansions in `gcc/incpath.cc` (`add_path`), `gcc/gcc.cc` (`add_prefix` + `do_spec_2` multi-word `MD_EXEC_PREFIX` used by `gcc-pass1` and `gcc-pass2`), and `gcc/file-find.cc` (`do_add_prefix`, preserving reverse `first` insertion order!), inserting matched `gbuf.gl_pathv` entries via non-recursive literal helpers (never re-globbing matched directory names, and using only standard `GLOB_ONLYDIR` so `gcc-pass1` compiles cleanly on any bootstrap host `<glob.h>` before `glibc-pass1` exists), plus the `gcc/Makefile.in`, `gcc/configure`, and `gcc/cppdefault.cc` cross/header hunks.
- **Test Suite Recommendations**:
  - **Upstream Suite (`CHECK()`)**: `make -k check` (DejaGnu `gcc`, `g++`, `libstdc++`, `libgomp`, `libatomic`, `libitm`), specifically inspecting `gcc.dg/cpp/*` (`#include_next` across multiple `/sw/<pkg>/include` mounts!) and `g++.dg/pch/*` (precompiled headers).
  - **Fluffy Regression Tests**:
    1. Run [`check-toolchain`](check-toolchain) (C + C++ compile/link/run including `<iostream>`, `<zlib.h>`, and `<ffi.h>` from separate SquashFS mounts with **zero `-I` and zero `-L` flags**).
    2. Add an explicit `#include_next <stdlib.h>` test (`g++ -E -x c++ - <<< '#include <cstdlib>' >/dev/null`) verifying `libstdc++` → `glibc` header chaining across `/sw/libstdcpp/include/c++/16.2.0` and `/sw/glibc/include`.

---

### Group B: Interactive Shells, Readline & Core Language Runtimes

#### 4. `bash` (`sw/bash`, `sw/bash-pass1` — v5.3)
- **Current State** (`sw/bash-5.3-fluffy-source.patch`):
  - Already deleted bundled `lib/glob/{glob.c,glob_loop.c,gmisc.c}` (-1,849 LOC)!
  - `pathexp.c` (`shell_glob_filename`, `shell_glob_path`), `findcmd.c` (`find_user_command_in_path`, `find_in_path_element`), `bashline.c` (`command_word_completion_function`), `shell.c` (`#include "pathexp.h"`, sourcing `/sw/*/etc/profile:/etc/profile`), and bundled `lib/readline/bind.c` all delegate directly to `glibc` `glob()` with `GLOB_PATHS`, `GLOB_EXTMATCH`, `GLOB_GLOBSTAR`, `GLOB_SKIPDOTS`, `GLOB_DOTDOT`, `GLOB_CASEFOLD`.
- **Target Ideal State**:
  - Keep current clean architecture; verify zero remaining dead prototypes from `lib/glob/glob.h` once `FSWC` v5 lands.
- **Test Suite Recommendations**:
  - **Upstream Suite (`CHECK()`)**: `make tests` (specifically gating `run-glob-test`, `run-glob-bracket`, `run-globstar`, `run-extglob`, `run-extglob2`, `run-extglob3`, `run-type`, `run-complete`).
  - **Fluffy Regression Tests (`tests/glob.tests` & `CHECK()`)**:
    1. Command lookup (`type -P`, `hash`), `PATH=/sw/*/bin` empty-segment `:` handling (`PATH=:/sw/*/bin`), and `compgen -c` completion across `/sw/*/bin`.
    2. Login shell profile discovery order across `/sw/*/etc/profile:/etc/profile`.
    3. Interactive/script parity on `shopt -s globstar extglob dotglob nocaseglob globskipdots nullglob failglob`.

#### 5. `readline` (`sw/readline` — v8.3)
- **Current State** (`sw/readline-8.3-fluffy-source.patch`, plus `test_rl.c` `CHECK()` harness in `sw/readline`):
  - Patches `bind.c` (`_rl_read_init_file`) to expand `"/sw/*/etc/inputrc:" SYS_INPUTRC` with `glob(..., GLOB_PATHS | GLOB_NOESCAPE, ...)`, loading vendor inputrc files first so `/etc/inputrc` overrides last, and supports colon-delimited `INPUTRC` / `rl_read_init_file()` paths, but checks `strchr(filename, ':') != 0` *before* trying a literal open (which would split a literal user filename containing `:` and map leading/trailing empty `:` segments to `"."`).
- **Target Ideal State**:
  - Pass `-DSYS_INPUTRC='"/sw/*/etc/inputrc:/etc/inputrc"'` from build `CPPFLAGS` (eliminating the hardcoded `"/sw/*/etc/inputrc:"` C literal and `reading_sys_inputrc` guard in `bind.c`, and likewise in `bash`'s bundled `lib/readline/bind.c`). When `filename` contains no glob wildcards (`*?[`), try `_rl_read_init_file_single(filename, 1, include_level)` **first** so literal filenames containing `:` open directly, falling back to `glob(filename, GLOB_PATHS | GLOB_NOESCAPE, ...)` only when `filename` contains `*?[` or (`:` with `ENOENT` on the literal open), and skip `S_ISDIR` matches (`"."` from empty `:` segments).
- **Test Suite Recommendations**:
  - **Existing + Extended `CHECK()` in `sw/readline`**: Keep `sw/readline`'s `test_rl.c` harness asserting `rl_read_init_file("$td/sw/*/etc/inputrc:$td/etc/inputrc")` vendor-then-`/etc` override precedence, and extend it with assertions for a literal filename containing `:` (`"$td/my:inputrc"`) and leading/trailing empty `:` safety (`":$td/sw/*/etc/inputrc:"`).

#### 6. `python` (`sw/python`, `sw/python-pass1` — v3.14.7)
- **Current State** (`sw/Python-3.14.7-fluffy-source.patch`, `sw/Python-3.14.7-fluffy-test.patch`):
  - Exposes minimal `posix._glob(pathname)` (`GLOB_NOESCAPE | GLOB_KEEP_SLASHES`) and `_getpath.glob`; `Lib/glob.py` only fast-paths `glob.glob()` when `root_dir is None and dir_fd is None and not recursive and not include_hidden` and `isinstance(pathname, str)`.
  - Repeats 4 separate manual `:`-splitting + `glob` loops across `Lib/os.py` (`get_exec_path`), `Lib/shutil.py` (`which`), `Modules/getpath.py`, and `Lib/site.py` (using `any(c in p for c in '*?')`, which misses `[...]` character classes, and in `site.py` `glob.glob("/sw/*")` matches `/sw/*.squashfs` regular files as bogus prefixes!).
  - **Live Frozen-Module Bug**: `Modules/getpath.c` executes frozen bytecode from `Python/frozen_modules/getpath.h`. Because `sw/python` applies patches with `patch -Z -Np1`, `Modules/getpath.py` keeps the exact same `mtime` as `getpath.h`, so `make` skips `_freeze_module` (`test_getpath.py` passes by reading `getpath.py` from disk while `libpython3.14.so` runs unpatched `getpath.h`!).
- **Target Ideal State**:
  1. **Re-freeze `Modules/getpath.py` in `sw/python` & `sw/python-pass1`**:
     - Run `touch Modules/getpath.py` after `patch -Z -Np1` (or `make regen-frozen` during build) so `Programs/_freeze_module` regenerates `Python/frozen_modules/getpath.h` deterministically.
  2. **Upgrade `posix._glob(pattern, flags=0, root_dir=None)`**:
     - Accept both `str` (`PyUnicode_FSConverter` / `os.fsencode` `surrogateescape`) and `bytes`, plus `flags` (`GLOB_NOESCAPE`, `GLOB_KEEP_SLASHES`, `GLOB_PATHS`, `GLOB_ONLYDIR`, `GLOB_MARK`, `GLOB_GLOBSTAR`, `GLOB_PERIOD`, `GLOB_DOTDOT`, `GLOB_SKIPDOTS`, `GLOB_CASEFOLD`), while always firing both `sys.audit("glob.glob", pathname, recursive)` and `sys.audit("glob.glob/2", pathname, recursive, root_dir, dir_fd)` in `Lib/glob.py` prior to delegation (`test_glob` / `test_audit`).
     - When `root_dir is not None` (and `dir_fd is None` and `pathname` is relative), escape literal glob metacharacters (`[`, `*`, `?` → `[[]`, `[*]`, `[?]`) in `root_dir` before prefixing and strip the `root_dir` prefix on output (if `pathname` is absolute, ignore `root_dir` per Python semantics).
     - Only delegate `case_sensitive=False` to `GLOB_CASEFOLD` when ASCII-only or `LC_CTYPE` UTF-8 matches Python's `re.IGNORECASE` rules, and verify `**` / `**/` / `a/**` trailing-slash output parity with `Lib/glob.py` (keeping `dir_fd is not None` on pure Python).
  3. **Clean Up the 4 Path-List Consumers Respecting Exact Python Contracts**:
     - `Lib/os.py:get_exec_path()`: Expand wildcard segments (`*`, `?`, `[`) via `posix._glob(..., GLOB_NOESCAPE)` while **strictly preserving `''` empty segments** (`PATH=':/bin'` → `['', '/bin']`, `PATH=''` → `['']`, **not** `'.'`, which `test_os` and `shutil.which` distinguish!).
     - `Lib/shutil.py:which()`: Reuse `posix._glob` for wildcard segments (`str` and `bytes`, including `[...]`) while preserving `''` vs `'.'` return prefix formatting (`'cmd'` vs `'./cmd'`).
     - `Modules/getpath.py`: Expand wildcard `ENV_PATH` entries (`*`, `?`, `[`) via `_getpath.glob`.
     - `Lib/site.py`: Expand wildcard entries in `PREFIXES` (`"/sw/*"`) directly via `posix._glob(prefix, GLOB_ONLYDIR | GLOB_NOESCAPE)` (**never** `import glob` or `re`/`fnmatch` at interpreter startup so `test_site.test_startup_imports` passes cleanly, while pruning `/sw/*.squashfs` regular files and keeping candidate `<pkg>/lib/python3.14/site-packages` entries even when `site-packages` does not yet exist, as required by `test_site.test_getsitepackages_wildcard`).
- **Test Suite Recommendations**:
  - **Upstream Suite (`CHECK()`)**: `unset SOURCE_DATE_EPOCH && make test TESTOPTS="--timeout 120 ..."`, explicitly gating `test_glob`, `test_fnmatch`, `test_pathlib`, `test_site` (`test_startup_imports` & `test_getsitepackages_wildcard`), `test_getpath`, `test_os`, `test_shutil`, `test_subprocess`, `test_pyrepl`.
  - **Fluffy Regression Tests (`sw/Python-3.14.7-fluffy-test.patch`)**:
    1. Real subprocess test launching `argv[0] = "python3"` (bare name without `/`) via `executable="/sw/python/bin/python3"` with `ENV={"PATH": "/sw/*/bin"}` to verify **compiled frozen `getpath.h`** resolves `sys.executable == "/sw/python/bin/python3"`.
    2. `[...]` bracket wildcards and `''` vs `'.'` empty segments in `os.get_exec_path` and `shutil.which`, `root_dir` containing literal `[1]` metacharacters, `/sw/*.squashfs` exclusion in `site.getsitepackages`, and `bytes` + `recursive=True` + `include_hidden=True` parity.

#### 7. `perl` (`sw/perl`, `sw/perl-pass1` — v5.44.0)
- **Current State** (`sw/perl-5.44.0-fluffy-source.patch`):
  - Only patches hardcoded `/bin/sh` / `/usr` test/config references (29 lines). `ext/File-Glob/bsd_glob.c` still runs Perl's bundled 1,050-line BSD glob implementation (bypassing `glibc` `glob()` and `FSWC`), and `File::Spec::Unix::path()` (`dist/PathTools/lib/File/Spec/Unix.pm`) still does raw `split(':', $ENV{PATH})` without expanding `/sw/*/bin`.
- **Target Ideal State**:
  1. **Delegate `File::Glob` (`ext/File-Glob/bsd_glob.c`) to `glibc` `<glob.h>` with Exact CSH Semantics**:
     - Marshal between Perl's `bsd_glob` struct/flag namespace (`BG_*`, `gl_matchc`, `BG_stat_t`) and `glibc`'s `glob_t` / `GLOB_*`:
       - Map `BG_NOMAGIC` (used by `GLOB_CSH`) → **`GLOB_NOMAGIC`** (never `GLOB_NOCHECK`, so `<"/sw/*/missing">` returns `()` while `<"/sw/literal_missing">` returns `("/sw/literal_missing")`), `BG_BRACE` → `GLOB_BRACE`, `BG_TILDE` → `GLOB_TILDE`, `BG_MARK` → `GLOB_MARK`, `BG_NOSORT` → `GLOB_NOSORT`, `BG_NOESCAPE` → `GLOB_NOESCAPE`, `BG_NOCASE` → `GLOB_CASEFOLD`, `BG_ERR` → `GLOB_ERR`.
       - Preserve `BG_ALTNOT` bracket semantics (`[^...]` negates only when `BG_ALTNOT` is set; rewrite unnegated `[^...]` to `[\^...]` when `!(flags & BG_ALTNOT)` so `ext/File-Glob/t/basic.t` passes!).
       - Enforce `BG_LIMIT` (`rt114984.t`, `rt131211.t`) via brace-expansion fanout precheck + `GLOB_ALTDIRFUNC` / output cap returning `BG_NOSPACE` on pathological exponential inputs, and preserve `SvUTF8` flag propagation in `Glob.xs`.
  2. **Patch `File::Spec::Unix::path()` (`dist/PathTools/lib/File/Spec/Unix.pm`)**:
     - Expand wildcard `PATH` entries (`/[*?[]/`) while normalizing empty segments to `"."` (matching upstream `File::Spec::Unix::path` lines `s/^$/./`) and keeping a `miniperl`-safe pure-Perl `opendir`/`readdir` fallback before XS `File::Glob` is built.
  3. **Optional `@INC` / `PERL5LIB` Wildcard Support (`perl.c:S_incpush`)**:
     - Expand wildcard entries in `PERL5LIB` and vendor `@INC` (`/sw/*/lib/perl5/...`) via `glob(..., GLOB_PATHS | GLOB_ONLYDIR | GLOB_NOESCAPE, ...)`.
- **Test Suite Recommendations**:
  - **Upstream Suite (`CHECK()`)**: `TEST_JOBS=$(nproc) make test_harness`, specifically gating `ext/File-Glob/t/{basic,case,global,rt114984,rt131211,taint}.t`, `t/op/glob.t`, `dist/PathTools/t/Spec.t`, `cpan/IPC-Cmd/t/01_IPC-Cmd.t`, `cpan/ExtUtils-MakeMaker/t/*.t`.
  - **Fluffy Regression Tests (`sw/perl-5.44.0-fluffy-test.patch`)**:
    1. `File::Spec->path()` and `IPC::Cmd::can_run('bash')` with `local $ENV{PATH} = ':/sw/*/bin'` under both `miniperl -Ilib` and `perl`.
    2. `<"/sw/*/bin/perl">` → `('/sw/perl/bin/perl')`, `<"/sw/*/nonexistent">` → `()`, and `<"/sw/nonexistent_literal">` → `('/sw/nonexistent_literal')`.

#### 8. `tcl` (`sw/tcl` — v8.6.18)
- **Current State** (`sw/tcl8.6.18-fluffy-source.patch`, `sw/tcl8.6.18-fluffy-test.patch`):
  - `TclpFindExecutable` (`unix/tclUnixFile.c`) already uses `glob(p, GLOB_PATHS | GLOB_NOESCAPE, NULL, &g)`; `library/init.tcl` expands `/sw/*/lib` into `auto_path` and wildcards in `auto_execok`; `generic/tclFileName.c` adds `CanUseNativeMultiGlob` + `NativeMultiGlob`.
  - However, `TclFSIsPureNative()` disables native `glob()` process-wide whenever *any* secondary `Tcl_Filesystem` (`zipfs`, `simplefs:/`) is registered, and `CanUseNativeMultiGlob` rejects all `{a,b}` braces.
- **Target Ideal State**:
  1. **Drop `GLOB_MOUNTS` & Replace `TclFSIsPureNative()` with `TclFSPatternIsNative(pathPtr, pattern)` (~20 lines in `generic/tclIOUtil.c`)**:
     - Walk Tcl's registered `FilesystemRecord` list:
       - If only `tclNativeFilesystem` is registered, return `1` in $O(1)$.
       - If any registered non-native `Tcl_Filesystem` has `listVolumesProc == NULL` (an intercept-all wrapper like `testReportingFilesystem` in `tests/fileSystem.test`!), return `0` so VFS reporting/interception callbacks receive 100% of calls.
       - Otherwise (volume-scoped VFSes like `simplefs:/` or `//zipfs:/`), verify the resolved native prefix starts with `/` (not `//`) and shares no prefix overlap with any volume returned by `Tcl_FSListVolumes()`.
  2. **Enable Safe `{a,b}` `GLOB_BRACE` in `CanUseNativeMultiGlob`**:
     - Allow `{...}` **only** when braces are balanced, unnested, outside `[...]`, contain **at least one unescaped `,`**, and have non-empty alternatives none starting with `.` or `~` (because Tcl `DoGlob` strips zero-comma `{foo}` to `foo` whereas `glibc` `GLOB_BRACE` treats comma-less `{foo}` literally, unmatched `{` or empty `{}` must hit `DoGlob` to raise Tcl's `"unmatched open-brace in file name"` `TCL_ERROR`, and `{.foo,bar}` would interact with `NativeMultiGlob`'s hidden-dot filter).
     - Keep Tcl's post-glob `NativeMatchType` check when `types != NULL` (`-types d`, `-types f`, `-types l`, perms) because `glibc`'s `GLOB_ONLYDIR` is only a `d_type` hint that still emits symlinks-to-regular-files (`DT_LNK`) without `stat`ting them.
- **Test Suite Recommendations**:
  - **Upstream Suite (`CHECK()`)**: `LC_ALL=C.UTF-8 make test`, specifically gating `tests/fileName.test` (braces, unmatched `{` error, `-types d` on symlinks-to-files vs. symlinks-to-dirs, `-tails`, `-directory`, `-path`), `tests/fileSystem.test` (`simplefs:/` **and** `testReportingFilesystem`), `tests/fCmd.test`, `tests/exec.test`, `tests/init.test`.
  - **Fluffy Regression Tests (`sw/tcl8.6.18-fluffy-test.patch`)**:
    - Test `glob -nocomplain /sw/{bash,tcl}/bin/*` while `simplefs:/` is mounted, verify `catch {glob /sw/{unclosed}` still errors identically, and verify `auto_execok` with `env(PATH)=/sw/*/bin`.

---

### Group C: Build Systems, Command-Search Utilities & Test Frameworks

#### 9. `make` (`sw/make` — v4.4.1)
- **Current State** (`sw/make-4.4.1-fluffy-source.patch`; note `sw/make-pass1` builds unpatched upstream):
  - Expands wildcard `PATH` elements in gnulib's `lib/findprog-in.c` using a manual `:` loop calling `glob(dir, 0, NULL, &g)`, and contains hardcoded `"/sw/*/bin"` and `"/sw/bash/bin/{sh,bash}"` C strings in `src/job.c` and `src/main.c`.
- **Target Ideal State**:
  - Simplify `lib/findprog-in.c` onto `glob(path, GLOB_PATHS | GLOB_NOESCAPE | GLOB_NOCHECK, NULL, &g)` (guarded with `#ifdef GLOB_PATHS`, and omitting `GLOB_ONLYDIR` so non-directory or unreadable literal `PATH` entries still reach `eaccess()` and preserve POSIX `ENOTDIR`/`EACCES` `failure_errno`), and replace hardcoded `"/sw/..."` strings in `src/job.c` and `src/main.c` with `<paths.h>` (`_PATH_DEFPATH`, `_PATH_BSHELL`).
- **Test Suite Recommendations**:
  - **Upstream Suite (`CHECK()`)**: `make check` (`./tests/run_make_tests.pl`), specifically `features/exec`, `variables/SHELL`, `functions/wildcard`, and `features/parallelism`.
  - **Fluffy Regression Tests**: Keep and expand the `features/exec` test running `make` with `PATH=/sw/*/bin` and un-overridden `SHELL` (verifying `USE_POSIX_SPAWN` fast-path spawns both `bash` recipes and direct commands without `/bin/sh`).

#### 10. `coreutils` (`sw/coreutils` — v9.11)
- **Current State** (`sw/coreutils-9.11-fluffy-source.patch`; note `sw/coreutils-pass1` builds unpatched upstream):
  - Patches gnulib `lib/findprog-in.c` (used by `env`, `nohup`, `timeout`, `nice`, `stdbuf`, `chroot`) with a manual per-element `glob()` loop.
- **Target Ideal State**:
  - Share the exact same `#ifdef GLOB_PATHS`-guarded `GLOB_PATHS | GLOB_NOESCAPE | GLOB_NOCHECK` `lib/findprog-in.c` implementation as `make` (preserving `ENOTDIR`/`EACCES` → exit status `126` vs. `ENOENT` → exit status `127` in `tests/misc/env.sh`).
- **Test Suite Recommendations**:
  - **Upstream Suite (`CHECK()`)**: `unset SOURCE_DATE_EPOCH && make RUN_EXPENSIVE_TESTS=yes check < /dev/null`, specifically gating `tests/misc/env.sh`, `tests/misc/nohup.sh`, `tests/misc/timeout.sh`, `tests/misc/nice.sh`, and `tests/misc/chroot-*.sh`.
  - **Fluffy Regression Tests**: Verify `PATH=/sw/*/bin env true`, `PATH=:/sw/*/bin timeout 5 bash -c exit`, and exit code `126` on `PATH=/sw/bash/bin/bash env non_existent_cmd`.

#### 11. `which` (`sw/which` — v2.25)
- **Current State** (`sw/which-2.25-fluffy-source.patch`):
  - Implements a 75-line global static `active_glob` / `active_glob_idx` iterator inside `find_command_in_path` in `which.c`.
- **Target Ideal State**:
  - Replace the static `active_glob` state machine in `which.c` with a local pre-expanded path vector built per `PATH` element via `extract_colon_unit` + `glob(unit, GLOB_NOESCAPE, NULL, &g)` on wildcard elements (~20 lines, -55 LOC), preserving GNU `which`'s exact distinction between empty `:` (`""` → full CWD path under `--show-dot`) and explicit `.` (`"./..."` → dot-prefixed output under `--show-dot`) as well as `--show-tilde` (`tilde_expand`).
- **Test Suite Recommendations**:
  - **Upstream + Fluffy `CHECK()` (`sw/which`)**: `sw/which` currently runs minimal sanity checks; expand `CHECK()` to test:
    1. `PATH=/sw/*/bin ./which bash` → `/sw/bash/bin/bash`,
    2. `PATH=/sw/*/bin:/sw/*/bin ./which -a bash` (all-matches deduplication/ordering),
    3. `PATH=:/sw/*/bin ./which <local-exec-in-cwd>` (empty leading, middle `::`, and trailing `:` segments resolving `./<cmd>`),
    4. `PATH='/sw/[b]ash/bin' ./which bash` (bracket wildcard),
    5. Non-executable file skipped in favor of later executable match, and exit status `1` on missing command.

#### 12. `meson` (`sw/meson` — v1.12.0)
- **Current State** (`sw/meson-1.12.0-fluffy.patch`):
  - Uses `os.get_exec_path()` and `shutil.which()` for wildcard `PATH` resolution, `HAS_CFLAGS` / `HAS_LDFLAGS` system-library lookup, and missing-shebang script invocation rewrite.
- **Target Ideal State**:
  - Zero changes needed in `meson` for globbing once Python's `os.get_exec_path()` / `shutil.which()` run on `posix._glob` + `FSWC` v5 (automatically inherits faster tool discovery). Note `sw/libxcrypt` (`sw/libxcrypt-4.5.2-fluffy-test.patch`) similarly expands `path()` via Perl `glob($_)` and automatically inherits Perl's `<glob.h>` delegation.
- **Test Suite Recommendations**:
  - **Upstream + Fluffy Suite (`CHECK()`)**: `python3 -B -m unittest unittests/{internal,option,tap,version,cargo,data}tests.py` (matching `sw/meson` `CHECK()`, including `ExternalProgram` lookup under `PATH=/sw/*/bin`).

#### 13. `sqlite` (`sw/sqlite` — v3530400, `autosetup`)
- **Current State** (`sw/sqlite-3530400-fluffy.patch`; **note: `sw/sqlite` currently has no `CHECK()` function!**):
  - Patches `autosetup/autosetup` (`proc split-path`) to expand `[*?\[]` wildcard elements in `$PATH` via Tcl `glob -nocomplain -types d -- $part`.
- **Target Ideal State**:
  - Keep `proc split-path` patch (now accelerated by Tcl's `NativeMultiGlob` + `FSWC` v5) and add a `CHECK()` phase to `sw/sqlite`.
- **Test Suite Recommendations**:
  - **New `CHECK()` for `sw/sqlite`**:
    1. Verify `autosetup`'s `cc-check-progs` resolves tools (`cc`, `ar`, `strip`) when `PATH=/sw/*/bin` and `CROSS=""`.
    2. Run SQLite CLI smoke & FTS4/FTS5/JSON regression queries (`./sqlite3 :memory: "CREATE VIRTUAL TABLE t USING fts5(x); INSERT INTO t VALUES ('fluffy glob'); SELECT * FROM t WHERE t MATCH 'fluffy';"` — note full `make test` requires the separate Fossil tree rather than `sqlite-autoconf` amalgamation tarball).

#### 14. `dejagnu` (`sw/dejagnu` — v1.6.3) & `expect` (`sw/expect` — v5.45.4)
- **Current State** (`sw/dejagnu-1.6.3-fluffy-source.patch`, `sw/expect5.45.4-fluffy-source.patch`):
  - `dejagnu`: `proc which` in `lib/utils.exp` expands wildcard `$PATH` directories via Tcl `glob -nocomplain -types d -- $dir`.
  - `expect`: TEA `configure` discovers `tclConfig.sh` and `tcl.h` across `/sw/*/lib` and `/sw/*/include` and sets `STTY_BIN=stty` via `PATH`.
- **Target Ideal State**:
  - Keep both minimal patches; `dejagnu`'s `glob -types d` and `expect`'s `exec stty` both automatically accelerate via Tcl `NativeMultiGlob` + `execvp` `FSWC` v5.
- **Test Suite Recommendations**:
  - **`dejagnu` `CHECK()`**: `make check` (`launcher`, `libdejagnu`, `report-card`, `runtest.exp`) + test `which gcc` inside `runtest` with `PATH=/sw/*/bin`.
  - **`expect` `CHECK()`**: `make test` (`all.tcl`: `cat.test`, `expect.test`, `logfile.test`, `pid.test`, `send.test`, `spawn.test`, `stty.test`).

---

### Group D: Stateless-`/etc`, Crypto Trust Store & System Daemons/Utilities

#### 15. `systemd` (`sw/systemd` — v261.2)
- **Current State** (`sw/systemd-261.2-fluffy-source.patch`):
  - Expands `/sw/*/lib/systemd/{system,user,network,...}` and `/sw/*/etc/...` across `sd-path/path-lookup.c`, `basic/conf-files.c`, `shared/conf-parser.c`, `basic/os-util.c`, `basic/path-util.c`, `shared/condition.c`, and `core/load-fragment.c` via `safe_glob()` / `glob_extend()`, keeping `/etc/systemd/system` at highest precedence and setting `99-default.preset` to `disable *`.
  - **Hidden Cache-Bypass Trap**: Upstream `systemd`'s `safe_glob_full()` (`src/basic/glob-util.c`) unconditionally passes `GLOB_ALTDIRFUNC` with `readdir_no_dot` solely because standard `<glob.h>` lacked `GLOB_SKIPDOTS`—which would force 100% of `systemd`'s `safe_glob()` and `glob_extend()` calls to bypass `FSWC` v5!
- **Target Ideal State**:
  - Patch `src/basic/glob-util.c:safe_glob_full` (~4 lines) so when `opendir_func == NULL`, it calls `glob(path, flags | GLOB_SKIPDOTS, NULL, &g)` **without** `GLOB_ALTDIRFUNC` (keeping `GLOB_ALTDIRFUNC` only when a caller supplies a custom `opendir_func`), unlocking full `FSWC` v5 shared-memory acceleration across PID 1 unit/generator discovery, `conf-files.c`, `conf-parser.c`, `os-util.c`, `path-util.c`, and `condition.c`!
  - Move `"/sw/..."` vendor strings (`constants.h`, `path-util.h`, `path-lookup.c`, `os-util.c`, `hwdb-util.c`, `namespace.c`) behind a Meson `-D` prefix macro, while **never** flattening `basic/conf-files.c`'s basename-deduplicating merge (where `50-foo.conf` in `/etc` masks `/sw/<pkg>/lib/.../50-foo.conf` before sorting basenames across all directories).
- **Test Suite Recommendations**:
  - **Upstream + Fluffy Suite (`CHECK()`)**: `meson test -C build --print-errorlogs`, specifically gating the 5 Fluffy-patched unit tests: `test-path-util`, `test-path-lookup`, `test-condition`, `test-conf-files`, and `test-conf-parser` (verifying `/etc` overrides `/sw/<pkg>/etc` and `/sw/<pkg>/lib`, basename masking across directories, `.wants/` symlinks across `/sw/*/lib/systemd/system`, and `ConditionPathExistsGlob=` over `/sw/*`).

#### 16. `kmod` (`sw/kmod` — v34.2)
- **Current State** (`sw/kmod-34.2-fluffy.patch`, `sw/kmod-34.2-fluffy-test.patch`):
  - Patches `libkmod/libkmod-config.c` and `tools/depmod.c` to expand `/sw/*/{etc,lib}/{modprobe,depmod}.d` via `glob(path, GLOB_ALTDIRFUNC, ...)` unconditionally (so `kmod`'s `LD_PRELOAD` `testsuite/path.so` intercepts `opendir`/`stat` during `meson test`, at the cost of forcing production `modprobe`/`depmod` to bypass `FSWC`!), and hardcodes `"/sw/*/{etc,lib}/modprobe.d"` in `libkmod/libkmod.c`.
- **Target Ideal State**:
  - Call standard `glob(path, GLOB_ONLYDIR, NULL, &gl)` in `libkmod/libkmod-config.c` and `tools/depmod.c` so production `modprobe`/`depmod` get full `FSWC` v5 acceleration, add a ~15-line `glob`/`glob64` `ROOTFS`-prefix wrapper to `testsuite/path.c` (`LD_PRELOAD` test-only shim), and pass vendor config directories via Meson `-DCFLAGS` defines rather than C `"/sw"` literals (while still preserving `FSWC` v5's `GLOB_ALTDIRFUNC` bypass for genuine callback callers).
- **Test Suite Recommendations**:
  - **Upstream + Fluffy Suite (`CHECK()`)**: `meson test -C build` (all 16/16 suites, specifically `test-blacklist` [`blacklist_fluffy_glob`] and `test-depmod` [`depmod_search_order_fluffy_sw`]).

#### 17. `dbus` (`sw/dbus` — v1.16.2)
- **Current State** (`sw/dbus-1.16.2-fluffy-source.patch`):
  - Expands `<include>` / `<includedir>` and `/sw/*/share/dbus-1/{system,session}.d` + `/sw/*/share/dbus-1/{system-services,services}` via `glob(..., 0, ...)` in `bus/config-parser.c` and `_dbus_split_glob_paths_and_append` in `dbus/dbus-sysdeps-util-unix.c` (currently contains hardcoded `"/sw/"` strings in `dbus-sysdeps-util-unix.c`).
- **Target Ideal State**:
  - Keep `_dbus_split_paths_and_append(dirs, suffix, &raw_dirs)` first in `dbus-sysdeps-util-unix.c` (because the XDG Base Directory Specification requires ignoring empty `:` segments in `XDG_DATA_DIRS`—never mapping `""` to `"."`—and `suffix` `"/dbus-1/services"` must be appended to each segment prior to globbing), pass `GLOB_ONLYDIR | GLOB_NOESCAPE` to the post-suffix `glob()` calls in `dbus-sysdeps-util-unix.c` and `<includedir>`/<servicedir>` in `bus/config-parser.c`, and move Fluffy default search paths into Meson `-DDBUS_SYSTEM_CONFIG_DIRS` / build configuration rather than C literals.
- **Test Suite Recommendations**:
  - **Upstream + Fluffy Suite (`CHECK()`)**: `meson test -C build` (including the dedicated Fluffy test `test/internals/fluffy-config.c` verifying multi-package `/sw/<pkg>/share/dbus-1` service & policy merging, empty `XDG_DATA_DIRS` segment skipping, and `/etc/dbus-1` precedence).

#### 18. `util-linux` (`sw/util-linux` — v2.42.2)
- **Current State** (`sw/util-linux-2.42.2-fluffy-source.patch`; note `sw/util-linux-pass1` builds unpatched upstream):
  - Uses `GLOB_PATHS | GLOB_NOCHECK` in `disk-utils/fsck.c` (`fsck_path`), `libmount/src/context.c` (`search_path`), and `lib/configs.c` (`ul_configs_file_list`), plus `glob()` in `lib/logindefs.c` (`"/sw/*/etc/login.defs"`) and a 2-pattern `glob()` loop in `term-utils/agetty.c` (`"/sw/*/etc/os-release"`, `"/sw/*/lib/os-release"`). Note that in `lib/configs.c`, passing `GLOB_PATHS` on `usrdir` maps accidental empty `:` segments (`":/sw/*/etc"`) to `"."` (CWD).
- **Target Ideal State**:
  - Pass `GLOB_NOESCAPE` alongside `GLOB_PATHS` across `fsck.c`, `context.c`, `configs.c`, `logindefs.c`, and `agetty.c` (collapsing `agetty.c`'s 2-element loop onto a single `GLOB_PATHS | GLOB_NOESCAPE` call), skip empty-segment `"."` in `lib/configs.c` unless `"."` was explicitly present in `usrdir` so `ul_configs` never loads config drop-ins from CWD, and move default vendor search paths (`lib/configs.c`, `lib/logindefs.c`, `agetty.c`, `include/pathnames.h`) into configure/`CPPFLAGS` macros (zero `"/sw"` C literals).
- **Test Suite Recommendations**:
  - **Existing + Extended `CHECK()` in `sw/util-linux`**: Keep `sw/util-linux`'s `test_pathnames`, `fsck -T -N`, and `test_configs` (`--etc` / `--usr` precedence) assertions, add a CWD-isolation check (`--usr ":/tmp/fluffy-ulcfg/sw/*/etc"` ignoring `./issue` in CWD), and run non-root `tests/run.sh` unit tests (`login/logindefs`, `libmount/*`).

#### 19. `shadow` (`sw/shadow` — v4.20.2)
- **Current State** (`sw/shadow-4.20.2-fluffy-source.patch`, plus multi-step `chpasswd`/`useradd`/`usermod` `-P` `CHECK()` in `sw/shadow`):
  - Globs vendor files across 4 files—`VENDOR_LOGINDEFS` (`"/sw/*/etc/login.defs"`) in `lib/getdef.c`, `VENDOR_GROUP_FILES` (`"/sw/*/etc/group"`) in `lib/groupio.c`, `VENDOR_PASSWD_FILES` (`"/sw/*/etc/passwd"`) in `lib/pwio.c`, and `vendor_{passwd,group}_glob` (`"%s/sw/*/etc/{passwd,group}"`) in `lib/prefix_flag.c`—plus sets `PATH=/sw/*/bin` in `lib/setupenv.c` and implements CoW initialization for `/etc/passwd`, `/etc/group`, and `/etc/shadow`.
- **Target Ideal State**:
  - Pass `VENDOR_LOGINDEFS`, `VENDOR_GROUP_FILES`, and `VENDOR_PASSWD_FILES` via `sw/shadow` `CPPFLAGS` and use `<paths.h>` `_PATH_DEFPATH` in `lib/setupenv.c` so zero `"/sw"` literals remain in C source; escape `*?[` glob metacharacters in the `--root` / `--prefix` `<pfx>` string before appending `VENDOR_*` and call `glob(pat, GLOB_NOESCAPE, NULL, &gl)` across all 4 files (`getdef.c`, `groupio.c`, `pwio.c`, `prefix_flag.c`) while keeping `def_load_file(def_fname)` literal (so `:` or `[1]` inside `--prefix <pfx>` never splits or misfires).
- **Test Suite Recommendations**:
  - **Existing + Extended `CHECK()` in `sw/shadow`**: Keep `sw/shadow`'s `chpasswd` / `useradd` / `usermod` `-P "$pfx"` CoW and `login.defs` override suite, and run it against a temp directory path containing `:` and `[1]` (e.g. `mktemp -d /tmp/shd_test_[1]:XXXXXX`) to verify prefix metacharacter safety across `getdef.c`, `groupio.c`, `pwio.c`, and `prefix_flag.c`.

#### 20. `e2fsprogs` (`sw/e2fsprogs` — v1.47.4)
- **Current State** (`sw/e2fsprogs-1.47.4-fluffy-source.patch`, plus `test_profile` `CHECK()` in `sw/e2fsprogs`):
  - Uses `glob(*fs, GLOB_PATHS, ...)` in `lib/support/profile.c` (`profile_init`), with `{"/etc/mke2fs.conf", "/sw/*/etc/mke2fs.conf", ...}` in `misc/mke2fs.c` and `e2fsck/unix.c` listed `/etc` **before** `/sw/*/etc` because `libprofile` uses **first-seen-wins** key semantics.
- **Target Ideal State**:
  - Change `glob(*fs, GLOB_PATHS, ...)` in `lib/support/profile.c:profile_init` to `glob(*fs, GLOB_NOESCAPE, ...)` (`profile_init_path` already splits colon-delimited path lists into `files[]`; passing `GLOB_PATHS` on single `files[]` elements like `MKE2FS_CONFIG` turns empty `:` segments into `"."`, causing `get_dirlist(".")` to parse every file in CWD as `mke2fs.conf`!), pass vendor config paths via configure/`CPPFLAGS` defines rather than C `"/sw/*/etc/..."` literals, and strictly preserve `libprofile`'s `/etc` → `/sw/*/etc` first-seen-wins ordering.
- **Test Suite Recommendations**:
  - **Existing + Extended `CHECK()` in `sw/e2fsprogs`**: Keep `sw/e2fsprogs`'s `test_profile` `/etc`-over-`/sw/*` assertions, add an empty-`:` CWD-isolation assertion (`test_profile ":$td/sw/*/etc/mke2fs.conf"` in a directory containing a decoy file), and run `make -C build check` (`m_*` `mke2fs` profile tests).

#### 21. `man-db` (`sw/man-db` — v2.13.1) & `groff` (`sw/groff` — v1.24.1)
- **Current State** (`sw/man-db-2.13.1-fluffy-source.patch`, `sw/groff-1.24.1-fluffy-source.patch`):
  - `man-db`: Uses `GLOB_PATHS | GLOB_NOESCAPE` in `lib/pathsearch.c` (`pathsearch` and `directory_on_path`) and `src/manp.c` (`"/sw/*/etc/man_db.conf:/etc/man_db.conf"`). Note `directory_on_path(dir)` compares `STREQ(gl.gl_pathv[i], dir)` against an absolute `dir`, which currently misses `"."` emitted by `GLOB_PATHS` for empty `:` segments (`xgetcwd()` needed) and drops non-existent literal `PATH` entries without `GLOB_NOCHECK`.
  - `groff`: Uses `GLOB_PATHS | GLOB_NOESCAPE` in `src/libs/libgroff/relocate.cpp` (`searchpath`) for executable/prefix relocation.
- **Target Ideal State**:
  - In `man-db`, pass `GLOB_PATHS | GLOB_NOESCAPE | GLOB_NOCHECK` in `directory_on_path()` while resolving `"."` via `xgetcwd()` before `STREQ`, and move `"/sw/*/etc/man_db.conf"` in `src/manp.c` into a `CPPFLAGS` macro. `FSWC` v5 newly indexes `share/man` and `share/groff`, making `man <page>` instant without `mandb` cache regeneration.
- **Test Suite Recommendations**:
  - **`man-db` `CHECK()`**: `make check` + `MANPATH=/sw/*/share/man ./src/man -w ls` verifying late-bound manpage resolution across mounted packages.
  - **`groff` `CHECK()`**: `make check` (all ~190 `tmac`/`roff`/`preproc` tests).

#### 22. `iproute2` (`sw/iproute2` — v7.1.0)
- **Current State** (`sw/iproute2-7.1.0-fluffy-source.patch`; `sw/iproute2` `CHECK()` currently only runs `./ip/ip -V`!):
  - Uses `GLOB_PATHS | GLOB_NOESCAPE` across `lib/rt_names.c`, `lib/bpf_legacy.c`, `tc/tc_util.c`, `tc/m_ematch.c`, and `tc/e_bpf.c` to resolve `/sw/*/etc/iproute2:...:/etc/iproute2` (`rt_tables`, `rt_protos`, `rt_scopes`, `ematch_map`, `group`).
- **Target Ideal State**:
  - Pass `-DCONF_VENDOR_DIR='"/sw/*/etc/iproute2"'` via build `CFLAGS` (removing hardcoded `"/sw/*/etc/iproute2"` C literals across `lib/*.c` and `tc/*.c`), and upgrade `CHECK()` in `sw/iproute2` beyond `-V` so patched `rt_names.c` and `tc` config paths are actually exercised!
- **Test Suite Recommendations**:
  - **Upgraded `CHECK()` for `sw/iproute2`**: Test `ip` / `tc` table-name resolution (`rtnl_rttable_n2a(255, ...)` → `"local"`) against vendor `etc/iproute2/rt_tables` when `/etc/iproute2` is absent, and verify `/etc/iproute2` override precedence without requiring `CAP_NET_ADMIN`.

#### 23. `openssl` (`sw/openssl`, `sw/openssl-pass1` — v4.0.1) & `curl` (`sw/curl`, `sw/curl-pass1` — v8.23.0)
- **Current State** (`sw/openssl-4.0.1-fluffy-source.patch`, `sw/curl-8.23.0-fluffy-source.patch`):
  - `openssl`: Expands wildcards in `X509_LOOKUP_file` (`crypto/x509/by_file.c`, currently only on `X509_FILETYPE_DEFAULT` `SSL_CERT_FILE`, missing explicit `-CAfile` `X509_FILETYPE_PEM` loads!) and `X509_LOOKUP_hash_dir` (`crypto/x509/by_dir.c`) for `--openssldir=/etc/ssl` / `/sw/*/etc/ssl/certs/ca-certificates.crt` and `/sw/*/etc/ssl/certs`.
  - `curl`: Expands `ssl_cafile` and `ssl_capath` via `glob()` in `lib/vtls/openssl.c` (`ossl_load_trust_anchors`).
- **Target Ideal State**:
  - In `openssl` `crypto/x509/by_dir.c` (`add_cert_dir`), **preserve upstream's `if (len == 0) continue;` empty-segment skip** (**never** use `GLOB_PATHS` on `SSL_CERT_DIR`, which would map empty `:` segments to `"."` and inject CWD into the X.509 root CA trust store!) while passing `GLOB_NOESCAPE | GLOB_ONLYDIR` on non-empty wildcard segments; and extend `crypto/x509/by_file.c` (`by_file_ctrl`) so explicit `X509_FILETYPE_PEM` (`-CAfile` / `X509_STORE_load_file`) wildcard paths expand with `GLOB_NOESCAPE` just like `X509_FILETYPE_DEFAULT`.
  - Once `libcrypto`'s `X509_STORE_load_file` and `X509_STORE_load_path` handle wildcards directly in `by_file.c` / `by_dir.c` (in both `openssl-pass1` and `openssl`), delete the redundant 65-line `glob()` wrapper in `curl`'s `lib/vtls/openssl.c` (`-65 LOC`, preserving `curl`'s clear error reporting when zero files match). `FSWC` v5 newly indexes `etc/ssl/certs/*`.
- **Test Suite Recommendations**:
  - **`openssl` `CHECK()`**: `HARNESS_JOBS=$(nproc) make test` + explicit `openssl verify -CApath ':/sw/*/etc/ssl/certs:/etc/ssl/certs'` (verifying leading empty `:` does **not** load untrusted certs from CWD!) and `-CAfile '/sw/*/etc/ssl/certs/ca-certificates.crt'` test against `/sw/ca-certificates`'s root bundle.
  - **`curl` `CHECK()`**: `make test` (`TFLAGS="-j$(nproc)"` non-flaky HTTP/TLS unit & server tests) + TLS verification smoke check via wildcard `--cacert '/sw/*/etc/ssl/certs/ca-certificates.crt'`.

#### 24. *Recommended New `GLOB_PATHS` Consumer*: `ncurses` (`sw/ncurses`, `sw/ncurses-pass1` — v6.6)
- **Current Gap**:
  - Python's `Lib/_pyrepl/terminfo.py` globs `/sw/*/share/terminfo`, but `sw/ncurses` is configured without `--with-terminfo-dirs`, so `libncursesw.so` only checks `/etc/terminfo` and `/sw/ncurses/share/terminfo`—missing third-party terminal definitions (`foot`, `kitty`, `alacritty`, `tmux`) mounted at `/sw/<pkg>/share/terminfo`.
- **Target Ideal State**:
  - Configure `sw/ncurses` with `--with-terminfo-dirs="/etc/terminfo:/sw/*/share/terminfo"` and add a ~15-line `glob(..., GLOB_PATHS | GLOB_NOESCAPE | GLOB_ONLYDIR, ...)` expansion in `ncurses/tinfo/db_iterator.c` (`_nc_next_db`), guarded with `#ifdef GLOB_PATHS` so `ncurses-pass1` (if sharing the patch on a host build) compiles cleanly on any host `<glob.h>`.
- **Test Suite Recommendations**:
  - **New `CHECK()` for `sw/ncurses`**: Run `./progs/infocmp xterm-256color >/dev/null` and test `TERMINFO_DIRS="/tmp/nc_etc:/tmp/nc_sw/*/share/terminfo" ./progs/infocmp custom-fluffy-term` against a compiled `tic` fixture under `/tmp/nc_sw/pkgA/share/terminfo`, asserting both vendor discovery and `/etc/terminfo` override precedence.

---

## 6. Phased Implementation Plan & Execution Gates

When executing this plan, follow these stages in strict order.
- **Workflow rules**: Never run `sudo` directly from the agent (provide `sudo --preserve-env=FLUFFY,CROSS ./swctl build <pkg>` or `sudo --preserve-env=FLUFFY ./swctl build <pkg>` commands), always apply patches with `patch -Z -Np1`, and keep recipe `*_NEEDS` arrays alphabetically sorted, 4-space indented, with a blank line between `NEEDS` and `BUILD_NEEDS`.
- **Companion Bootstrap Recipe Checksum & Host-Build Rule**: Whenever a shared `*-fluffy-*.patch` file changes, update its SHA-256 checksum in **every** recipe that references it in `ARCHIVES=(...)` (`sw/glibc` + `sw/glibc-pass1`; `sw/binutils` + `sw/binutils-pass{1,2}`; `sw/gcc` + `sw/gcc-pass{1,2}`; `sw/bash` + `sw/bash-pass1`; `sw/python` + `sw/python-pass1`; `sw/perl` + `sw/perl-pass1`; `sw/openssl` + `sw/openssl-pass1`; `sw/curl` + `sw/curl-pass1`; plus `sw/ncurses` + `sw/ncurses-pass1` if sharing the terminfo patch). Patches compiled natively on the bootstrap host (`binutils-pass1`, `gcc-pass1`, and `ncurses-pass1`'s host `tic` tool) **must** either stick to standard `<glob.h>` flags (`0`, `GLOB_ONLYDIR`) or guard Fluffy-specific macros with `#ifdef GLOB_PATHS` so bootstrap builds cleanly on any unpatched Linux host `<glob.h>`.

### Phase 0: Baseline Benchmark Harness (`bench-fswc`)
1. Build a standalone C benchmark binary (`bench-fswc`) measuring:
   - Tier 0 (cold `/dev/shm`), Tier 1 (cold mount namespace with warm `pkg_*`), Tier 2 (cross-process `posix_spawnp` / `execvp` $\times 1{,}000$), and Tier 3 (warm in-process `glob`, `openat`, `statx` latencies + `/proc/self/smaps_rollup` `Private_Dirty` KiB).
   - Micro/macro workloads: `/sw/*/bin/bash`, `/sw/*/bin/missing`, `/sw/*/{bin,include,lib}` (`GLOB_ONLYDIR`), `/sw/*/lib/python3.14/site-packages/*`, `/sw/*/share/terminfo/*/*`, 52-dir `-I` $\times$ 200 `#include` burst, and real `g++` `<iostream>` compile+link.
2. Record baseline metrics on the current `FSWC` v4 91-package Chapter 8 `/sw` tree.

### Phase 1: `FSWC` v5 Engine & `GLIBC_TUNABLES` in `glibc` (+ `sw/glibc-pass1`)
1. Implement `include/fswc.h`, `sysdeps/unix/sysv/linux/fswc.c`, writable `_rtld_global` (`GL`) slot table (`dl-support.c` for `libc.a`), and `elf/dl-tunables.list` (`glibc.fswc.mode=0|1|2`, `glibc.fswc.max_inodes`).
2. Delete `posix/glob_fluffy_cache.h`, `fc_glob_try`, and `glob_literal_suffix_try`; wire `fswc_match_pkg_wild_relpath` (`dl-load.c` keeping `rtld_search_dirs`, `execvpe.c` keeping `ENOEXEC` `scripts_argv`), `fswc_glob_walk` (`posix/glob.c`), and `fswc_probe_exact` (`mode=2` read-only VFS wrappers + stateful `..` + mount/cred invalidation hooks).
3. Add Tier-1 `make check` tests (`tst-glob-fluffy-flags`, `tst-fswc-oracle`, `tst-fswc-edge`, `tst-fswc-concurrency`, `tst-fswc-vfork`, `tst-fswc-static`) to `sw/glibc-2.44-fluffy-test.patch`, sync SHA-256 in `sw/glibc` and `sw/glibc-pass1`, and build Tier-2 `test-fswc`.
4. **Gate 1**:
   - `glibc` builds and passes 100% of `make check` (`CHECK()`).
   - `test-fswc` passes 100% of pathological SquashFS (`ncursesw -> .` dir symlinks, `*.squashfs` sibling files, mutable sibling dirs, `0111`/`0700`/ACL dirs), live mount/unmount/overmount, chroot loop-churn, and UID/`setfsuid`-drop differential checks across `mode={0,1,2}`.
   - `bench-fswc` confirms `Private_Dirty == 0 KiB` on `/dev/shm/.fswc-<uid>/blob_*`, `< 5 µs` bailout on non-SquashFS `/tmp/*` sharing root `/`, and faster deep-path (`site-packages`, `terminfo`, `systemd`) queries than v4.

### Phase 2: Strip Leaked Cache Headers from `binutils` & `gcc` (-6,700+ LOC)
1. Strip `include/fluffy-cache.h` and all `fc_*` hooks from `sw/binutils-2.47-fluffy-source.patch` and `sw/gcc-16.2.0-fluffy-source.patch` (restoring `libcpp/files.cc` to unmodified upstream, making `ldfile_add_library_path`, `add_path`, `add_prefix`, and `do_add_prefix` non-recursive on matched `gl_pathv` entries, and syncing SHA-256 across `binutils-pass{1,2}` and `gcc-pass{1,2}`).
2. **Gate 2**:
   - Rebuild `binutils` and `gcc`; pass full DejaGnu `CHECK()` suites (`binutils`, `gas`, `ld`, `libctf`, `libsframe`, `gcc`, `g++`, `libstdc++`).
   - Run [`check-toolchain`](check-toolchain) (including `<ncursesw/curses.h>` and `#include_next <stdlib.h>`) and `bench-fswc` `g++` + `ld` macrobenchmark across `glibc.fswc.mode={0,1,2}`, verifying `mode=2` matches or beats inline `fluffy-cache.h` wall time with zero leaked cache LOC.

### Phase 3: Language Runtime Glob Unification (`python`, `perl`, `tcl`)
1. **`python` (+ `python-pass1`)**: Re-freeze `Modules/getpath.py`, upgrade `posix._glob` (`str|bytes`, all flags, escaped `root_dir`), clean up `os.py`, `shutil.py`, `getpath.py`, and `site.py` (`GLOB_ONLYDIR` prefix expansion), and expand `sw/Python-3.14.7-fluffy-test.patch`.
2. **`perl` (+ `perl-pass1`)**: Delegate `ext/File-Glob/bsd_glob.c` to `<glob.h>` (`GLOB_NOMAGIC`, `BG_ALTNOT`, `BG_LIMIT`, `SvUTF8`), patch `File::Spec::Unix::path()` (`miniperl`-safe), optionally wire `@INC`/`PERL5LIB` `GLOB_PATHS`, and add tests to `sw/perl-5.44.0-fluffy-test.patch`.
3. **`tcl`**: Replace `TclFSIsPureNative()` with `TclFSPatternIsNative()` (honoring `listVolumesProc == NULL` interceptors), enable balanced `{a,b}` `GLOB_BRACE` in `CanUseNativeMultiGlob` (preserving `NativeMatchType`), and expand `sw/tcl8.6.18-fluffy-test.patch`.
4. **Gate 3**:
   - Full `CHECK()` suites pass 100% in `python` (`test_glob`, `test_site`, `test_os`, `test_shutil`, `test_getpath` + frozen subprocess test), `perl` (`make test_harness`), and `tcl` (`make test` including `fileSystem.test`).

### Phase 4: CLI & System `GLOB_PATHS` Consolidation, C-Literal Cleanup & `CHECK()` Gap Closure
1. Simplify `which` (`which.c`, preserving `--show-dot` / `--show-tilde`), `make` & `coreutils` (`lib/findprog-in.c` with `GLOB_PATHS | GLOB_NOESCAPE | GLOB_NOCHECK`), `systemd` (`src/basic/glob-util.c` `GLOB_SKIPDOTS` when `opendir_func == NULL` instead of `GLOB_ALTDIRFUNC`), `kmod` (`libkmod-config.c` + `testsuite/path.c` `glob` wrapper), `dbus` (`GLOB_ONLYDIR | GLOB_NOESCAPE` post-suffix), `readline` (`-DSYS_INPUTRC`, literal-first open before `GLOB_PATHS`, `S_ISDIR` skip), `man-db` (`directory_on_path` `"."` `xgetcwd` + `GLOB_NOCHECK`), `util-linux` (`GLOB_NOESCAPE` + `lib/configs.c` empty-`:` `"."` skip + `agetty.c` `GLOB_PATHS`), `shadow` (`getdef.c`/`groupio.c`/`pwio.c`/`prefix_flag.c` prefix metacharacter escaping + `GLOB_NOESCAPE`), `e2fsprogs` (`profile.c` `GLOB_NOESCAPE` fixing CWD `get_dirlist(".")`), and `openssl` (+ `openssl-pass1`) / `curl` (+ `curl-pass1`) (`by_dir.c` empty-segment skip + `by_file.c` explicit `-CAfile` globbing + removing `curl` `openssl.c` wrapper); add `GLOB_PATHS` `TERMINFO_DIRS` support to `ncurses`; move remaining C `"/sw/..."` default literals (`bash`, `readline`, `make`, `kmod`, `dbus`, `man-db`, `util-linux`, `shadow`, `e2fsprogs`, `iproute2`, `systemd`) into build/config macros (`paths.h` / `CFLAGS` / Meson `-D`).
2. Add missing `CHECK()` blocks to `sw/ncurses` and `sw/sqlite`, upgrade `sw/iproute2` and `sw/which` `CHECK()` suites, and extend existing `CHECK()` assertions in `sw/readline`, `sw/shadow`, `sw/util-linux`, and `sw/e2fsprogs`.
3. **Gate 4**:
   - Every package modified from upstream source has an automated `CHECK()` test exercising its Fluffy wildcard/stateless-`/etc` code paths and passes cleanly.

### Phase 5: End-to-End `world` Convergence & Final Audit
1. Run `sudo --preserve-env=FLUFFY ./swctl build world` (and verify `CROSS=1` checksum consistency), confirming `git grep fluf''fy-cache -- sw/` returns 0 hits, zero C logic files hardcode `"/sw"`, and all `world` `CHECK()` suites pass.
