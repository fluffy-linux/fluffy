# Fluffy Packaging & System Architecture Notes

## Core Design Principles

1. **Per-Package Squashfs Images (`/sw/<pkg>`)**
   - Every package builds and installs into `/sw/<pkg>` (e.g. `/sw/man-pages`, `/sw/zlib`), which is packaged as `sw/<name>-<version>.squashfs` with `-all-root -comp zstd`.
   - At runtime and build time, the squashfs image is mounted at its unversioned mountpoint `/sw/<pkg>`.
   - Upgrading a package means mounting a newer `.squashfs` at `/sw/<pkg>` in the new mount namespace—no RPATH or path rewriting needed.
   - **Why SquashFS? (The Architectural & Security Rationale)**:
     - **Installation Almost *Isn't***: There is no file extraction, tar unpacking, or payload copying. Installing a package is literally a single kernel `mount` syscall ($O(1)$ time complexity).
     - **Inherently Read-Only by Design**: The underlying filesystem format is immutable. Even the `root` user cannot accidentally clobber, mutate, trojan, or delete files inside `/sw/*`.
     - **Cryptographically Verifiable Forever, Even After Installation**: Because the package is mounted directly from its signed `.squashfs` image rather than extracted into loose files, verifying the package's integrity across its entire lifecycle on the machine is as trivial as checking the image's hash or signature in `/sw/.build/fstab`. There is zero file-level bit rot or stealth file tampering.
     - **Clear Security Boundary**: Only `root` can mount anything into `/sw/`. The system attack surface is exceptionally easy to reason about and audit.
     - **Self-Documenting File Ownership**: The pathname `/sw/<pkg>/...` directly and unambiguously identifies which package owns every binary, library, header, and asset on the system with zero database queries (`dpkg -S`, `rpm -qf`).
     - **Transparent Deduplication & Compression**: Zstandard compression at rest with shared page cache entries across all processes, containers, and namespaces on the host.

2. **Immutable Mount Namespaces (Zero Torn Installs, Zero-Logout Desktop UX)**
   - Running processes keep their existing mount namespace (`CLONE_NEWNS`) across package installs/upgrades.
   - Installing or upgrading a package updates the canonical system mount namespace (`/proc/1/ns/mnt`).
   - A running process can never experience a torn upgrade (e.g. halfway through loading shared libraries or reading data files while files change underneath).
   - **Desktop / Interactive UX**: Users do *not* need to log out to use newly installed or upgraded software. Opening a new shell/terminal tab or launching an application enters `/proc/1/ns/mnt` (`setns`), immediately forks a fresh private mount namespace (`unshare(CLONE_NEWNS)`) with `MS_PRIVATE`, and execs the shell/app—so new shells and newly launched apps see the new environment immediately while already-running apps continue uninterrupted until restarted.
   - Old `.squashfs` mounts stay alive in existing namespaces until the last process using them exits.
   - **New Installs vs. Package Upgrades**:
     - **Fresh Package Installs (Additions)**: Do *not* require a new mount namespace. Mounting a brand-new package at `/sw/<pkg>` carries zero risk of torn state since no active process was running against it. Combined with the shared CoW index below, newly installed commands become available immediately in existing shells.
     - **Package Upgrades (Replacements)**: Only package *upgrades* necessitate namespace isolation. Existing processes remain pinned to their older squashfs generation in their private namespace, avoiding torn shared libraries or clobbered assets until restarted.

3. **Read-Only Package Defaults (`/sw/<pkg>/etc`) & `/etc` User Overlay**
   - **Package Creation vs. System Configuration**:
     - Package creation (`swctl build`) builds hermetically and **never** touches `/etc`. All package-supplied default configuration files install strictly into `/sw/<pkg>/etc/` inside the read-only `.squashfs` image (zero copy, zero mutable package state).
   - **Layered Configuration (`Read /sw/<pkg>/etc` First, Overlay `/etc` After)**:
     - Packages are taught to read their vendor defaults from `/sw/<pkg>/etc/...` (or `/sw/*/etc/...`) first and overlay `/etc/...` on top (for example, reading `/sw/fstab` or `/sw/<pkg>/etc/fstab` first and overlaying `/etc/fstab` after to form the complete mount table).
     - `/etc` belongs strictly to the user/administrator. Mounting or upgrading a package in `/sw/<pkg>` never mutates `/etc` or runs background mount hooks (`fluffy-upsert` / `fluffy-init` are eliminated).
     - When user-level setup or initialization is desired, users explicitly invoke functions/commands that write directly to `/etc`.
   - **Btrfs Snapshot Protection for `/etc`**:
     - The root filesystem uses **btrfs**, and `/etc` can be snapshotted across administrative changes for instant atomic rollback.

4. **Late-Bound `/sw/*/foo` Discovery (No Symlink Farms, Zero Hardcoded Package Ownership)**
   - **Principle of Late Binding**: Tools and libraries should never assume or hardcode which `/sw/<pkg>` provides a given header, library, executable, or data file. Instead, resolution should happen as late as possible by walking `/sw/*` alphabetically (`alphasort`) in the current mount namespace.
     - Even if a build tool (`configure`, a linker, etc.) resolves a `/sw/<pkg>/...` path during build, the input to that build should never require hardcoding `--with-foo=/sw/bar`. And wherever possible, runtime tools should traverse `/sw/*` dynamically (caching per-process, which is always safe because `/sw` mounts never change within a launched process's mount namespace).
     - **Why this matters**: Packages can be split into subpackages, merged, or reorganized later (e.g. `libstdcpp` separate from `gcc` vs. bundled) and everything continues to work with zero flag changes.
   - Concrete `/sw/*` discovery points:
     - **`PATH` (`/sw/*/bin` only — zero `sbin`)**:
       - Fluffy does not use `sbin` directories anywhere. All utilities, system binaries, and administrative daemons reside in `/sw/<pkg>/bin` (configured via `--sbindir=/sw/<pkg>/bin` or `rootsbindir=/sw/<pkg>/bin`).
       - `bash`: `findcmd.c` and `bashline.c` dynamically glob and iterate `/sw/*/bin` for command resolution and TAB completion.
       - `glibc`: `posix/execvpe.c` (`__execvpe_common`) parses wildcard PATH entries like `/sw/*/bin`, discovers all `/sw/<pkg>/bin` directories via `__getdents64` without heap allocations (`vfork`/`CLONE_VM` safe), and tests executables in alphabetical order. All POSIX execution APIs (`execvp`, `execvpe`, `execlp`, `posix_spawnp`) work transparently with literal wildcard `PATH`.
          - **Future Enhancement — Wildcard Executable Paths in `glibc` & `PATH`-Resolving `#!` via `binfmt_misc`**:
            - **Wildcard Executable Paths in `glibc` (`exec*` / `posix_spawn`)**: Teach `glibc` execution routines (`execve`, `execv`, `execvpe` when `file` contains `/`, `posix_spawn`) to expand glob patterns directly in the executable path itself (e.g. `/sw/*/bin/sh`, `/sw/*/bin/diff`), where the first lexicographical match wins.
            - **Kernel-Level `#!` Resolution via `binfmt_misc` (`#!bash`, `#!perl`, `#!/sw/*/bin/...`)**:
              - In the Linux kernel (`fs/exec.c`), `binfmt_misc` (`register_binfmt`, added at the head of `formats`) runs *before* `binfmt_script` (`insert_binfmt`, added at the tail) and applies to all `execve(2)` callers—including statically linked non-libc binaries like Go.
              - Since Linux 6.7+, `binfmt_misc` is per-user-namespace, so `swctl` (or a booted Fluffy system) can mount an isolated `binfmt_misc` instance and register a handler at `/sw/shebang/bin/shebang` on magic `#!` (with `P` `preserve-argv[0]` and `O` `open-binary` flags, and *without* `F` so the kernel resolves `/sw/shebang/bin/shebang` dynamically inside the caller's active mount/chroot namespace).
              - Because `binfmt_misc` invokes the handler in the calling process's context with its exact `envp` (including `PATH`), shebangs can honor the caller's `PATH` via `execvp()`—enabling pathless shebangs like `#!bash`, `#!sh`, `#!perl -w`, or `#!python3`, as well as globbed shebangs (`#!/sw/*/bin/bash`) or legacy FHS shebangs (`#!/bin/sh`, `#!/usr/bin/env ...`) without patching script headers.
              - **Two-Stage Bootstrap (`host /bin/bash` Shim → Native C `shebang` Binary)**:
                1. **Stage 1 (`host-build` Bootstrap Placeholder)**: On the host (where `swctl` already expands `/sw/*/bin` into explicit `PATH` entries so no `PATH` globbing is needed yet), `swctl` bind-mounts the host's `/bin/bash` ELF binary to `/sw/shebang/bin/shebang` with a tiny `BASH_ENV` hook. Because `/bin/bash` is an ELF binary (`\x7fELF`), `binfmt_misc` does not recurse on `#!`; when invoked on a script, `bash` sources `$BASH_ENV`, inspects line 1 of `$0`, executes plain `#!bash`/`#!sh` scripts directly in-process (treating line 1 as a `#` comment), and uses `BASH_ENV= exec <interp> "$0" "$@"` to dispatch flagged (`#!bash -e`) or non-shell (`#!perl -w`, `#!gawk -f`) scripts via normal `PATH` lookup.
                2. **Stage 2 (`cross-build` / `fluffy-build` Native C Handler)**: Once the cross-toolchain (`gcc-pass1` + `glibc-pass1`) is built, a tiny, zero-overhead native C `shebang` binary is cross-compiled against Fluffy's glob-aware `glibc` (`execvp`) and packaged at `/sw/shebang/bin/shebang`. Entering the chroot mounts `/sw/shebang` at the exact same `/sw/shebang/bin/shebang` path already registered in `binfmt_misc`, handing off seamlessly from the host bash placeholder to the native C binary.
            - **GNU `make` Default Shell (`default_shell = "bash"` / `SHELL = bash`) & `find_in_given_path` Wildcard `PATH`**:
              - In `make-4.4.1/src/job.c`, `default_shell` is hardcoded to `"/bin/sh"`, and when `USE_POSIX_SPAWN` is enabled (lines 2450–2460), `make` does not call `posix_spawnp()` (because `glibc`'s `execvpe`/`posix_spawnp` reads `getenv("PATH")` from the parent's `environ` rather than `child->environment`). Instead, `make` calls gnulib's `find_in_given_path(argv[0], p, NULL, 0)` (`lib/findprog-in.c`) before `posix_spawn()`.
              - Because gnulib's `find_in_given_path` splits `PATH` on `:` without expanding `/sw/*/bin`, relative command names (fast-path `touch`, `printf`, or `argv[0] = "bash"` when `SHELL = bash`) fail unless `SHELL` is an absolute path (`SHELL = /sw/bash/bin/bash`).
              - While `--disable-posix-spawn` falls back to `vfork()` + `environ = child->environment; execvp()` (which uses `glibc`'s wildcard `PATH`), it has the downside that missing commands (`ENOENT`) `vfork()` first and invoke `OSS(error, ...)` (`gettext`/`stdio`) inside the `vfork()` child while sharing the parent's heap, and skips `posix_spawn`'s dedicated stack and full signal masking.
              - **Fix for Chapter 8 `make`**: Set `default_shell = "bash"` in `src/job.c` and teach `find_in_given_path` (`lib/findprog-in.c`) to expand wildcard `PATH` entries via `glob()`. That keeps `USE_POSIX_SPAWN` enabled while making both `SHELL = bash` and Makefiles that omit `SHELL` altogether work out of the box via `/sw/*/bin`.
            - **Perl `File::Spec::Unix::path()` Wildcard `PATH` Expansion (`dist/PathTools/lib/File/Spec/Unix.pm`)**:
              - In Perl's standard library, `File::Spec->path()` (`File::Spec::Unix::path`) is the canonical function used by `IPC::Cmd::can_run()`, `ExtUtils::MakeMaker` (`maybe_command`), `CPAN`, and downstream consumers like OpenSSL's `./config` (`OpenSSL::config`) to iterate `$ENV{PATH}` directories.
              - Upstream `File::Spec::Unix::path` simply runs `split(':', $ENV{PATH}, -1)`, returning the literal string `"/sw/*/bin"`, which fails `-d $dir` checks in callers.
              - **TODO for Next `perl` Pass**: Patch `File::Spec::Unix::path` in `dist/PathTools/lib/File/Spec/Unix.pm` to expand wildcard `PATH` entries (using pure-Perl `opendir`/`readdir` so it works even inside `miniperl` before the `File::Glob` XS module is built), making `File::Spec->path()` and `IPC::Cmd::can_run()` work transparently across all Perl scripts without per-package overrides.
            - **Eliminating Explicit `/sw/<pkg>/bin/<prog>` Overrides (First-Class `PATH` Honoring)**:
              - **Architectural Imperative**: As much as possible, stop requiring build recipes to configure tools with explicit paths like `/sw/<pkg>/bin/<tool>` (e.g. `HASHBANGPERL=/sw/perl/bin/perl`, `PKG_CONFIG=/sw/coreutils/bin/true`, `autosetup_tclsh=/sw/tcl/bin/tclsh`). Build systems and packages must honor `$PATH` and resolve tools (`perl`, `tclsh`, `python3`, `true`, `sh`, `cc`) dynamically from the environment.
              - **Why Upstream Configures Currently Demand Absolute Paths**:
                1. *Interpreted `PATH` Scanners*: Scripts in Tcl (`autosetup`), Python (`shutil.which`), Perl (`File::Spec->path`), or gnulib (`findprog-in`) manually split `$PATH` on `:` and test each item with `stat`/`access(2)`, failing on `/sw/*/bin`.
                2. *Baking Shebangs into Generated Scripts*: Tools like OpenSSL or Automake resolve an interpreter during `./configure` specifically to write `#!$PATH_TO_PERL` into installed scripts.
              - **The Unified Path-Honoring Strategy**:
                1. *Runtime `which`/`path` Patches*: Teach each core language runtime's path-resolution primitive (Perl `File::Spec::Unix::path`, Python `shutil.which`, Tcl `TclpFindExecutable` / `split-path`, Gnulib `findprog-in`) to expand wildcard `$PATH` elements via `glob()`.
                2. *Path-Resolving Shebangs (`binfmt_misc`)*: With kernel-level `binfmt_misc` resolving shebangs via `$PATH` (`execvp`), installed scripts can simply use `#!perl`, `#!bash`, or `#!python3` instead of hardcoding `/sw/<pkg>/bin/<tool>`.
                3. *Global Autoconf Site Defaults (`CONFIG_SITE`)*: Provide a system-level `config.site` that pre-sets standard tool variables (`PERL=perl`, `AWK=gawk`, `SED=sed`, `PKG_CONFIG=true`) as bare command names rather than absolute filesystem paths, ensuring downstream Makefiles invoke tools through the active `$PATH`.
       - Shell defaults in `paths.h` and `system.c`: `_PATH_DEFPATH` defaults to `"/sw/*/bin"`, `_PATH_STDPATH` to `"/sw/*/bin:/sw/*/sbin"`, and `_PATH_BSHELL` / `SHELL_PATH` to `"/sw/bash/bin/bash"`, ensuring `system()` and `popen()` run natively without `/bin/sh`.
     - **Dynamic Linker (`ld.so`)**: Iterates `/sw/*/lib` (`_dl_init_paths` in `elf/dl-load.c`) to resolve shared libraries dynamically at runtime.
     - **Final Pass Toolchain Vision (Glibc & GCC Native Wildcard Inclusion)**:
       - **GCC Preprocessor (`cppdefault.cc`)**: In the final native pass, patch GCC's include directory search logic to natively understand `/sw/*/include` (and `/sw/*/include/c++/<ver>`) instead of hardcoding `/usr/include`. GCC's CPP will discover and include headers across all mounted packages without passing a single `-I` flag.
       - **Linker (`binutils` `ld`) & Specs**: Set default library search paths to `/sw/*/lib` instead of `/usr/lib` or `/lib`.
         - **Dynamic Wildcard `SEARCH_DIR` in Binutils Linker Scripts**: Quoting `LIB_PATH='/sw/*/lib'` embeds literal `SEARCH_DIR("/sw/*/lib")` in the default ldscripts, allowing `ldfile.c` to dynamically expand `/sw/*/lib` via `glob()` at runtime and register all `/sw/<pkg>/lib` with `cmdline=false`. This ensures `ldelf.c` automatically resolves both direct `-l<name>` libraries and indirect `DT_NEEDED` dependencies (e.g. `libncursesw.so.6` needed by `libreadline.so`) without requiring `-rpath-link` or explicit `-L` flags.
       - **Zero `-I`/`-L` Flags & Deprecation of `pkg-config`**: Because GCC, LD, and LD.SO dynamically iterate all `/sw/*/{include,lib}`, packages built for Fluffy never need `-I` or `-L` directory path flags or `pkg-config` path overrides. Upstream packages link against external libraries simply with `-l<name>`.
     - **Systemd Unit Files (`/sw/*/lib/systemd/system`)**: `systemd` (`lookup_paths_init` in `sd-path/path-lookup.c`) iterates `/sw/*/lib/systemd/system` (and `/sw/*/lib/systemd/user`) so services install their own `.service` / `.socket` files directly in `/sw/<pkg>/lib/systemd/system/` (via a heredoc or local file in `INSTALL()`), eliminating any need for external meta-packages like `blfs-systemd-units`.
     - **General-Purpose Wildcard Support (Configure `/sw/*`, Never Hardcode `/sw/` in C Source)**:
       - **Architectural Rule**: C source patches to upstream packages must **never** hardcode Fluffy-specific directory names like `"/sw"` or `"/lib"` or custom `scandir("/sw", ...)` loops. Instead, upstream code is patched to support general-purpose glob/wildcard expansion in its standard configuration paths, and `/sw/*/bin`, `/sw/*/lib`, `/sw/*/include` are passed in via configuration (`configparms` `user-defined-trusted-dirs`, `configure` flags, `paths.h`, `STANDARD_STARTFILE_PREFIX`, `NATIVE_SYSTEM_HEADER_DIR`, `PATH`).
       - For example, in `glibc` (`elf/dl-load.c`), `SYSTEM_DIRS` receives `/sw/*/lib/` via `user-defined-trusted-dirs=/sw/*/lib` in `configparms`, and `_dl_init_paths` / `is_trusted_path_normalize` expand wildcard entries in `system_dirs` generically (just like `binutils` `ldfile.c` calls `glob()` on `LIB_PATH=/sw/*/lib` and `bash` calls `shell_glob_filename` on `PATH=/sw/*/bin`).
       - Similarly, `gcc` (`gcc.cc`, `incpath.cc`, `cppdefault.cc`) should expand wildcards in configured `STANDARD_STARTFILE_PREFIX`, `STANDARD_EXEC_PREFIX`, and `NATIVE_SYSTEM_HEADER_DIR` (`--with-native-system-header-dir=/sw/*/include`) via `glob()` rather than hardcoding `scandir("/sw")`.
     - **Deprecation of `ldconfig` / `ld.so.cache` & Optimizing `glob()` in `glibc` as the Universal Lookup Primitive**:
       - `ldconfig` and `USE_LDCONFIG` (`ld.so.cache`) are completely disabled (`use_ldconfig=no`) in `glibc`. In an FHS system, `ld.so.cache` is a single-purpose hack for one subsystem (`ld.so`), whereas in Fluffy, `ld.so` (`/sw/*/lib`), `execvpe` and `bash` (`/sw/*/bin`), `gcc`/`binutils` (`/sw/*/include`, `/sw/*/lib`), and `tcl` (`/sw/*/lib`) all share the exact same access pattern: wildcard path expansion over `/sw/*/...`.
       - Rather than maintaining subsystem-specific caches or scattering custom `getdents64` loops across tools, standard POSIX `glob()` in `glibc` is the single general-purpose primitive. Optimizing `glob()` directly inside `glibc` (and using `glob()` everywhere) makes `ld.so`, `execvpe`, `bash`, `tcl`, `gcc`, and every standard `glob()` caller fast automatically.
      - **Enriching `glibc` `glob()` with Bashisms & Delegating Bash, Tcl VFS, and Python Globbing to Glibc**:
        - **Enriching `glibc` `glob()` & `fnmatch()`**:
          - Extend `posix/glob.h`, `posix/glob.c`, `posix/glob_internal.h`, `posix/fnmatch.h`, and `posix/fnmatch_loop.c` with new flags to match modern shell and language globbing, allocating custom Fluffy flag bits from the **high end** of the bit range (`(1 << 30)` downward) so they never collide with flags that upstream `glibc` may add in future releases:
            - `FNM_DOTDOT` (`1 << 30`): Leading `.` or `..` matched only explicitly (never by `*`, `?`, `[...]`, or `!(...)`).
            - `GLOB_KEEP_SLASHES` (`1 << 30`): Preserve redundant trailing slashes on literal directory patterns (`"aaa//"` -> `"aaa//"`) while still normalizing wildcard directory matches (`"aa*//"` -> `"aaa/"`).
            - `GLOB_PATHS` (`1 << 29`): Expand colon-separated `PATH` elements as ordered alternation, where empty segments (`""`) normalize to `"."` and alphabetical sorting applies strictly **within** each colon-delimited segment (never reordering across `:` boundaries).
            - `GLOB_EXTMATCH` (`1 << 28`): Expose `FNM_EXTMATCH` in `glob()` and `glob_dirscan`/`__glob_pattern_type_ext` to enable ksh/bash extended pattern matching (`@(a|b)`, `!(x)`, `+(x)`, `*(x)`, `?(x)`).
            - `GLOB_CASEFOLD` (`1 << 27`): Expose `FNM_CASEFOLD` for case-insensitive matching (`nocaseglob`).
            - `GLOB_SKIPDOTS` (`1 << 26`): Never match `.` or `..` even when `GLOB_PERIOD` or explicit `.*` is used (`globskipdots`).
            - `GLOB_GLOBSTAR` (`1 << 25`): Recursive `**` directory-tree traversal (`globstar`, following symlinks only for the pattern `"**"` itself and not descending into symlinked directories for `"**/..."`).
            - `GLOB_DOTDOT` (`1 << 24`): Skip `.` and `..` unless the pattern explicitly begins with `.` (used with `GLOB_PERIOD` for Bash `dotglob`).
          - This eliminates the historical reason GNU Bash bundled its own `lib/glob` (cross-UNIX portability to non-glibc OSes), allowing Fluffy's `bash` to completely delete `lib/glob/glob.c`, `lib/glob/glob_loop.c`, `glob_dirscan` (`lib/glob/gmisc.c`), `get_next_path_element` (`findcmd.c`), and `extract_colon_unit`/`bash_tilde_expand` in `command_word_completion_function` (`bashline.c`), delegating 100% of filesystem globbing and `PATH` expansion to `glibc` `glob()`.
        - **Delegating Tcl VFS Glob to `glibc` `glob()` & Per-Mount VFS Table (`GLOB_MOUNTS`)**:
          - In Tcl's Virtual File System (`generic/tclFileName.c` and `generic/tclIOUtil.c`), upstream `DoGlob` splits multi-component patterns at every `/` and implements its own `{a,b}` brace expansion and directory recursion solely because it assumes OS `glob(3)` cannot see Tcl VFS mounts.
          - Meanwhile, legacy `GLOB_ALTDIRFUNC` in `glob_t` is all-or-nothing (forcing every path in the `glob()` call through global callbacks without a `void *userdata` pointer, disabling the native `/dev/shm` SquashFS cache, and requiring callers to manually merge submounts into parent directory listings).
          - **VFS Mount Table in `glob_t` (`GLOB_MOUNTS`, mutually exclusive with `GLOB_ALTDIRFUNC`)**:
            - Reuse the 5 `GLOB_ALTDIRFUNC` function-pointer slots at the end of `glob_t` via an anonymous `union` (preserving `sizeof(glob_t)` and full ABI compatibility) to pass a pointer/count (or NULL-terminated array) of `struct glob_mount { const char *gm_mountpoint; struct glob_vfs gm_vfs; void *gm_userdata; }`.
            - Internally in `posix/glob.c`, legacy `GLOB_ALTDIRFUNC` becomes a special case of a 1-entry mount table mounted at `""` (`"/"`) with `userdata = NULL`.
            - During multi-component `glob()` traversal, `glob()` resolves the active mount by longest prefix match on the directory path:
              1. Any directory not under a custom VFS mountpoint runs 100% natively (retaining full `/dev/shm` SquashFS cache acceleration for `/sw/*` and zero per-lookup C callbacks).
              2. Any VFS submount whose `gm_mountpoint` is a direct child of a scanned directory is automatically synthesized as a `DT_DIR` candidate without needing `matchmounts` callbacks on every directory.
              3. When descending into a directory matching `gm_mountpoint`, `glob()` dispatches `opendir`/`readdir`/`closedir`/`stat`/`lstat` to that mount's `gm_vfs` callbacks along with `gm_userdata`.
            - This allows Tcl to pass multi-component and braced patterns directly to `glibc` `glob()` in a single call whether or not custom VFS mounts (`simplefs:/`, `zipfs`, `testReportingFilesystem`) are registered, eliminating Tcl's custom `DoGlob` recursion.
        - **Colon (`:`) as a First-Class `glob(3)` Construct (`GLOB_PATHS`)**:
          - `GLOB_PATHS` (`1 << 29`) treats top-level `:` (outside `[...]` and `extglob(...)`) as an ordered alternation operator:
            - **Strict Segment Ordering**: A `PATH` like `"/x:/y/*/z:/w"` always resolves `/x` first, then alphabetically sorted matches of `/y/*/z`, then `/w`, even when alphabetical sorting is enabled (since `__glob` sorts only the slice `[oldcount, gl_pathc)` appended by each segment).
            - **Directory-list expansion & Executable lookup**: `glob(path, GLOB_PATHS | ..., NULL, &g)` replaces hand-rolled `:`-splitting, tilde-expansion, and directory-scanning loops across C, Python, Perl, Tcl, Gnulib, and Bash.
        - **Making Python's `glob` Module a Thin C Shim Around `glibc` `glob()`**:
          - Upstream Python's `Lib/glob.py` implements pattern matching in pure Python (`os.scandir` + `fnmatch` + `re` regex compilation), which pulls `re`, `fnmatch`, `collections`, and `functools` into `sys.modules` whenever `import glob` runs (breaking `test_site.test_startup_imports` if imported in `site.py`) and bypasses `glibc`'s native `glob()`.
          - Python's `posix._glob` and `_getpath.glob` delegate directly to `glibc`'s `glob(3)` (`GLOB_NOESCAPE | GLOB_KEEP_SLASHES`), keeping `import glob` and `site.py` zero-dependency and fast.
      - **Two-Layer SquashFS-Aware Cross-Process `glob()` Cache Architecture in `glibc`**:
        - **Problem**: Linux build workloads (`configure`, `make`, shell scripts) spawn thousands of short-lived processes (`fork`+`exec`), and 99%+ of `glob()` calls resolve `/sw/*/bin/<cmd>` (or `/sw/*/bin`, `/sw/*/lib`, `/sw/*/include`), which returns the exact same result within a mount namespace.
        - **Design Principle**: "Get it right, then get it fast" — once `glibc` + `bash` and `glibc` + `tcl` glob unification are verified, accelerate `glob()` transparently inside `glibc`:
        - **1. Literal-Suffix Fast Path in `glob()`**:
          - When `glob()` expands a multi-component pattern ending in a literal suffix (e.g. `/sw/*/bin/bash` or `/sw/*/bin` with `GLOB_ONLYDIR`), avoid recursive intermediate `glob_t` heap allocations and intermediate `fstatat` calls; probe `<dir>/<literal-suffix>` directly.
        - **2. SquashFS On-Disk Sorted Order (`SQUASHFS_MAGIC`)**:
          - `mksquashfs` (`unsquash-4.c` / `sort_directory`) sorts all directory entries in byte (`strcmp`) order on disk, and the Linux kernel's `squashfs_readdir` yields `getdents64` entries in that exact on-disk order.
          - On a SquashFS mount (`f_type == SQUASHFS_MAGIC`, `0x73717368`) in the `C` / `POSIX` locale (`_NL_CURRENT_WORD (LC_COLLATE, _NL_COLLATE_NRULES) == 0`), `getdents64` already streams entries in sorted order with zero `qsort` needed.
        - **3. Layer 1 — Per-SquashFS-Mount Immutability (`/sw/<pkg>`)**:
          - Because every mounted SquashFS image at `/sw/<pkg>` is 100% read-only and immutable, any lookup within `/sw/foo/bin` for `baz` (both positive and negative) will return the exact same result for the lifetime of that mount.
          - Identified by its kernel mount/superblock identity (`STATX_MNT_ID_UNIQUE` `stx_mnt_id` or `(st_dev, st_ino, st_mtim)` with `f_type == SQUASHFS_MAGIC`), cached directory entry tables for `/sw/<pkg>/bin` (and `/sw/<pkg>/lib`, `/sw/<pkg>/include`) never expire while mounted and can be reused across processes and even across different build namespaces that mount the same `.squashfs` image.
        - **4. Layer 2 — Whole-`/sw` Mount-Set Snapshot & $O(1)$ Inverted Index for `/sw/*/bin/<cmd>`**:
          - For `/sw/*/bin/<literal>` queries, an **inverted hash table** keyed on `<cmd>` maps `"bash"` directly to `"/sw/bash/bin/bash"` (or the pre-sorted list of matching `/sw/<pkg>/bin/<cmd>` paths) in **$O(1)$ time** without iterating over the 60+ `/sw/<pkg>` directories on each call.
          - Detecting whether `/sw/` mounts have changed in the current mount namespace is also $O(1)$:
            - Via Linux 6.8+ `listmount()` (returning the array of 64-bit `mnt_id_unique`s under `/sw` in a single syscall with zero `/proc` or string parsing), and/or
            - Checking `(mnt_ns_id, /sw st_dev, /sw st_ino, /sw st_ctim)` via `stat("/sw")` (since `swctl` creates/updates mountpoints under `/sw` whenever mounts change, and within a `swctl build` sandbox `/sw` mounts never change after `pivot_root`).
        - **5. Cross-Process Persistence & Permission / Namespace Safety**:
          - Because in-memory per-process caching doesn't help across `fork`+`exec` of short-lived processes, the cache lives in a cross-process shared memory / `mmap` segment (`PROT_READ | MAP_SHARED`).
          - Keyed by mount namespace (`/proc/self/ns/mnt` + root `/` `(st_dev, st_ino)` for `chroot` safety) and effective credentials (`euid`, `egid`), with a fast-path `all_world_rx` bit when all traversed `/sw/<pkg>` and `/sw/<pkg>/bin` directories have `0755` (`S_IROTH | S_IXOTH`) permissions (the 99.99% case in Fluffy SquashFS images built with `-all-root`), allowing a single namespace cache entry to serve all UIDs safely.
        - **6. Single Shared Implementation in `glibc` Only (Zero Header Triplication, `RELRO`/`vfork` Safety & `GLIBC_TUNABLES`)**:
          - **Single Implementation in `glibc`**: Delete the duplicated `include/fluffy-cache.h` header and all `fc_*` hooks from `binutils` (`sw/binutils-2.47-fluffy-source.patch`) and `gcc` (`sw/gcc-16.2.0-fluffy-source.patch`), reverting both to tiny, upstream-clean `glob(..., GLOB_ONLYDIR, ...)` patches with zero `"/sw"` strings or cache logic. (During `ON=host-build` `pass1`, `/sw` has only 1–5 mounts so host `glob()` is already instantaneous; by `pass2`, tools link against Fluffy's `glibc`.)
          - **Eliminate Multi-TU Header Duplication & Respect `RELRO` / `vfork` Constraints**: Refactor `posix/glob_fluffy_cache.h` from a multi-thousand-line `static` header into a single shared internal module across `ld.so`, `libc.so`, and `libc.a` (deleting `#ifdef FC_TEST_*` shims). Keep `_rtld_global_ro` (`GLRO`) strictly for immutable views seeded by `ld.so` prior to `_dl_protect_relro`; store dynamically discovered runtime prefixes in writable `_rtld_global` (`GL`) as an append-only atomic slot table guarded by an internal `__libc_lock` for writers, while `execvpe()` reads already-mapped slots lock-free and never allocates, locks, or mutates global state inside a `vfork()` (`CLONE_VM`) child.
          - **Benchmark-Gated `libc.so` Read-Only VFS Negative-Lookup Wrappers**: Optionally hook `glibc`'s read-only path-probing wrappers (`open`/`openat` without `O_CREAT`, `stat`/`lstat`/`fstatat`/`statx`, `access`/`faccessat`) against the same shared `FSWC` module so negative probes inside immutable SquashFS mounts short-circuit in userspace (~15 ns) across `cc1`, `ld`, `dlopen`, Python/Perl/Tcl module search, and shell tests—subject to the strict POSIX correctness invariants in (10) and empirical benchmarking in (12).
          - **Idiomatic Runtime Control via `GLIBC_TUNABLES` (`glibc.fswc.mode=0|1|2`, `glibc.fswc.max_inodes`)**: Register `SXID_IGNORE` (`AT_SECURE`-safe) tunables in `elf/dl-tunables.list` parsed at `rtld` startup before `_dl_init_paths`: `mode=0` (uncached kernel baseline), `mode=1` (core `FSWC` in `ld.so` + `glob()` + `execvpe()`), `mode=2` (core `FSWC` + `libc.so` VFS negative-lookup wrappers), plus a configurable sanity cap `max_inodes` (e.g. default `1,048,576`, `0` = unlimited) that cleanly falls back to uncached `glob()` instead of stalling or OOMing `ld.so` if a multi-million-inode archival SquashFS is mounted under a wildcard prefix.
        - **7. General-Purpose Multi-Prefix Discovery & Killing `/tmp/.fluffy_ns_sealed` (Zero Hardcoded `"/sw"`)**:
          - **Zero `"/sw"` String Literals**: Delete `fswc_is_sw_prefix` and all hardcoded `"/sw"` / `"/sw/"` checks. Any wildcard pattern `<prefix>/*` or `<prefix>/*/...` passed to `ld.so` (`system_dirs`), `execvpe()` (`PATH`, e.g. `/sw/.build/*/bin:/sw/*/bin`), or `glob()` treats canonical `<prefix>` as a candidate mount-farm prefix.
          - **SquashFS-Gated Activation**: `fswc_get_prefix_state(prefix)` runs `statx(prefix)` + `listmount(prefix_mnt_id)` (~4.1 µs total). If `<prefix>` contains zero `SQUASHFS_MAGIC` child mounts (e.g. `glob("/home/*/.bashrc")` or `glob("/tmp/*")`), `FSWC` bails out immediately without building or mapping any cache blob and falls straight back to standard `glob()`.
          - **Multi-Prefix Table (`GLRO` Seeded + `GL` Dynamic)**: Seed initial prefix views in `ld.so` from wildcard `system_dirs` entries into `GLRO` before `RELRO` freeze, and extend on demand in `libc.so`'s writable `GL` table whenever additional SquashFS mount-farm prefixes (`/sw/.build`, `/opt/pkgs`, test harnesses) are queried.
          - **Kill `/tmp/.fluffy_ns_sealed`**: Remove `touch /tmp/.fluffy_ns_sealed` from `swctl` and delete `fswc_check_ns_sealed`, `fswc_format_sealed_path`, and `FSWC_HDR_SEALED` from `glibc`. Live validation via `statx` + `listmount(prefix_mnt_id)` takes ~4.1 µs and recursively enumerates the entire descendant mount subtree under `<prefix>` (including grandchild overmounts), eliminating stale-marker hazards completely.
        - **8. Uniform `(parent_id, basename)` Full-Tree Index (Eliminating `FSWC_NUM_SUBDIRS` & `FSWC_INC_MAX_SLASHES`)**:
          - **Replace the 5-Subdir Whitelist & Depth Cap with a Uniform Radix/DAG Table**: Delete `FSWC_NUM_SUBDIRS = 5` (`fc_subdir_names = {"bin", "lib", "etc", "include", "libexec"}`), `sub_start[5]`/`sub_count[5]`/`inc_deep_start` in `struct fswc_pkg`, `(ns_id << 24)` bit-packing in `fswc_ht_entry`, and `FSWC_INC_MAX_SLASHES = 4`. Walk every immutable SquashFS mount iteratively using a dynamically grown `fswc_buf` work-stack (zero C call-stack recursion cap) and index every entry at arbitrary depth by `(uint32_t parent_id, basename)` (where `parent_id == 0` is `<prefix>/<pkg>` root).
          - **Compactness & Universal Coverage**: Storing single path components in `strtab` deduplicates repeated basenames (`"__init__.py"`, `"Makefile"`, `"lib"`), fitting all ~57k inodes across all 91 Chapter 8 packages into ~2 MiB total and covering every path shape (`share/terminfo/*/*`, `lib/python3.14/site-packages/...`, `lib/perl5/...`, `lib/systemd/system/*.service`, `etc/modprobe.d/*.conf`, `etc/ssl/certs/...`, and arbitrarily deep `include/c++/...` trees) without special cases.
          - **Unified Wildcard & Component Traversal**: Pair the node index with a flat `(pkg_idx, dir_node_id) -> (dirent_start, dirent_count)` slice table so wildcard `fnmatch` works at any directory depth, collapsing Cases A/B/C in `glob.c` into one component-walking loop over `(ptr, len)` string slices with zero fixed `PATH_MAX`/`NAME_MAX` copy buffers.
        - **9. Content-Addressed `MAP_SHARED` Blobs, Per-UID `0700` SHM Isolation & Chroot-Safe Backing-File Identity (Eliminating `FSWC_SHM_SLOTS`)**:
          - **Split Namespace Binding from Content-Addressed Blob + Per-Package Subtree Reuse**: Eliminate `FSWC_SHM_SLOTS = 16` (`mix64(prefix_mnt_id) & 15`, which collides across multiple prefixes and `unshare(CLONE_NEWNS)` clones) and stop baking `prefix_mnt_id` / `mnt_hash` into the blob header (which forced `MAP_PRIVATE` + `mprotect` CoW dirtying). Store namespace- and prefix-independent blobs `blob_<128bit_pkgset_hash>` mapped `PROT_READ | MAP_SHARED` (with optional per-package subtree blobs `pkg_<128bit_pkg_id>` so novel `BUILD_NEEDS` combinations assemble in memory from already-indexed packages without re-walking `getdents64`), paired with exact-ID namespace bindings `ns_<prefix_mnt_id>_<prefix_ino>` storing `(prefix_dev, prefix_ctime, prefix_mtime, mnt_count, order_sensitive_mnt_hash128)` → `pkgset_hash` (so unmounted sibling dir edits under `<prefix>` also invalidate immediately).
          - **Per-UID `0700` Directory Isolation & `SIGBUS` / `/proc`-less Hardening**: Place all SHM artifacts inside `/dev/shm/.fswc-<uid>/` (created `0700`, opened `O_RDONLY | O_DIRECTORY | O_NOFOLLOW`, verified `st_uid == euid && (st_mode & 07777) == 0700` via `fstat`, with all child ops using `openat`/`renameat` on that `dirfd` so `/proc` is never required and other local UIDs cannot pre-create, squat, or poison filenames in sticky `1777` `/dev/shm`). `fchmod` completed temp files `0400` before `renameat` (and validate `fstat` size >= header `total_size` before `mmap`) to prevent accidental same-UID truncation `SIGBUS`, using `fstatfs` free-space pressure eviction instead of a hardcoded `512 MiB` ceiling.
          - **Chroot-Safe Git-Style `statx` Identity on Loop Backing Files & Persistent Build SHM**: Cold-namespace setup reads `/sys/dev/block/<maj>:<min>/loop/backing_file` and calls `statx(..., STATX_BASIC_STATS)` to key each package by Git's stat tuple `(dev_major, dev_minor, ino, size, ctime_sec, ctime_nsec, mtime_sec, mtime_nsec)`. If `backing_file` carries a pre-`chroot` host prefix (e.g. `/mnt/fluffy/sw/foo.squashfs` when `$ON` was loop-mounted before `chroot "$FLUFFY"` in `swctl`) and returns `ENOENT`, fall back to probing `<prefix>/<basename>` inside the chroot before falling back to SquashFS root `(sb_dev_major, sb_dev_minor, root_ino, root_mtime)`. In `swctl`, share a persistent cache tmpfs across chroot package builds (rather than wiping `$FLUFFY/dev/shm` per package) so Tier-1 package cache hits persist across the entire build DAG.
        - **10. Strict POSIX/VFS Correctness Invariants ("Optimizations Must Never Change Correctness")**:
          - **True Immutable Filesystem Images Only**: Mark `<prefix>/<pkg>` `FSWC_PKG_IMMUTABLE` strictly when `f_type == SQUASHFS_MAGIC` (optionally `EROFS_SUPER_MAGIC_V1`) **and** no descendant mount in `listmount(prefix_mnt_id)` has `mnt_parent_id == pkg_mnt_id` (read-only bind mounts of mutable filesystems are never assumed immutable).
          - **Never Negative-Cache Unknown or Mutable `<pkg>` Entries**: Any `<pkg>` absent from `v->pkgs` or lacking `FSWC_PKG_IMMUTABLE` must fall through to the kernel (never return bogus `ENOENT`), so mutable sibling directories and freshly mounted packages work immediately.
          - **Preserve `ENOTDIR` vs. `ENOENT`**: Store exact `d_type` on every indexed node; traversing through (or trailing-slashing) a non-`DT_DIR` node must return `ENOTDIR` (or fall through to the kernel), never `ENOENT`.
          - **Fall Through on Any `DT_LNK`**: Any walked component with `d_type == DT_LNK` (internal or external, relative or absolute, dangling or looping) falls through to the kernel, preserving exact `stat` vs. `lstat`, `O_NOFOLLOW`, `AT_SYMLINK_NOFOLLOW`, `ELOOP`, and `GLOB_MARK` behavior.
          - **Separate `WORLD_SEARCH` (`0111`) vs. `WORLD_READ_SEARCH` (`0555`) & Preserve `ENAMETOOLONG`**: At index time, check `getxattr(..., "system.posix_acl_access")` == `ENODATA` and track **two** permission bits per directory: `WORLD_SEARCH` (`(st_mode & 0111) == 0111`, required on all three user/group/other classes so even an unprivileged owner or group member has search permission on `stat`/`open` traversal) and `WORLD_READ_SEARCH` (`(st_mode & 0555) == 0555`, required on directories enumerated by `glob()`, preventing `0111` execute-only directories from leaking filenames or skipping `EACCES` + `errfunc`); combined with per-UID `.fswc-<uid>/` isolation, `root`-built (`CAP_DAC_READ_SEARCH`) blobs are never served to unprivileged UIDs. Fall through to the kernel whenever a required bit is absent or any component exceeds `NAME_MAX` (255) / path reaches `PATH_MAX`.
          - **Preserve Exact `glob()` Collation & Error Callbacks**: Sort matched outputs with `glibc`'s own `collated_compare` so non-`C` `LC_COLLATE` locales match uncached `glob()` byte-for-byte, and fall back to standard `glob()` on `GLOB_ALTDIRFUNC` or unreadable directories when `errfunc != NULL` / `GLOB_ERR` is active.
          - **Live Mount & Symlink-Prefix Coherence (Including External `umount`/Overmount)**: `glob()` and `execvpe()` (`mode=1`) revalidate `statx` + `listmount(prefix_mnt_id)` (~4.1 µs) on every call (zero staleness window). If `mode=2` VFS single-path wrappers are enabled: (a) only register `<prefix>` for string-prefix matching if every ancestor component from `/` to `<prefix>` is verified non-symlink via `O_NOFOLLOW`, (b) invalidate immediately on in-process topology/credential syscalls (`mount`, `umount2`, `move_mount`, `fsmount`, `chroot`, `pivot_root`, `unshare`, `setns`, `set*uid`/`set*gid`), and (c) bound external cross-process `umount`/overmount visibility via a vDSO `CLOCK_MONOTONIC_COARSE` (~3 ns, zero-syscall) revalidation window.
        - **11. Comprehensive Test Suite Architecture (Two-Tier `make check` + Privileged Mount/SquashFS Differential Oracle)**:
          - **Tier 1 — Unprivileged `glibc` `make check` Suite (`posix/tst-fswc-*.c`, `elf/tst-fswc-*.c`)**: Replaces the minimal 40-line `dummy_err` check in `posix/tst-glob-bz30635.c` with dedicated tests that run automatically inside `swctl build glibc` `CHECK()` without requiring `CAP_SYS_ADMIN` or nested `CLONE_NEWUSER`:
            1. *Differential Oracle (`mode=0` vs. `mode=1` vs. `mode=2`)*: Spawns child workers across `GLIBC_TUNABLES=glibc.fswc.mode={0,1,2}` testing `glob()` (all `GLOB_*` flags, `errfunc != NULL`, `LC_COLLATE=C` and `en_US.UTF-8`), `execvpe()`, `dlopen()`, and `open`/`openat`/`stat`/`lstat`/`fstatat`/`statx`/`access`/`faccessat`, asserting identical return codes, `errno`s, `statx` fields, and `glob_t` arrays.
            2. *POSIX Edge Cases on Live `/sw` Mounts*: `ENOTDIR` on regular-file trailing slash (`/sw/bash/bin/bash/`) and file-as-parent (`/sw/bash/bin/bash/foo`), `ENAMETOOLONG` on 256-byte components and `>= PATH_MAX` paths, `.` / `..` / `//` path normalization, symlinked `<prefix>` (`ln -s /sw /tmp/sym_sw` flipped to `/tmp/empty_sw`), `O_CREAT` / `O_DIRECTORY` / `O_NOFOLLOW` / `AT_SYMLINK_NOFOLLOW` / `dirfd != AT_FDCWD` handling, `glibc.fswc.max_inodes=16` bailout fallback, and clean 0-blob no-op fallback on non-SquashFS `/tmp` prefixes.
            3. *Runtime & Adversary Resilience*: Static binary (`libc.a` `tst-fswc-static`), `vfork()` + `execvpe()` safety on cold/unmapped prefixes (verifying zero parent heap/lock mutation), multithreaded `pthread` barrier stampede dynamically adding new prefixes after `RELRO` freeze, cross-UID pre-created / symlink-squatted `/dev/shm/.fswc-<uid>` rejection, and corrupted/malicious blob/binding files (truncated length, bad magic/version, out-of-bounds offsets) verifying graceful kernel fallback with zero `SIGBUS`/`SIGSEGV`.
          - **Tier 2 — Privileged Mount-Topology & Pathological-SquashFS Torture Suite (`test-fswc`)**: Standalone runner (invoked under `sudo` / isolated `CLONE_NEWNS`) that builds synthetic `.squashfs` fixtures via `mksquashfs` containing every pathological inode shape (`0700` root-owned dirs, `0111` execute-only dirs, `0005` owner-denied dirs, `system.posix_acl_access` xattrs, internal relative symlinks, external symlinks, dangling symlinks, `ELOOP` symlink cycles, 16-level deep trees, 255-byte `NAME_MAX` names, `.hidden` files, UTF-8 collation pairs) and loop-mounts them across multiple arbitrary non-`/sw` prefixes (`/tmp/fswc_p1`, `/tmp/fswc_p2`) alongside mutable `tmpfs` sibling dirs:
            1. *Live Mount Mutation Coherence (In-Process & External Sibling Process)*: Mutates mounts both in-process and from an external sibling process sharing the mount namespace—mounting a new `.squashfs` child, adding/renaming unmounted sibling dirs under `<prefix>`, `umount2`ing an existing child, mounting a `tmpfs` grandchild overmount (`<prefix>/<pkg>/include`), and running `chroot` / `unshare(CLONE_NEWNS)`—asserting coherence across `mode={0,1,2}`.
            2. *Loop-Churn, Pre-`chroot` `backing_file` & Image-Rebuild Verification*: Loop-mounts outside a chroot and enters `chroot` (verifying `<prefix>/<basename>` fallback when host `backing_file` `ENOENT`s), detaches `/dev/loopX` and reattaches on `/dev/loopY` in a fresh namespace (verifying `0` `getdents64` calls via per-package reuse), then rebuilds/replaces the `.squashfs` file and verifies automatic invalidation.
            3. *Exhaustive Unprivileged-UID Oracle*: Warms cache as `root`, then drops privileges (`setresuid`) and runs randomized path/pattern probes comparing `mode=0` against `mode=1` and `mode=2` across every pathological fixture (`0111` `glob` `EACCES` vs. `stat` `0`, `0700` `EACCES`, `ENOENT`, `ENOTDIR`, `ELOOP`).
          - **Downstream Regression Gates**: Full `CHECK()` suites across `glibc`, `binutils` (DejaGnu `binutils`, `gas`, `ld`, `libctf`, `libsframe`), `gcc`, `bash`, `tcl`, `python`, and `kmod`.
        - **12. Reproducible Benchmark Suite (`glibc` `benchtests/` + Top-Level `bench-fswc`)**:
          - **Single-Binary A/B/C Methodology**: Benchmarks the exact same binaries on the 91-package Chapter 8 SquashFS set using `GLIBC_TUNABLES=glibc.fswc.mode={0,1,2}`, recording p50/p99 latency, wall-clock time, `user`/`sys` CPU time, VFS syscall counts (`perf stat` / `strace -c`), `.fswc-<uid>/` total byte size, and `/proc/self/smaps_rollup` `Private_Dirty` KiB (verifying `0 KiB` CoW dirtying on `PROT_READ | MAP_SHARED` mappings):
            1. **Cache Lifecycle Tiers (Cold-to-Warm Breakdown)**:
              - *Tier 0 (True Cold Build)*: Empty `/dev/shm` → 91-mount `listmount` + `statmount` + iterative `getdents64` walk + blob build + atomic publish.
              - *Tier 1 (Cold Namespace / Novel `BUILD_NEEDS` Subset / `/dev/loopN` Churn)*: Fresh `CLONE_NEWNS` + chroot → chroot-safe `backing_file` `statx` reuse + per-package subtree assembly → binding publish with zero `getdents64`.
              - *Tier 2 (Warm Cross-Process `exec`)*: `ld.so` startup + `MAP_SHARED` attach cost and RSS footprint.
              - *Tier 3 (Warm In-Process)*: Nanosecond per-call latency for `glob()`, `execvpe()`, VFS probes, and non-SquashFS prefix bailout (`< 5 µs`).
            2. **Microbenchmarks (`benchtests/bench-fswc-*` & `bench-fswc`)**:
              - *`glob()` pattern matrix*: Literal hit/miss (`/sw/*/bin/bash`, `/sw/*/bin/missing`), `GLOB_ONLYDIR` expansion (`/sw/*/{bin,include,lib}`), deep subpaths & wildcards (`/sw/*/lib/python3.14/site-packages/*`, `/sw/*/share/terminfo/*/*`, `/sw/*/include/c++/*/*/bits/*.h`), and multi-prefix `GLOB_PATHS` (`/sw/.build/*/bin/gcc:/sw/*/bin/gcc`).
              - *Process spawn & `PATH` search*: $N=1{,}000$ `posix_spawnp` / `fork`+`execvp("true")` hits and $N=1{,}000$ `execvp("missing")` misses with `PATH=/sw/*/bin`.
              - *Toolchain VFS probe burst (isolating `mode=1` vs. `mode=2`)*: 52 `-I/sw/<pkg>/include` dirs $\times$ 200 `#include`s and 65 `-L/sw/<pkg>/lib` dirs $\times$ 30 `-l<lib>` probes.
            3. **End-to-End Macrobenchmarks**:
              - Multi-header C++ compile + link (`g++` + `ld` with `<iostream>`, `<filesystem>`, `<openssl/ssl.h>`).
              - Real Autoconf `./configure` run (`bash` / `coreutils`) inside the `swctl` build sandbox.
              - Full `glibc-2.44` `MAKE` + `CHECK` in Fluffy (`mode=0,1,2`) vs. a flat-FHS (`/usr/{bin,include,lib}`) baseline build.
        - **13. Plan of Action — Getting From Here to There**:
          - **Phase 1 — Build `bench-fswc` Baseline Harness, Fix `swctl` SHM Persistence / Kill Marker & Strip `binutils`/`gcc` Headers**:
            1. Write the reproducible `bench-fswc` harness first and record pre-refactor numbers on the current 91-package `/sw` tree for an objective "before" baseline.
            2. *(Done in `swctl`)* Removed `touch /tmp/.fluffy_ns_sealed` / `chmod 0444` and wired a session-scoped `/dev/shm` `tmpfs` (bind-mounted into `$FLUFFY/dev/shm`) across chroot package builds.
            3. Delete `include/fluffy-cache.h` and all `fc_*` call sites from `sw/binutils-2.47-fluffy-source.patch` and `sw/gcc-16.2.0-fluffy-source.patch`, leaving minimal `glob(..., GLOB_ONLYDIR, ...)` patches.
          - **Phase 2 — Implement the Consolidated, Hardened `FSWC` Engine & `GLIBC_TUNABLES` in `glibc`**:
            1. Replace `posix/glob_fluffy_cache.h` with a single shared internal module across `ld.so` (`GLRO` seeded views), `libc.so` (`GL` dynamic multi-prefix table, `vfork`-safe `execvpe()`, `glob()`, optional VFS wrappers), and `libc.a`, wired to `GLIBC_TUNABLES=glibc.fswc.{mode,max_inodes}`.
            2. Implement SquashFS-gated dynamic multi-prefix discovery (zero `"/sw"` literals), iterative full-tree `(parent_id, basename)` + `(pkg_idx, dir_node_id)` indexing, per-UID `0700` `/dev/shm/.fswc-<uid>/` `0400` `MAP_SHARED` blobs + per-package subtree reuse, chroot-safe Git-style `statx(backing_file)` identity, and all strict POSIX/security invariants from (10).
          - **Phase 3 — Land Tier-1 (`make check`) & Tier-2 (`test-fswc`) Adversarial Test Suites**:
            1. Add `posix/tst-fswc-*.c` and `elf/tst-fswc-*.c` to `sw/glibc-2.44-fluffy-test.patch` and build the standalone `test-fswc` pathological SquashFS / live-mount / UID-drop / chroot differential torture runner; require 100% pass across `mode={0,1,2}`.
          - **Phase 4 — Run the `bench-fswc` A/B/C Gate (`mode=0` vs. `mode=1` vs. `mode=2`)**:
            1. Execute the full Tier 0–3 lifecycle, microbenchmark, and macrobenchmark suite from (12); set the default `glibc.fswc.mode` (`1` vs. `2`) based on measured compiler/linker/`configure`/build wins vs. complexity.
          - **Phase 5 — Full Toolchain Rebuild & Regression Verification**:
            1. Rebuild `glibc`, `binutils`, and `gcc` via `swctl build`, pass all downstream `CHECK()` suites, verify `check-toolchain`, and compare end-to-end build times against the Phase 1 and flat-FHS baselines.

5. **Hermetic, Unprivileged Builds & Unified Tooling (`swctl build`, `swctl install`)**
   - **Developer Environment Convention (`direnv` & `sudo --preserve-env`)**:
     - Developer environments export `CROSS=1` and `FLUFFY` variables via `direnv`.
     - When invoking `swctl` under `sudo`, commands should use `sudo --preserve-env=CROSS,FLUFFY ./swctl build <pkg>` (or `swctl install <pkg>`) to preserve the caller's environment rather than prefixing `CROSS=1` manually.
   - **Folding `create` into `swctl` (`swctl build`)**:
     - All package building and recipe orchestration is unified under `swctl` (`swctl build <pkg...>` and `swctl install <pkg...>`), auto-prefixing `sw/` so package names are first-class identifiers (`swctl build glibc`, `swctl install gcc`).
     - **Registration as a Build Byproduct**: With `swctl build`, registration ceases to exist as a separate manual step. Upon completing `SQUASHFS`, `swctl build` automatically calculates the image SHA-256 checksum (`X-fluffy.image-checksum`), writes the `/sw/.build/fstab` entry (target `/sw/<pkg>`, `X-fluffy.needs`, `X-fluffy.recipe-checksum`, `X-fluffy.image-checksum`), and signs the `/sw/.build/fstab` manifest file in a single atomic transaction. The fstab file itself is the sole signed artifact.
   - **Recursive Recipe DAG Resolution, Direct Build Input Hashing (`format_recipe_mime`), Early Cutoff & Fixed-Point Cyclic Build Convergence**:
     - `swctl build <pkg...>` recursively walks the recipe files in `sw/` across `ON`, `NEEDS`, and `BUILD_NEEDS`.
     - **In-Memory Direct Build Input Hash (`format_recipe_mime`)**: Without mutating git-tracked `sw/<pkg>` files on disk, `format_recipe_mime` streams the raw `sw/<pkg>` recipe file, any sourced helper files (`pkg_includes`), and sorted `<dep>:<X-fluffy.image-checksum>` pairs for **direct** `$ON` + `BUILD_NEEDS` dependencies (`pkg_bneeds`) through `sha256sum`.
     - **Early Cutoff & Image Checksum Reuse**: Rebuilding a byte-identical `.squashfs` preserves `X-fluffy.image-checksum`. `SQUASHFS()` writes to `<pkg>-<ver>.squashfs.new`, and `register_entry` compares its SHA-256 against the existing `X-fluffy.image-checksum` in `/sw/.build/fstab`. If the newly built `.squashfs` is identical, `register_entry` preserves `X-fluffy.image-checksum` and updates `X-fluffy.recipe-checksum`, stopping the downstream rebuild cascade immediately.
     - **TODO: Self-Hosting Build Cycles (`ON=fluffy-build`, `glibc` ↔ `gcc`) & Fixed-Point Convergence**:
       - While runtime dependencies (`NEEDS` in `swctl install`) must form a strict DAG, a self-hosting native build system (`ON=fluffy-build`) inherently contains build-time cycles (Strongly Connected Components / SCCs): `glibc` needs `gcc` in `BUILD_NEEDS`, `gcc` needs `glibc` in `NEEDS`, and every `ON=fluffy-build` package depends on `fluffy-build` (including the packages that make up `fluffy-build`).
       - Because Fluffy combines bitwise reproducible builds with image checksum preservation (`register_entry`), `swctl build` can resolve cyclic build SCCs by iterating to a **cryptographic fixed point**:
         1. On Pass 1 of a cyclic SCC (e.g. `glibc` → `gcc`), `glibc` builds using the currently registered `gcc` ($G_0$), producing $C_1$, and `gcc` rebuilds against $C_1$.
         2. If `gcc` produces a byte-identical `.squashfs`, `register_entry` preserves $G_0$, so `glibc`'s `current_recipe_chk` immediately matches its `recorded_recipe_chk` (`X-fluffy.recipe-checksum`) and the cycle terminates in 1 pass.
         3. If `gcc`'s binary output changed ($G_1 \neq G_0$), `glibc`'s `current_recipe_chk` (which hashes $G_1$) differs from its `recorded_recipe_chk` (which hashed $G_0$), so Pass 2 rebuilds `glibc` with $G_1$ (and if needed, `gcc` with $C_2$) until every `X-fluffy.image-checksum` is preserved around the cycle and **every package in `/sw/.build/fstab` simultaneously satisfies `recorded_recipe_chk == current_recipe_chk`**.
         4. **Bounded Convergence Guard**: If a cyclic SCC fails to reach a fixed point within a small bounded number of passes (e.g. `MAX_CYCLE_PASSES=3`, analogous to GCC's 3-stage bootstrap comparison), `swctl build` fails with a fatal diagnostic naming the non-converging package(s) whose `.squashfs` output is failing to stabilize (automatically catching any build nondeterminism).
   - **Unified `BUILD_NEEDS` Architecture & Strict Isolation (Build-Time vs. Runtime)**:
     - Dependency declarations across all recipes are consolidated into a clean two-tier model: `NEEDS` (runtime dependencies) and `BUILD_NEEDS` (all tools required across `MAKE`, `CHECK`, and `INSTALL`).
     - **Strict Sandbox Mount Isolation (`BUILD_NEEDS` Only)**:
       - `NEEDS` represents runtime-only dependencies of the packaged software. It is **never mounted** during `MAKE`, `CHECK`, or `INSTALL`.
       - Build phases only mount `BUILD_NEEDS` (and the runtime dependencies those build tools themselves need to execute). Leaking runtime `NEEDS` into the build sandbox is eliminated, ensuring that a package cannot silently link against or inspect undeclared build requirements.
   - **Sound Early Cutoff via Direct `BUILD_NEEDS` + `$ON` Image Hashing (No Dependency Trimming)**:
     - `X-fluffy.recipe-checksum` locks strictly against the recipe definition, any included files, and the image checksums (`X-fluffy.image-checksum`) of **direct** `BUILD_NEEDS` + `$ON` images only.
     - **No `NEEDS` in Recipe Checksum**: A runtime-only dependency change (e.g. updating `ca-certificates` or `shadow`) never alters compiled build outputs and must never trigger a rebuild.
     - **No Transitive Expansion & No Transitive Trimming**: To enable true early cutoff, the recipe checksum does not expand transitive dependencies—and recipes must **never** trim direct dependencies just because another dependency happens to pull them in transitively. If an upstream dependency $Z$ changes, but intermediate package $Y \in \text{BUILD\_NEEDS}$ rebuilds to an identical squashfs image, downstream package $X$ skips recompilation entirely; therefore, if $X$ directly depends on $Z$, $X$ must list $Z$ explicitly in its own immediate dependencies so changes to $Z$ are tracked accurately for $X$.
   - **Multipart MIME Serialization for Recipe Checksums (`source X`)**:
     - Recipes execute as plain, untouched Bash at runtime (`source "$inc"` is just `builtin source`).
     - For modification detection and recipe checksumming, `swctl` serializes the recipe, all sourced snippets, and direct image checksums into a canonical multipart MIME envelope (RFC 2046) with explicit boundaries, preventing ad-hoc delimiter collisions and providing an inspectable, self-contained record of the build recipe inputs.
   - **Declarative Direct Dependency Contract (The Recipe Honor System)**:
     - As in Arch (`makedepends`), Debian (`Build-Depends`), and Alpine (`makedepends`), dependency declaration is fundamentally a declarative recipe contract.
     - If package $X$ directly consumes APIs, headers, tools, or libraries from package $Y$, the recipe author declares $Y$ in `BUILD_NEEDS`.
     - If package $X$ only uses $Y$, and $Y` internally uses $Z$ as a transitive implementation detail, $X$ does *not* declare $Z$.
     - By keeping dependency declarations strictly direct, early cutoff functions as intended: if $Z$ changes, $Y$ rebuilds; if $Y$ produces an identical squashfs image, $X$ skips recompilation entirely.
     - Sandbox isolation (never mounting runtime `NEEDS` during `MAKE`) naturally prevents the most common class of undeclared dependencies without requiring complex language-specific source scanners or kernel tracing.
   - **Explicit `CROSS=1` Bootstrap vs. Native Self-Hosting (`ON=fluffy-build`)**:
      - **Runtime `NEEDS=(...)` is Strictly Invariant**:
        - A final package's runtime contract never varies between bootstrap and native modes. `NEEDS=(...)` is always 100% composed of final packages (`glibc`, `attr`, `acl`, `libxcrypt`, etc.) from day one.
        - Neither `-pass1` nor `-pass2` packages ever appear in a final package's runtime `NEEDS` or in `X-fluffy.needs` in `/sw/.build/fstab`.
      - **Explicit `CROSS=1` Build-Tool Branching**:
        - Scaffolding (`ON`, `BUILD_NEEDS`) branches cleanly on `if test -v CROSS`.
        - The default mode is native (`ON=fluffy-build`), avoiding any runtime filesystem/fstab autodetection overhead.
        - Cross-building during initial bootstrap is summoned explicitly via `CROSS=1` (e.g. `sudo --preserve-env=FLUFFY,CROSS ./swctl build <pkg>`), switching `$ON` to `cross-build` and `BUILD_NEEDS` to `*-pass1` / `gcc-pass2`.
      - **Zero Git Churn & Automatic Invalidation**:
        - Keeping both scaffolding closures inside the same recipe file avoids branch juggling or local file edits.
        - Because `format_recipe_mime` hashes `$ON` and the image checksums of direct build dependencies, `swctl build` automatically knows when a package was built against bootstrap tools vs native tools, enabling seamless fixed-point convergence once `fluffy-build` is assembled.
   - **Distro-as-Build-Environment, Remote Repositories (`/etc/sw/repositories`), Trust Store (`/etc/sw/*.pub`) & Parallel Bottle Prefetch (`curl -Z`)**:
     - **Core Philosophy — A Distribution That Is Secretly a Build Environment**:
       - Fluffy does not have a separate "binary package manager" vs. "source build system". A Fluffy installation is simply a `swctl build` environment backed by signed binary bottle caches, and the installed system universe is managed by building/mounting a top-level `world` (or `local`) pseudopackage.
       - Because every `fstab` entry records `X-fluffy.recipe-checksum` (the SHA-256 of the RFC 2046 multipart MIME envelope containing the recipe, any sourced includes, and sorted `<dep>:<X-fluffy.image-checksum>` pairs across direct `BUILD_NEEDS` + `$ON` images), changing any recipe, include, or direct build dependency automatically invalidates `X-fluffy.recipe-checksum` downstream while preserving early cutoff across untouched dependencies.
     - **Trust Store (`/etc/sw/*.pub`) & Repository Sources (`/etc/sw/repositories`)**:
       - `/etc/sw/*.pub` (overlaid on `/sw/*/etc/sw/*.pub`) holds trusted `signify` public keys.
       - `/etc/sw/repositories` configures one or more remote repository URLs serving signed `fstab` manifests and `.squashfs` bottles (supporting multiple merged repository sources).
     - **Upfront DAG Resolution & Parallel Bottle Prefetching via `curl --parallel` (`-Z`)**:
       - When `swctl build <pkg...>` calculates the topological dependency closure (`${order[@]}`), it can first fetch and verify the remote signed `fstab` manifest(s) from `/etc/sw/repositories`.
       - Walking `${order[@]}` in topological order in memory, `swctl` compares each package's computed `current_recipe_chk` against both the local `/sw/.build/fstab` and the remote `fstab`(s) (adopting the remote `X-fluffy.image-checksum` whenever a remote entry matches `current_recipe_chk`).
       - Before running a single local build, `swctl` knows the exact set of missing or outdated packages in the closure that have valid prebuilt `.squashfs` bottles upstream, downloads **all** of them concurrently in one shot via `curl --parallel` (`-Z`), verifies the signed manifest against `/etc/sw/*.pub` and compares image SHA-256 hashes, updates `/sw/.build/fstab`, and then kicks off local builds only for the remaining locally-modified packages.
     - **Binary Bottles (GitHub Packages / GHCR / Download Mirrors)**:
       - `ON=host-build` and `ON=cross-build` recipes (`*-pass1`, `*-pass2`) are host-dependent and stored as **private** packages solely for CI reuse (avoiding cache eviction), whereas `ON=fluffy-build` packages are **public** portable bottles (which have free, unlimited storage and bandwidth on `ghcr.io`).
       - **OCI Artifact Layout on `ghcr.io` (Homebrew-Style Arbitrary Files)**:
         - Packages are stored on `ghcr.io` as standard OCI Artifacts: **1 package per `.squashfs`** and **1 package for the `fstab` manifest**, scoped per branch (e.g., tagged by branch and overwritten when changed).
         - Because `ghcr.io` stores each uploaded file as a content-addressed blob whose layer descriptor in the ~1 KB OCI manifest JSON embeds its exact `sha256` digest (`layers[0].digest`), `swctl` can query a package's remote `.squashfs` `sha256` checksum via a lightweight manifest fetch (`GET /v2/<owner>/<pkg>/manifests/<tag>`) independently of downloading the `.squashfs` blob itself, and `ghcr.io` automatically deduplicates identical blobs on the backend.
     - **CI/CD & `swctl` Registry Workflow (`fstab` Sync, Lazy Prerequisite Fetch & Atomic Publish)**:
       - **1. Fetch Latest Branch `fstab`**:
         - At the start of a run, `swctl` downloads the latest signed `fstab` package for the current branch (keeping a copy of the pre-build `fstab` to diff against at publish time).
       - **2. Existence-Verified `UP-TO-DATE` Check (`build` vs. `install` Semantics)**:
         - Walking `plan_pkgs` in topological `order`, `swctl build` computes `current_recipe_chk` (`format_recipe_mime`, which hashes the recipe, sourced includes, and direct `ON` + `BUILD_NEEDS` `X-fluffy.image-checksum` values) and compares it against `X-fluffy.recipe-checksum` in `fstab`.
         - **Build vs. Install**: During `swctl build`, a package's `.squashfs` file does *not* need to sit on local disk if nothing is mounting it, **provided** the `.squashfs` matching `X-fluffy.image-checksum` is verified to exist (either locally in `/sw/` or in its corresponding `ghcr.io` package manifest).
         - By verifying that `X-fluffy.image-checksum` matches the sole image digest in `ghcr.io`'s manifest for every `UP-TO-DATE` entry in `fstab`, `swctl build` guarantees that a complete, self-consistent set of `.squashfs` images exists in the registry for `swctl install`.
         - On a cache miss (`recorded_recipe_chk != current_recipe_chk`, or the `.squashfs` is absent/mismatched both locally and in `ghcr.io`), `swctl` rebuilds the package (recursively fetching or rebuilding its dependencies).
       - **3. Up-Front `ensure_prerequisites` (Outside `CLONE_NEWNET` Lockdown)**:
         - Because `lockdown_exec` immediately enters an air-gapped network namespace (`CLONE_NEWNET`) and the `FLUFFY` chroot mounts `$ON` before executing inside the sandbox, all network downloads for a package build happen up-front on the host via `ensure_prerequisites`:
           1. **Recursive `.squashfs` Dependencies (`$ON` + `BUILD_NEEDS` + Transitive `X-fluffy.needs`)**: Walks the mount dependency closure via `dfs`. For any required `.squashfs` not already present and checksum-verified in `/sw/`, `swctl` downloads the blob from `ghcr.io` and verifies its `sha256` against `X-fluffy.image-checksum`. (This same helper powers lazy `.squashfs` fetching for `swctl install <pkg...>`).
           2. **Source `ARCHIVES`**: Downloads and verifies all `ARCHIVES[@]` tarballs/files into `work/archives/`.
         - Consolidating both `.squashfs` and `ARCHIVES` fetches into `ensure_prerequisites` keeps `lockdown_exec` strictly offline, avoids needing `ghcr.io` credentials or CA certs inside the chroot, and makes a future air-gapped/offline prefetch mode (`swctl fetch`) trivial.
       - **4. Atomic Two-Phase Publish (Changed `.squashfs` Images First, `fstab` Last)**:
         - Upon build completion, comparing the new `/sw/.build/fstab` against the pre-build `fstab` (or remote manifest digests) identifies every package whose `X-fluffy.image-checksum` changed.
         - CI first uploads all changed `.squashfs` images to their corresponding branch packages in `ghcr.io` (and prunes untagged versions on private packages to avoid storage quota bloat).
         - Only after **all** changed `.squashfs` uploads succeed is the newly signed `fstab` uploaded to its branch package—acting as an atomic commit pointer so consumers never observe an `fstab` referencing an unuploaded `.squashfs`.
       - **CI Pipeline via `sw/world` Pseudopackage (`swctl build world`)**:
         - `sw/world` is a standard pseudopackage (`ON=host-build`, `VERSION=1.0`, `NEEDS=(...)` with no build steps, producing `world-1.0.squashfs` and identical in all other ways to any other package) that explicitly lists every final package on the Fluffy image according to Chapter 8 of Linux From Scratch (untrimmed).
         - With caching, prerequisite fetching, and publishing integrated into `swctl`, the entire CI pipeline on push to `main` is simply `swctl build world` (and installing the full base system is `swctl install world`).
         - **Dev (`SNAPSHOT`) vs. Release Channels & Immutable Release Versions (`fluffy0`, `fluffy1`)**:
           - Dev/main builds and tagged releases are separated Maven-style (`SNAPSHOT` vs. release manifests/tags) so experimental rebuilds don't overwrite release bottles.
           - **Release Immutability Guard & Package Revisions**: On release builds, publishing over any existing package version is a hard error. Before publishing *any* artifact, CI checks the entire publish set and fails immediately if any rebuilt package (`X-fluffy.recipe-checksum` changed) still has a version/filename that already exists in the release registry—which always means a version bump was forgotten.
           - To support recipe/patch updates without changing upstream `$VERSION` (used in `ARCHIVES` URLs), recipes support Debian/Ubuntu-style package revisions (`fluffy0`, `fluffy1`, etc., e.g. `<pkg>-<version>-fluffy0.squashfs`).
         - **Debian-Style Reproducible Builds & Early Cutoff (Avoiding Mass Rebuild Cascades)**:
           - In purely input-addressed systems (Nix/Guix), changing an upstream recipe like `glibc` alters input hashes and forces blind rebuild cascades across every downstream package, even when compiled output binaries would be bit-for-bit identical.
           - By enforcing Debian-style bitwise reproducible builds (`SOURCE_DATE_EPOCH=0`, deterministic squashfs creation, normalized timestamps and filesystem ordering), Fluffy employs an **early cutoff** strategy directly in `swctl`: when an upstream dependency changes and a downstream package is rebuilt, `register_entry` compares `.squashfs.new` against the existing `X-fluffy.image-checksum`; if they are identical, it preserves `X-fluffy.image-checksum` so all further downstream packages see an unchanged `format_recipe_mime` hash and the rebuild cascade stops immediately.
         - **SquashFS vs. Object-Level Hashing**: Unlike OSTree or Git, which hash individual uncompressed files, Fluffy hashes the `.squashfs` image directly with SHA-256. A change to `zstd` compression heuristics or `mksquashfs` block layout will change the `.squashfs` SHA-256 even if uncompressed files are identical. However, because `zstd` and `squashfs-tools` belong to `cross-build` / `fluffy-build`, any change to the compression toolchain automatically triggers a system rebuild anyway—so within a stable toolchain generation, deterministic `mksquashfs` is completely sufficient without needing an extra object-hashing layer.
     - **Native OS Detection (`/etc/os-release`) & Local User Packages (`sw/local`)**:
       - Using `/etc/os-release` (`ID=fluffy`) and `$ON`, `swctl` knows when it is running natively on Fluffy Linux vs. bootstrapping from a foreign host, ensuring users on Fluffy never re-trigger `pass1`/`pass2` cross-compilation because `ON=fluffy-build` packages are self-contained.
       - Users can define local packages and even a `sw/local` pseudopackage (`NEEDS=(world userpkg1 userpkg2)`), where `world` resolves from signed upstream bottles while `userpkg1` and `userpkg2` build locally.
     - **Setuid Embedded-Script `swctl` Binary, `build` Group & User vs. System Squashfs Separation**:
       - Because the Linux kernel ignores the `setuid` bit on `#!` scripts, `swctl` can be packaged as a dedicated setuid binary built from a special-purpose `bash` (with the `swctl` script embedded in `.rodata` and `-c` / interactive flags disabled) or a small C wrapper.
       - A `build` group and separate storage/namespace boundaries between system squashfs images (requiring `CAP_SYS_ADMIN` / system install privileges) and user-built squashfs images allow unprivileged users to run `swctl build` out of their own home-directory recipe clones (and even drop into a shell with a custom `fstab` software set) without granting them unrestricted root access to the system.
   - **Host vs. Native Detection via `$FLUFFY` & `/sw` Bind-Mount Normalization**:

6. **The Dual-Manifest Model (`/sw/.build/fstab` vs. `/etc/fluffy/fstab`)**
   - **1. `/sw/.build/fstab` — The Available Package Index**:
     - Records every built or downloaded `.squashfs` image available in `/sw/` (including `*-pass1`, `*-pass2`, build-only libraries, and uninstalled packages), formatted as a self-signed `fstab(5)` file:
       ```fstab
       # fluffy.signature=<base64-ed25519-signature-over-remaining-lines>
       /sw/foo-1.23.squashfs /sw/foo squashfs X-mount.mkdir,X-fluffy.image-checksum=<sha256>,X-fluffy.needs="bar,baz",X-fluffy.recipe-checksum=<sha256> 0 0
       /sw/bar-2.0.squashfs /sw/bar squashfs X-mount.mkdir,X-fluffy.image-checksum=<sha256>,X-fluffy.needs="bar,baz",X-fluffy.recipe-checksum=<sha256> 0 0
       ```
   - **2. `/etc/fluffy/fstab` — The Installed System Manifest**:
     - Records the exact topological set of `.squashfs` packages actually **installed** on the system (written/updated when `swctl install` installs packages into the system).
     - Free of duplicate mountpoint collisions (`*-pass1` vs. final packages) and build-only clutter.
     - Because it lives under `/etc`, Btrfs snapshots of `/etc` automatically snapshot and roll back the installed software state alongside system configuration.
   - **Why this design is so powerful**:
     - **Directly mountable by standard tools**: `libmount`, `mount -a -T`, and `systemd-fstab-generator` treat `#` as a comment line by default. No stripping or pre-processing is needed to use either `fstab` as a mount table.
     - **Standard Userspace Options (`X-appname.option`)**: In accordance with the `mount(8)` and `libmount` standard specification, all user-space / application-specific mount options are prefixed with `X-<appname>.<option>` without leading hyphens:
       - `X-fluffy.image-checksum=<sha256>`: package image SHA-256 checksum (preserved across rebuilds when the new `.squashfs` is byte-identical).
       - `X-fluffy.needs="<dep1>,<dep2>"`: comma-separated list of runtime dependency packages.
       - `X-fluffy.recipe-checksum=<sha256>`: sha256 checksum of the multipart MIME envelope (`format_recipe_mime`) containing `sw/<pkg>`, any sourced includes, and the sorted `<dep>:<X-fluffy.image-checksum>` pairs of its direct `$ON` + `BUILD_NEEDS` dependencies, recording both recipe and dependency provenance without mutating recipe files on disk.
        - `X-fluffy.cflags="..."` / `X-fluffy.ldflags="..."`: Package compile and link metadata declared via `HAS_CFLAGS=` and `HAS_LDFLAGS=` in library recipes (e.g. `HAS_LDFLAGS=-lzstd` in `sw/zstd`, `HAS_LDFLAGS="-lssl -lcrypto"` in `sw/openssl`). During `lockdown_exec`, `swctl` inspects `X-fluffy.cflags` and `X-fluffy.ldflags` for every dependency in `BUILD_NEEDS` and automatically exports `<DEP>_CFLAGS`, `<DEP>_LDFLAGS`, and `<DEP>_LIBS` (defaulting `<DEP>_CFLAGS` to `" "` when only `X-fluffy.ldflags` is set so Autoconf `pkg.m4` accepts the override without `pkg-config`), so consuming a library never requires manually specifying `pkg-config`, `CFLAGS`, `LDFLAGS`, or `LIBS`.
     - **Compact Ed25519 signatures**: Raw Ed25519 signatures are exactly 64 bytes (88 base64 characters; 100 characters in OpenBSD signify format)—no massive ASCII armor blocks or multi-kilobyte RSA blobs.
     - **Single-file verification**: The signature on line 1 covers lines 2 through EOF. Verifying line 1 against the trusted public key validates the entire repository index in one shot (all package filenames, mountpoints, squashfs image checksums, and dependency closures) without needing separate detached `.sig` files or per-package signatures:
       ```bash
       sig=$(sed -n '1s/^# fluffy\.signature=//p' /sw/.build/fstab)
       # Verify lines 2..EOF against the embedded signature
       ```
     - **Trust Root / Bootstrap**: The distro release signing public key cannot live inside a package squashfs (which would be circular). Instead, it lives alongside the manifest at `/sw/.build/release.pub` (or embedded in the bootstrap script / `/init`), providing the root of trust from day one.
     - **In-process parsing & mounting**: `libmount` (`<libmount/libmount.h>` called via `ctypes.sh`) parses the manifest, resolves dependencies, checks options (`X-mount.mkdir`, `X-fluffy.image-checksum`, `X-fluffy.needs`, `X-fluffy.recipe-checksum`), and mounts the squashfs images directly in-process.

7. **Runtime State Separation (`/var/<pkg>`) & Dynamic Users**
   - Packages in `/sw/<pkg>` are strictly immutable, code/asset-only squashfs images packed with `-all-root` (everything owned by `root:root`).
   - Packages that require persistent mutable runtime state (databases, spools, caches) store it in `/var/<pkg>` (e.g. `/var/locate`, `/var/systemd`).
   - To avoid coordinating hardcoded static UIDs across package definitions at build time, runtime services run under dynamic users (e.g. `DynamicUser=yes` with `StateDirectory=` under systemd, or `sysusers.d` allocation at install/boot).
   - This ensures `/var/<pkg>` directories are mode `0700` and accessible only to that specific package's service, with zero UID baked into the package image itself.

8. **Pseudopackages (`*-build`, `world`), Manifest-Driven Resolution & Companion Mount Engine**
   - **Pseudopackages (Packages with `NEEDS=(...)` Only and Uniform `.squashfs` Representation)**:
     - A pseudopackage is simply a package with no build steps (`MAKE()`, `CHECK()`, or `INSTALL()`) and identical in all other ways to any other package: it produces a `.squashfs` image, is registered in `/sw/.build/fstab` with its `X-fluffy.image-checksum`, `X-fluffy.needs`, and `X-fluffy.recipe-checksum`, and requires zero special-case branches in `swctl`.
     - Core pseudopackages encapsulate builder profiles and target system sets:
       - `sw/host-build`: `NEEDS=()` (pure host compilation with no `/sw` mounts).
       - `sw/cross-build`: `NEEDS=(bzip2-pass1 coreutils-pass1 ctypes-sh-pass1 curl-pass1 gzip-pass1 signify-pass1 squashfs-tools-pass1 tar-pass1 util-linux-pass1 xz-pass1)` (the top-level scaffold needed to run `swctl build` and `PREPARE` inside chroot; transitive dependencies like `bash-pass1`, `glibc-pass1`, `ncurses-pass1`, `openssl-pass1`, `ca-certificates`, `zlib-pass1`, and `zstd-pass1` are resolved automatically).
       - `sw/fluffy-build`: `NEEDS=(bzip2 coreutils ctypes-sh curl gzip signify squashfs-tools tar util-linux xz zstd)` (the final native Fluffy self-hosting environment).
       - `sw/world`: `ON=host-build`, `VERSION=1.0`, `NEEDS=(...)` explicitly listing every final package on the Fluffy system image according to Chapter 8 of Linux From Scratch (untrimmed), enabling `swctl build world` in CI and `swctl install world` on target systems.
     - Regular package definitions reference builder profiles directly via `$ON`, which defaults to `fluffy-build`. `swctl` transitively resolves the builder profile's `NEEDS` to set up the build environment for each stage before mounting package-specific requirements.
   - **Builder Harness Isolation (`/sw/.build/<pkg>`) & Rebuilt Build Dependencies**:
     - **TODO: Post-Boot Priority: Implement `/sw/.build/<pkg>` Harness Isolation**:
       - As observed during Chapter 8 (`zstd` discovering `zlib` and `xz` from `cross-build`), mounting builder tools directly in `/sw/*` allows configure checks to accidentally discover and link against build-harness libraries.
       - Immediately once the system boots natively, rebuild the build harness under `/sw/.build/<pkg>` and isolate compiler/linker include/lib search strictly to `/sw/*` (since `.build` starts with `.`, standard `/sw/*` wildcard globs automatically skip `/sw/.build` without needing a separate top-level `/builder` directory on `/`).
     - **Problem with Accidental Linkage**: Packages being built can accidentally discover and link against libraries or headers provided by the builder harness (`$ON` profiles like `cross-build` or `fluffy-build`). Post-install closure verification is finicky and brittle; statically linking the entire build harness runs counter to LFS and Glibc design.
     - **Isolation via Dedicated `/sw/.build/<pkg>` Prefix**:
       - Packages belonging to the build toolkit are rebuilt specifically under a `/sw/.build/<pkg>` prefix rather than `/sw/<pkg>`, and mounted under `/sw/.build/<pkg>`, keeping them completely invisible to `/sw/*` globs.
     - **Magic Detection via Self-Referential Circular Dependency (`ON=<self>`)**:
       - If a builder profile or recipe (e.g. `sw/foo-builder`) declares `ON=foo-builder` (a synthetic self-referential / circular dependency), the build engine magically detects that this package and all of its transitive dependencies are intended for `/sw/.build/<pkg>`.
       - **Unhardcoding Paths**: Build staging and prefixes transition from hardcoded `/sw` to dynamic root paths (e.g. `$PKG_ROOT` or `$BUILD_PREFIX` resolving to `/sw/.build` vs `/sw`), allowing recipes and build logic to target `/sw/.build` cleanly without duplicating recipe definitions.
     - **Clean Path Semantics**:
       - Environment path execution is straightforward:
         ```bash
         PATH='/sw/.build/*/bin:/sw/*/bin'
         ```
       - Compilers, dynamic linkers, and include preprocessors only scan `/sw/*/{include,lib}` for dependencies. Because the builder harness lives under `/sw/.build/*` (skipped by `/sw/*` globs), packages can invoke build tools from `/sw/.build/*/bin` without ever accidentally resolving or linking against build-time harness libraries.
   - **Strict Circular Dependency Detection & Topological Mount Order**:
     - Before performing any mount operations, `swctl install` executes a recursive depth-first search (DFS) tracking node states (0 = unvisited, 1 = visiting/active in-stack, 2 = visited/completed).
     - Any circular dependency (direct or transitive) is rejected immediately with a fatal diagnostic displaying the exact dependency cycle path before touching mounts or namespaces.
     - Dependencies are gathered in DFS post-order, producing a strictly topological mount order where every dependency is mounted prior to the packages that depend on it.
   - **Manifest-Driven Resolution via `/sw/.build/fstab`**:
     - `swctl` stops scanning filesystem glob patterns (`/sw/"$dep"-[0-9]*.squashfs`).
     - `/sw/.build/fstab` is the single source of truth for all built squashfs images, mount targets, package image checksums (`X-fluffy.image-checksum`), transitive requirements (`X-fluffy.needs="dep1,dep2"`), and build recipe hashes (`X-fluffy.recipe-checksum="<sha256>"`).
     - After `SQUASHFS` completes, the newly created image is recorded into `/sw/.build/fstab` via `libmount`:
       - Newly built packages append a line.
       - Rebuilt packages report updates in-place for that exact package entry.
   - **Unified Package Manager & Build Tool (`swctl`)**:
     - All mount, unmount, loop device ioctl, namespace preparation, dependency resolution, build orchestration, and `fstab` manipulation logic is unified in `swctl`.
     - `swctl` exposes two primary commands (`swctl build <pkg...>` and `swctl install <pkg...>`):
       - Resolving build and runtime dependency DAGs and detecting circular references.
       - Setting up the outer harness mounts for `$ON`.
       - Cleaning `/sw` inside `lockdown` and mounting strictly the phase dependency closure.
       - Upserting entries into `/sw/.build/fstab` on packaging completion (automatically calculating mount target `/sw/<pkg>`, sourcing recipe `sw/<pkg>` for `NEEDS`, hashing recipe for `X-fluffy.recipe-checksum`, computing image SHA-256 for `X-fluffy.image-checksum`, and signing the manifest with release keys).
     - **Potential Simplification: Eliding `free` / `mnt_free_*` / `mnt_unref_*` Calls**:
       - Because `( ... )` subshells and `$( ... )` command substitutions in Bash fork separate child processes whose virtual address spaces are torn down by the kernel on exit—and none of `libmount`'s `mnt_free_*` / `mnt_unref_*` functions have external side effects—explicit FFI deallocation (`cleanup` + `trap cleanup EXIT`, `free`, `mnt_free_table`, `mnt_free_iter`, `mnt_free_context`, `mnt_unref_fs`) can be dropped in `swctl` (at least outside loops, or entirely given the small bounded iteration count), saving ~18–22 lines of code.
     - **Runtime / System Package Operations**:
       - Resolving installed packages from `/sw/.build/fstab` ("available") into `/etc/fluffy/fstab` ("installed") and mounting them for system boot and user sessions.
      - **Adversarial Review & Hardening of `swctl` (Completed)**:
        - Replaced all `eval` output-assignment sinks (`fs_str`, `get_fs_opt`, `find_fs_by_pkg`) with Bash namerefs (`local -n`), fixing both command-injection risks and backslash corruption (`\040` -> `040`) on multi-flag `HAS_CFLAGS` / `HAS_LDFLAGS`.
        - Enforced `signify` Ed25519 verification (`verify_fstab_signature`) in `reload_fstab` before `libmount` parses `$FSTAB`, and atomic same-directory temp replacement in `sign_and_save_fstab`.
        - Overmounted `/sw/.build` (`sign.sec`, `toushun.sec`, `keys`, `fstab`) with an ephemeral read-only `tmpfs` inside unprivileged `lockdown_exec` phases (`MAKE`, `CHECK`, `INSTALL`), permanently dropped saved-UID/GID `0` before `PREPARE` network `curl` + `tar --no-same-owner --no-same-permissions`, added `resolve_in_chroot` symlink-escape and `validate_pkg_name` guards, fixed `src_matches_pkg` prefix collisions and version-bump `UP-TO-DATE` checks, removed `/tmp/.fluffy_ns_sealed`, and wired a session-scoped `/dev/shm` `tmpfs` across chroot builds.

9. **Garbage Collection & Retention Model (`prune`)**
   - **Git-Style Lazy Garbage Collection**:
     - Upgrades and package removals do not delete active `.squashfs` files immediately. They update `/etc/fluffy/fstab` (and `/sw/.build/fstab`) and rebind mounts in new namespaces.
     - Running processes continue to execute against old `.squashfs` images safely in their private mount namespaces.
   - **Pruning Policy (`<pkgmgr> prune`)**:
     - Scans `/sw/*.squashfs` periodically (cron/timer) or manually.
     - An image is a candidate for deletion if:
       1. It is no longer referenced by `/etc/fluffy/fstab` or `/sw/.build/fstab`.
       2. It is not currently held open/mounted in any running mount namespace (verified via `/proc/*/mountinfo`).
       3. Optional retention window: unreferenced, unmounted images can be kept for a grace period (e.g. 30 days) to allow instant rollback to older generations.
   - **Btrfs Snapshot Protection**:
     - System generations and `/etc` are preserved via Btrfs snapshots.
     - Standard Linux POSIX file semantics ensure that even if an image is unlinked while still open in a dying namespace, its disk blocks remain allocated until the last referencing process exits.

10. **Boot Architecture: GRUB Direct-Mount, Kernel Squashfs & Static `/init`**
    - **Kernel & Modules in `/sw/linux`**:
      - The Linux kernel and its loadable kernel modules are packaged together in `/sw/linux-<version>.squashfs` and mounted at `/sw/linux`.
      - Modules live in `/sw/linux/lib/modules/<kernel-version>/`.
    - **GRUB Squashfs & Btrfs Native Direct-Mount**:
      - GRUB natively includes filesystem drivers for both Btrfs and Squashfs (`insmod btrfs`, `insmod squash4`).
      - GRUB mounts the Btrfs root filesystem, locates the active kernel squashfs (`/sw/linux-*.squashfs`), and mounts/reads the squashfs image directly on the fly.
      - GRUB streams the kernel (`vmlinuz`) directly into RAM from the `.squashfs` image without requiring any intermediate unpacking on disk or an initramfs.
    - **Zero-Initramfs Boot via Tiny Static `/init` on Btrfs Root**:
      - With `CONFIG_DEVTMPFS_MOUNT=y`, Btrfs, SquashFS (`CONFIG_SQUASHFS_ZSTD=y`), and Loop device support built into `vmlinuz`, the kernel mounts the Btrfs root filesystem directly and starts `/init` (a tiny statically linked C binary on `/`).
      - **Early Boot Sequence (Prior to `systemd`)**:
        1. Kernel mounts Btrfs `/` and `devtmpfs` on `/dev`, then executes static `/init` as PID 1.
        2. `/init` mounts `/etc/fstab` (if needed prior to systemd) and `/etc/fluffy/fstab` (the installed system squashfs mount table, loop-mounting each `/sw/<pkg>-<ver>.squashfs` onto `/sw/<pkg>`).
        3. `/init` calls `execv("/sw/systemd/lib/systemd/systemd", argv)` to hand off PID 1 to `systemd`.
    - **Zero-Hack PID 1 Startup**:
      - `systemd` starts with all dynamic libraries (`/sw/*/lib`), unit files (`/sw/*/lib/systemd/system`), and binaries (`/sw/*/bin`) already mounted and available in `/proc/1/ns/mnt`.
      - Kernel modules load directly from `/sw/linux/lib/modules/<version>`.
      - Zero package hooks run during boot; the system starts immediately with full consistency.

11. **Network Independence, `curl` & TLS Trust Store (`ca-certificates`, `openssl`, `curl`)**
    - **Base HTTP Client (`curl`)**:
      - `curl` (`--with-openssl --without-libpsl --with-ca-bundle='/sw/*/etc/ssl/certs/ca-certificates.crt' --with-ca-path='/sw/*/etc/ssl/certs' --with-ca-fallback`) serves as the base HTTP client in `cross-build` (`curl-pass1`) and `fluffy-build` (`curl`), with `glob()` expansion in `lib/vtls/openssl.c` (`ossl_load_trust_anchors`), providing:
        1. Native concurrent multi-URL downloads via `curl --parallel` (`-Z`) for parallel bottle prefetching during `swctl build` DAG resolution and multi-archive `PREPARE` downloads.
        2. `libcurl.so` for downstream packages (`git`, `cmake`, `systemd`, etc.).
    - **Single Network-Enabled Lockdown Phase (`PREPARE`)**:
      - `PREPARE` is the sole `lockdown` phase executed with network access: it runs in an isolated private mount namespace (`CLONE_NEWNS`) with a read-only root (`/`), unprivileged builder user, and `/etc/resolv.conf`, but without `CLONE_NEWNET`.
      - All subsequent phases (`MAKE`, `CHECK`, `INSTALL`, `SQUASHFS`) are strictly air-gapped via `CLONE_NEWNET`, guaranteeing hermetic, deterministic, offline builds.
      - To download source archives autonomously without host intervention, `cross-build` and `fluffy-build` incorporate `curl`, `openssl`, and `ca-certificates` in their base environment.
    - **Read-Only `/sw/<pkg>/etc` CA Trust Store**:
      - Packages never write to `/etc` during build or install.
      - Upstream Mozilla root CA bundle is packaged directly into `/sw/ca-certificates/etc/ssl/certs/ca-certificates.crt` inside the read-only `ca-certificates` squashfs image.
      - OpenSSL and `curl` read certificates directly from `/sw/*/etc/ssl/certs/ca-certificates.crt` and `/sw/*/etc/ssl/certs`, requiring zero `/etc` mutation or mount-time hooks.
    - **TODO: Universal Timestamp Preservation Across All Patches**:
      - All patches across all recipes must strictly preserve upstream file modification timestamps.
      - Applying patches must never shift file `mtime` values forward, ensuring that timestamp-sensitive dependencies (e.g. Makefile vs configure vs aclocal.m4) do not falsely trigger autotools regeneration or `help2man` rebuilds during compilation.
    - **TODO: Patching Autotools Input Files (`configure.ac` / `Makefile.am`) + `autoreconf` with Inline `ARCHIVES` Autoconf/Automake Pins**:
      - Rather than carrying multi-thousand-line patches against generated `configure` / `Makefile.in` / `build-aux/*` files across every package, patch only the declarative input files (`configure.ac`, `Makefile.am`, `.m4`) and run `autoreconf -fi` against Fluffy-patched `autoconf`, `automake`, and `libtool` templates (which emit `/sw/bash/bin/bash` and Fluffy defaults out of the box).
      - Where packages pin specific older Autoconf/Automake versions (e.g. GCC and Binutils requiring `autoconf-2.69` and `automake-1.15.1`), pull the required `autoconf`/`automake` source tarballs and reusable Fluffy generator patches directly in that recipe's `ARCHIVES=(...)` and build them inline into a scratch prefix inside `/work` (just like `gcc-pass1` pulls `mpfr`/`mpc`/`gmp` via `ARCHIVES`).
      - This avoids proliferating versioned `autoconf-*`/`automake-*` package recipes in `sw/` while shrinking per-package patches down to tiny, human-auditable `configure.ac`/`Makefile.am` diffs that survive upstream version bumps cleanly.
    - **TODO: Maintain Git Repos for All Upstream Software (`git format-patch` Over Branches from Release Tags)**:
      - Maintain dedicated git repositories for all patched upstream software packages and develop Fluffy changes as clean commits on a branch forked directly from the upstream release tag, generating patch series with `git format-patch` instead of doing the manual tar-untar-diff-patch-sha256 dance.
      - Each logical change (mechanical shebang rewrites, `/sw/*` wildcard path discovery, upstream bugfixes) lives as its own atomic, self-documented commit that can be cherry-picked or rebased cleanly across upstream version upgrades.
      - *Note on `sqlite`*: SQLite is tricky because upstream develops in Fossil rather than Git and distributes pre-generated amalgamation tarballs (`sqlite-autoconf-*`) whose directory layout differs from the raw Fossil repository tree.
    - **Mandatory Test Coverage for All Patched Behavior & High-Bit Custom Flags**:
      - Every behavior we patch or add in an upstream package (bugfixes, `/sw/*` wildcard expansion, custom flags) must be accompanied by unit/regression tests in that package's test suite so `CHECK()` continuously verifies our patched behavior.
      - Whenever we introduce new bitflags into upstream headers (such as `GLOB_KEEP_SLASHES` in `glibc`'s `<glob.h>`), allocate bits starting from the high end of the bit range (e.g. `(1 << 30)` downward) to avoid colliding with flags upstream adds at the low end in future releases.
    - **TODO: Split Shebang / Path Patches from Logic / Bugfix Patches**:
      - Separate `/sw/bash/bin/bash` shebang and interpreter path rewrites from functional logic and bugfix patches.
      - Both types can use the `-fluffy` naming convention, e.g.:
        - `<pkg>-<version>-fluffy-shell.patch`: bulk script shebang and interpreter path adjustments.
        - `<pkg>-<version>-fluffy-<issue>.patch` (e.g. `m4-1.4.21-fluffy-posix-spawn.patch`): surgical upstream logic fixes, glibc compatibility, or testsuite adaptations.
        - Decoupling shebang updates ensures automated path updates can be regenerated cleanly with `mkbashpatch` without clobbering or conflating hand-crafted code fixes.
    - **Timestamp Preservation Across Fluffy Patches**:
      - `mkbashpatch` records `os.stat` timestamps and restores exact nanosecond mtimes/atimes using `os.utime()` after rewriting paths to `/sw/bash/bin/bash`.
      - Diffs are generated in UTC (`TZ=UTC0 LC_ALL=C diff -Naur`) and applied with `patch -Z` (`--set-utc`), perfectly preserving original upstream release file ordering and preventing autotools (`aclocal`, `autoheader`, `automake`) or `help2man` from falsely triggering during compilation.

## Bootstrap Milestones

- **Chapter 8 Progress (Installing Basic System Software)**:
  - 8.3 `man-pages` (6.18) verified and registered (`man-pages-6.18.squashfs`).
  - 8.4 `iana-etc` (20260805) verified and registered (`iana-etc-20260805.squashfs`).
  - 8.5 `glibc` (2.44) verified and registered (`glibc-2.44.squashfs`).
  - 8.6 `zlib` (1.3.2) verified and registered (`zlib-1.3.2.squashfs`).
  - 8.7 `bzip2` (1.0.8) verified and registered (`bzip2-1.0.8.squashfs`).
  - 8.8 `xz` (5.8.3) verified and registered (`xz-5.8.3.squashfs`).
  - 8.9 `file` (5.48) verified and registered (`file-5.48.squashfs`).
  - 8.10 `readline` (8.3) verified and registered (`readline-8.3.squashfs`).
  - 8.11 `m4` (1.4.21) verified and registered (`m4-1.4.21.squashfs`): gnulib `posix_spawn` redirect recursion guarded and test BOURNE_SHELL paths adapted to `/sw/bash/bin/bash`; all tests passing.
  - 8.12 `bc` (7.0.3) verified and registered (`bc-7.0.3.squashfs`).
  - 8.13 `flex` (2.6.4) verified and registered (`flex-2.6.4.squashfs`).
  - 8.14 `lz4` (1.10.0) verified and registered (`lz4-1.10.0.squashfs`).
  - 8.15 `zstd` (1.5.7) verified and registered (`zstd-1.5.7.squashfs`): built with multi-format compression support (lz4, xz, zlib).
  - 8.16 `tcl` (8.6.18) verified and registered (`tcl-8.6.18.squashfs`): includes dynamic `auto_path` globbing over `/sw/*/lib` in `library/init.tcl`.
  - 8.17 `expect` (5.45.4) verified and registered (`expect-5.45.4.squashfs`): TEA configured with late-bound `/sw/*/lib` and `/sw/*/include` discovery; `exec_prefix` isolated to `/sw/expect`; `STTY_BIN=stty` resolved via `PATH`.
  - 8.18 `dejagnu` (1.6.3) verified and registered (`dejagnu-1.6.3.squashfs`): `proc which` in `lib/utils.exp` updated for wildcard `PATH` expansion and `exec bash -c` in `lib/remote.exp`; all `launcher`, `libdejagnu`, `report-card`, and `runtest` tests passing.
  - 8.19–8.21 `pkgconf`: skipped by design (late-bound `/sw/*/{include,lib}` discovery eliminates `pkg-config`).
  - 8.20 `ninja` (1.13.2) verified and registered (`ninja-1.13.2.squashfs`, 2.9M): `Subprocess::Start` (`src/subprocess-posix.cc`) patched to invoke `/sw/bash/bin/bash`, `NINJAJOBS` support added, and Python test suites (`ninja_syntax_test.py`, `jobserver_pool_test.py`, `jobserver_test.py` including `test_subprocess_uses_fluffy_bash`) passing.
  - 8.22 `binutils` (2.47) verified and registered (`binutils-2.47.squashfs`): literal `SEARCH_DIR("/sw/*/lib")` in ldscripts with runtime `glob()` expansion in `ldfile.c`; full DejaGnu testsuite (`binutils`, `gas`, `ld`, `libctf`, `libsframe`) passing 100%.
  - 8.23 `gmp` (6.3.0) verified and registered (`gmp-6.3.0.squashfs`): C++ bindings (`libgmpxx`), HTML docs, and >=199 tests passing.
  - 8.24 `mpfr` (4.2.2) verified and registered (`mpfr-4.2.2.squashfs`).
  - 8.25 `mpc` (1.4.1) verified and registered (`mpc-1.4.1.squashfs`).
  - 8.26 `attr` (2.6.0) verified and registered (`attr-2.6.0.squashfs`).
  - 8.27 `acl` (2.4.0) verified and registered (`acl-2.4.0.squashfs`).
  - 8.28 `libcap` (2.78) verified and registered (`libcap-2.78.squashfs`).
  - 8.29 `libxcrypt` (4.5.2) verified and registered (`libxcrypt-4.5.2.squashfs`): C23 `strchr` discarded-qualifier fix applied; test suite passing.
  - 8.30 `shadow` (4.20.2) verified and registered (`shadow-4.20.2.squashfs`): configured with `shadow_cv_maildir=/var/mail` and `shadow_cv_logdir=/var/log`; setuid bits preserved in squashfs image.
  - 8.31 `gcc` (16.2.0) verified and registered (`gcc-16.2.0.squashfs`, 649M) and `libstdcpp` (16.2.0, `libstdcpp-16.2.0.squashfs`, 3.6M).
  - 8.32 `ncurses` (6.6) verified and registered (`ncurses-6.6.squashfs`, 1.7M): wide-character ABI enabled (`--enable-widec`, `--enable-overwrite`), shared C++ bindings (`--with-cxx-shared`, `libncurses++w.so`), curses.h wide-character ABI fix applied, and non-wide compatibility symlinks (`libncurses.so`, `libform.so`, `libpanel.so`, `libmenu.so`, `libcurses.so`).
  - 8.33 `sed` (4.10) verified and registered (`sed-4.10.squashfs`, 500K): built with HTML documentation, full test suite passing, and `/sw/sed/bin/sed` verified.
  - 8.34 `psmisc` (23.7) verified and registered (`psmisc-23.7.squashfs`, 352K): full DejaGnu test suite passing; `fuser`, `killall`, `peekfd`, `prtstat`, `pslog`, `pstree`, and `pstree.x11` verified.
  - 8.35 `gettext` (1.0) verified and registered (`gettext-1.0.squashfs`).
  - 8.36 `bison` (3.8.2) verified and registered (`bison-3.8.2.squashfs`).
  - 8.37 `grep` (3.12) verified and registered (`grep-3.12.squashfs`).
  - 8.38 `bash` (5.3) verified and registered (`bash-5.3.squashfs`).
  - 8.39 `libtool` (2.6.2) verified and registered (`libtool-2.6.2.squashfs`).
  - 8.40 `gdbm` (1.26) verified and registered (`gdbm-1.26.squashfs`).
  - 8.41 `gperf` (3.3) verified and registered (`gperf-3.3.squashfs`).
  - 8.42 `expat` (2.8.3) verified and registered (`expat-2.8.3.squashfs`).
  - 8.43 `inetutils` (2.8) verified and registered (`inetutils-2.8.squashfs`).
  - 8.45 `less` (704) verified and registered (`less-704.squashfs`).
  - 8.46 `perl` (5.44.0) verified and registered (`perl-5.44.0.squashfs`).
  - 8.47 `autoconf` (2.73) verified and registered (`autoconf-2.73.squashfs`).
  - 8.48 `automake` (1.18.1) verified and registered (`automake-1.18.1.squashfs`).
  - 8.49 `openssl` (4.0.1) verified and registered (`openssl-4.0.1.squashfs`): `HASHBANGPERL` configured to `/sw/perl/bin/perl` in `Configurations/00-base-templates.conf`, full test suite passing.
  - 8.50 `libelf` (0.195 from `elfutils-0.195`) verified and registered (`libelf-0.195.squashfs`): configured with `--disable-debuginfod --enable-libdebuginfod=dummy --without-libarchive`, passing all 260 unit tests (`PASS: 251`, `SKIP: 9`, `FAIL: 0`).
  - 8.51 `libffi` (3.8.0) verified and registered (`libffi-3.8.0.squashfs`): configured with `--disable-multi-os-directory --with-gcc-arch=native`, DejaGnu test suite passing.
  - 8.52 `sqlite` (3530400) verified and registered (`sqlite-3530400.squashfs`): configured with `--disable-static --enable-fts4 --enable-fts5 --disable-rpath --soname=legacy`; `autosetup` patched to expand wildcard `PATH` entries and avoid hardcoded `/bin/sh`.
  - 8.53 `mpdecimal` (4.0.1) verified and registered (`mpdecimal-4.0.1.squashfs`): configured with `--disable-static`, documentation installed; full C (`runtest_shared`) and C++ (`apitest_shared`, `runtest_shared`) test suites passing 100%.
  - 8.54 `python` (3.14.7) verified and registered (`python-3.14.7.squashfs`, 66M): configured with `--enable-shared --with-system-expat --without-static-libpython`; documentation and pip configuration installed; patched for Fluffy wildcard `PATH` in `shutil.which` and PyREPL `/sw/*/share/terminfo` discovery; `SOURCE_DATE_EPOCH` unset for `CHECK()`; full test suite passing 100% including `test_socket`, `test_base_events`, `test_subprocess`, `test_pyrepl`, `test_shutil`, `test_zipfile`, `test_importlib`.
  - 8.55 `flit-core` (4.0.2) verified and registered (`flit-core-4.0.2.squashfs`, 108K): pure Python package built with pip wheel and installed into `/sw/flit-core/lib/python3.14/site-packages` without build isolation.
  - 8.56 `packaging` (26.3) verified and registered (`packaging-26.3.squashfs`, 304K): built with `flit_core` via Python `/sw/*/lib/python3.14/site-packages` late-bound discovery and `glibc` `glob(3)` (`GLOB_KEEP_SLASHES`) shim.
  - 8.57 `wheel` (0.48.0) verified and registered (`wheel-0.48.0.squashfs`, 76K): built with `flit_core` and `packaging`.
  - 8.58 `setuptools` (84.0.0) verified and registered (`setuptools-84.0.0.squashfs`, 1.7M): built with `wheel` and `packaging`.
  - 8.59 `meson` (1.12.0) verified and registered (`meson-1.12.0.squashfs`, 3.0M): patched with environment-driven `SystemLibraryDependency` (`<DEP>_CFLAGS` and `<DEP>_LDFLAGS` / `<DEP>_LIBS` like Autoconf `pkg.m4`), missing-shebang script invocation rewrite, wildcard `PATH` expansion via `os.get_exec_path`, and unit tests (`test_fluffy_system_library_dependency`, `test_fluffy_shebang_rewrite`) passing (188 tests).
  - 8.60 `kmod` (34.2) verified and registered (`kmod-34.2.squashfs`, 160K): built with Zstandard, XZ, Zlib, and OpenSSL PKCS7 signature support via `HAS_LDFLAGS` / `X-fluffy.ldflags` in `fstab` without hardcoded flags; patched `libkmod` and `depmod` to glob `/sw/*/{etc,lib}/{modprobe,depmod}.d` and `/etc/{modprobe,depmod}.d`; all 16/16 test suites passing (including `blacklist_fluffy_glob` and `depmod_search_order_fluffy_sw`).

- **`libstdcpp` Standalone Build & POSIX Gthreads Support**:
  - When `libstdc++-v3` is configured standalone outside of the full GCC build tree, its configure script checks for gthreads by compiling `#include "gthr.h"`.
  - `gthr.h` includes `"gthr-default.h"`, which is normally generated as a symlink during `libgcc` builds. In a standalone `libstdc++-v3` build without `libgcc` concurrently building in tree, this header was missing, causing `ac_has_gthreads=no` and undefining `_GLIBCXX_HAS_GTHREADS` in `c++config.h`.
  - As a result, `std::thread`, `std::mutex`, `std::condition_variable`, and C++11 concurrency symbols were omitted from `libstdc++.so.6`, breaking downstream C++ test suites (such as `mpdecimal`'s `tests++`).
  - **Fix in `sw/libstdcpp`**: Symlink `gthr-posix.h` to `libgcc/gthr-default.h` before running `configure`. Rebuilding `libstdcpp-16.2.0.squashfs` restored all `std::thread` symbols and full C++ concurrency across the system.

- **Autosetup `$CROSS` Collision Note**:
  - `autosetup` (used by modern SQLite and other tools) defines its cross-compilation prefix directly from the `CROSS` environment variable: `define cross [get-env CROSS $cross]`.
  - When building with `CROSS=1 ./swctl build ...`, `autosetup` treats `CROSS=1` as a tool prefix string `"1"` and attempts to invoke `1cc`, `1gcc`, `1ar`, `1ld`.
  - Recipes using `autosetup` must invoke configure with `CROSS="" ./configure ...` to ensure native tools (`cc`, `ar`, etc.) are resolved correctly.

- **Chapter 7 Complete (In-Chroot Native Compilation & Network Stack)**:
  - `zstd-pass1` and `squashfs-tools-pass1` cross-compiled with `$FLUFFY_TGT-gcc` on host.
  - `create` executes inside a pure Fluffy chroot for `ON=fluffy`, mounting a minimal 9-package base (`glibc-pass1`, `ncurses-pass1`, `bash-pass1`, `libffi-pass1`, `ctypes-sh-pass1`, `coreutils-pass1`, `tar-pass1`, `xz-pass1`, `gzip-pass1`).
  - Isolated `lockdown SQUASHFS` phase mounts strictly `SQUASHFS_NEEDS` (`squashfs-tools-pass1`, `gcc-pass2`, transitively `zstd-pass1` and `glibc-pass1`), completely isolating packaging tools from `MAKE`, `CHECK`, and `INSTALL`.
  - `gettext-pass1` (1.0) built, installed, and packaged into `gettext-pass1-1.0.squashfs` inside the chroot with zero FHS symlinks and zero `sbin`.
  - `bison-pass1` (3.8.2) built, installed, and packaged into `bison-pass1-3.8.2.squashfs` (1.7M) inside the chroot; `bison` and `yacc` verified.
  - `perl-pass1` (5.44.0) built, installed, and packaged into `perl-pass1-5.44.0.squashfs` (13M) inside the chroot; native `/sw/perl/bin/perl` verified with zero `/bin/sh` or `/usr` references.
  - `zlib-pass1` (1.3.2) built, tested (`make check`), installed, and packaged into `zlib-pass1-1.3.2.squashfs` (96K) inside the chroot.
  - `mpdecimal-pass1` (4.0.1) built, tested (`make check`), installed, and packaged into `mpdecimal-pass1-4.0.1.squashfs` (120K) inside the chroot; `libmpdec` and `libmpdec++` verified.
  - `python-pass1` (3.14.7) built, installed, and packaged into `python-pass1-3.14.7.squashfs` (62M) inside the chroot with shared library support, decimal, and zlib modules.
  - `texinfo-pass1` (7.3) built, installed, and packaged into `texinfo-pass1-7.3.squashfs` (3.0M) inside the chroot with timestamp-preserving patches and Libtool install-time relinking.
  - `util-linux-pass1` (2.42.2) built, installed, and packaged into `util-linux-pass1-2.42.2.squashfs` (16M).
  - Standalone network & trust stack built and verified: `ca-certificates` (2026.10.20), `openssl-pass1` (4.0.1), `curl-pass1` (8.23.0), and `signify-pass1` (32) registered into `cross-build-1.0.squashfs`.

- **Chapters 5 & 6 Toolchain Complete & Verified (`check-toolchain`)**:
  - Full cross-toolchain (`binutils-pass1`, `gcc-pass1`, `glibc-pass1`, `libstdcpp-pass1`, `linux-headers`) and temporary tools (`m4-pass1`, `ncurses-pass1`, `bash-pass1`, `libffi-pass1`, `ctypes-sh-pass1`, `coreutils-pass1`, `diffutils-pass1`, `file-pass1`, `findutils-pass1`, `gawk-pass1`, `grep-pass1`, `gzip-pass1`, `make-pass1`, `patch-pass1`, `sed-pass1`, `tar-pass1`, `xz-pass1`, `binutils-pass2`, `gcc-pass2`) are built and verified.
  - Verified via [`check-toolchain`](check-toolchain): C and C++ compilation, `<iostream>` and `<ffi.h>` inclusion, `PT_INTERP` pointing to `/sw/glibc/lib/ld-linux-x86-64.so.2`, and dynamic execution—all with zero `-I` and zero `-L` flags.
