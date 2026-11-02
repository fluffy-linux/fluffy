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
       - Shell defaults in `paths.h` and `system.c`: `_PATH_DEFPATH` defaults to `"/sw/*/bin"`, `_PATH_STDPATH` to `"/sw/*/bin:/sw/*/sbin"`, and `_PATH_BSHELL` / `SHELL_PATH` to `"/sw/bash/bin/bash"`, ensuring `system()` and `popen()` run natively without `/bin/sh`.
     - **Dynamic Linker (`ld.so`)**: Iterates `/sw/*/lib` (`_dl_init_paths` in `elf/dl-load.c`) to resolve shared libraries dynamically at runtime.
     - **Final Pass Toolchain Vision (Glibc & GCC Native Wildcard Inclusion)**:
       - **GCC Preprocessor (`cppdefault.cc`)**: In the final native pass, patch GCC's include directory search logic to natively understand `/sw/*/include` (and `/sw/*/include/c++/<ver>`) instead of hardcoding `/usr/include`. GCC's CPP will discover and include headers across all mounted packages without passing a single `-I` flag.
       - **Linker (`binutils` `ld`) & Specs**: Set default library search paths to `/sw/*/lib` instead of `/usr/lib` or `/lib`.
         - **TODO: Dynamic Wildcard SEARCH_DIR in Binutils Linker Scripts**: In `binutils-pass2`, `genscripts.sh` assigned `LIB_PATH=/sw/*/lib` unquoted, expanding the glob at host build-time to only the packages present on the host (`/sw/binutils/lib /sw/gcc/lib /sw/glibc/lib`). Quoting `LIB_PATH='/sw/*/lib'` embeds literal `SEARCH_DIR("/sw/*/lib")` in the default ldscripts, allowing `ldfile.c` to dynamically `scandir("/sw", ...)` at runtime and register all `/sw/*/lib` with `cmdline=0`. This ensures `ldelf.c` automatically resolves indirect `DT_NEEDED` dependencies (e.g. `libncursesw.so.6` needed by `libreadline.so`) without requiring `-rpath-link` or explicit linker flags.
       - **Zero `-I`/`-L` Flags & Deprecation of `pkg-config`**: Because GCC, LD, and LD.SO dynamically iterate all `/sw/*/{include,lib}`, packages built for Fluffy never need `-I` or `-L` directory path flags or `pkg-config` path overrides. Upstream packages link against external libraries simply with `-l<name>`.
     - **Systemd Unit Files (`/sw/*/lib/systemd/system`)**: `systemd` (`lookup_paths_init` in `sd-path/path-lookup.c`) iterates `/sw/*/lib/systemd/system` (and `/sw/*/lib/systemd/user`) so services install their own `.service` / `.socket` files directly in `/sw/<pkg>/lib/systemd/system/` (via a heredoc or local file in `INSTALL()`), eliminating any need for external meta-packages like `blfs-systemd-units`.
     - **General-Purpose Wildcard Support (Configure `/sw/*`, Never Hardcode `/sw/` in C Source)**:
       - **Architectural Rule**: C source patches to upstream packages must **never** hardcode Fluffy-specific directory names like `"/sw"` or `"/lib"` or custom `scandir("/sw", ...)` loops. Instead, upstream code is patched to support general-purpose glob/wildcard expansion in its standard configuration paths, and `/sw/*/bin`, `/sw/*/lib`, `/sw/*/include` are passed in via configuration (`configparms` `user-defined-trusted-dirs`, `configure` flags, `paths.h`, `STANDARD_STARTFILE_PREFIX`, `NATIVE_SYSTEM_HEADER_DIR`, `PATH`).
       - For example, in `glibc` (`elf/dl-load.c`), `SYSTEM_DIRS` receives `/sw/*/lib/` via `user-defined-trusted-dirs=/sw/*/lib` in `configparms`, and `_dl_init_paths` / `is_trusted_path_normalize` expand wildcard entries in `system_dirs` generically (just like `binutils` `ldfile.c` calls `glob()` on `LIB_PATH=/sw/*/lib` and `bash` calls `shell_glob_filename` on `PATH=/sw/*/bin`).
       - Similarly, `gcc` (`gcc.cc`, `incpath.cc`, `cppdefault.cc`) should expand wildcards in configured `STANDARD_STARTFILE_PREFIX`, `STANDARD_EXEC_PREFIX`, and `NATIVE_SYSTEM_HEADER_DIR` (`--with-native-system-header-dir=/sw/*/include`) via `glob()` rather than hardcoding `scandir("/sw")`.
     - **Deprecation of `ldconfig` / `ld.so.cache` & Optimizing `glob()` in `glibc` as the Universal Lookup Primitive**:
       - `ldconfig` and `USE_LDCONFIG` (`ld.so.cache`) are completely disabled (`use_ldconfig=no`) in `glibc`. In an FHS system, `ld.so.cache` is a single-purpose hack for one subsystem (`ld.so`), whereas in Fluffy, `ld.so` (`/sw/*/lib`), `execvpe` and `bash` (`/sw/*/bin`), `gcc`/`binutils` (`/sw/*/include`, `/sw/*/lib`), and `tcl` (`/sw/*/lib`) all share the exact same access pattern: wildcard path expansion over `/sw/*/...`.
       - Rather than maintaining subsystem-specific caches or scattering custom `getdents64` loops across tools, standard POSIX `glob()` in `glibc` is the single general-purpose primitive. Optimizing `glob()` directly inside `glibc` (and using `glob()` everywhere) makes `ld.so`, `execvpe`, `bash`, `tcl`, `gcc`, and every standard `glob()` caller fast automatically.
     - **LMDB-Style Copy-on-Write `mmap` Index (`/run/fluffy/index.db`)**:
       - **Problem**: Cold traversal of `/sw/*/bin` across thousands of configure checks (e.g. 15,000 forks during Gnulib/Coreutils) performs repeated `getdents64` and `stat` calls on the filesystem.
       - **Single-Writer Multi-Reader (SWMR) CoW Architecture**:
         - `swctl` maintains an LMDB-style B+ tree index stored in a shared memory-mapped file at `/run/fluffy/index.db`.
         - **Zero-Lock, Zero-Malloc Client Traversal**: Clients (glibc `execvpe`, bash `findcmd`, ld.so) map the index read-only (`PROT_READ | MAP_SHARED`). Lookups are simple pointer traversals in memory ($O(\log N)$ or $O(1)$) with **zero mutexes, zero syscalls, and zero heap allocations**, making it 100% `vfork`/`CLONE_VM`-safe.
         - **Live In-Place Updates for Fresh Installs**: When a new package is installed, `swctl` writes new CoW tree nodes and atomically flips a single 64-bit root pointer in the header. Active shells and processes see new commands instantly without re-opening files or bouncing namespaces.

5. **Hermetic, Unprivileged Builds & Unified Tooling (`swctl build`, `swctl install`)**
   - **Folding `create` into `swctl` (`swctl build`)**:
     - All package building and recipe orchestration is unified under `swctl` (`swctl build <pkg...>` and `swctl install <pkg...>`), auto-prefixing `sw/` so package names are first-class identifiers (`swctl build glibc`, `swctl install gcc`).
     - **Registration as a Build Byproduct**: With `swctl build`, registration ceases to exist as a separate manual step. Upon completing `SQUASHFS`, `swctl build` automatically signs the image, writes the `/sw/.build/fstab` entry (target `/sw/<pkg>`, `X-fluffy.needs`, `X-fluffy.from`, `X-fluffy.signature`), and re-signs the manifest in a single atomic transaction.
   - **Recursive Recipe DAG Resolution, Transitive Input Hashing (`compute_from`) & Byte-Identical Early Cutoff**:
     - `swctl build <pkg...>` recursively walks the recipe files in `sw/` across `ON`, `NEEDS`, `MAKE_NEEDS`, `CHECK_NEEDS`, and `INSTALL_NEEDS`, producing a strict topological build order and rejecting any circular dependencies.
     - **In-Memory Transitive Input Hash (`compute_from`)**: Without mutating git-tracked `sw/<pkg>` files on disk, `compute_from` streams the raw `sw/<pkg>` recipe file followed by sorted `<canon_pkg>:<X-fluffy.signature>` pairs for the entire transitive `X-fluffy.needs` closure of `$ON`, `NEEDS`, `MAKE_NEEDS`, `CHECK_NEEDS`, and `INSTALL_NEEDS` in `/sw/.build/fstab` through `sha256sum`. Because it hashes the full mounted dependency closure rather than only direct `ON`/`NEEDS` targets, changes inside empty-squashfs meta-packages (`cross-build`, `fluffy-build`) propagate accurately to downstream packages.
     - **Early Cutoff via `cmp -s` & Signature Reuse**: Because OpenBSD `signify -S` generates a random 8-byte salt on every signing operation, re-signing a byte-identical `.squashfs` would produce a new `X-fluffy.signature` and trigger unnecessary downstream rebuilds. Instead, `SQUASHFS()` writes to `<pkg>-<ver>.squashfs.new`, and `register_entry` compares it against the existing `.squashfs` in `/sw/.build/fstab` using `cmp -s` (which checks file size via `stat` and exits immediately on the first differing byte without hashing). If the newly built `.squashfs` is byte-identical, `register_entry` reuses the existing `X-fluffy.signature` and updates only `X-fluffy.from`, stopping the downstream rebuild cascade immediately.
   - **Future CI, Remote Binary Bottle Cache, `world` & Local User Packages**:
     - **Binary Bottles (GitHub Packages / GHCR)**:
       - Before building a package from source, `swctl` can query a remote package registry for a prebuilt `.squashfs` matching the recipe's `X-fluffy.from` hash, verify its `signify` signature against `release.pub`, and register it directly into `fstab`.
       - `ON=host-build` and `ON=cross-build` recipes (`*-pass1`, `*-pass2`) are host-dependent and stored as **private** GitHub Packages solely for CI reuse (avoiding cache eviction), whereas `ON=fluffy-build` packages are **public** portable bottles.
     - **CI Pipeline via `sw/world` & Manifest Diffing**:
       - A `sw/world` pseudopackage (`NEEDS=(...)` of all distro packages) lets CI run `swctl build world`.
       - CI downloads the prior `fstab` manifest; where `X-fluffy.from` matches the current recipe `sha256`, `swctl` downloads the existing `.squashfs` from GitHub Packages and validates `X-fluffy.signature`. Where it differs, `swctl` rebuilds from source.
       - Comparing the old `fstab` against the new `fstab` identifies the exact set of newly built `.squashfs` images to publish.
       - **Dev (`SNAPSHOT`) vs. Release Channels & Immutable Release Versions (`fluffy0`, `fluffy1`)**:
         - Dev/main builds and tagged releases are separated Maven-style (`SNAPSHOT` vs. release manifests/tags) so experimental rebuilds don't overwrite release bottles.
         - **Release Immutability Guard & Package Revisions**: On release builds, publishing over any existing package version is a hard error. Before publishing *any* artifact, CI checks the entire publish set and fails immediately if any rebuilt package (`X-fluffy.from` changed) still has a version/filename that already exists in the release registry—which always means a version bump was forgotten.
         - To support recipe/patch updates without changing upstream `$VERSION` (used in `ARCHIVES` URLs), recipes support Debian/Ubuntu-style package revisions (`fluffy0`, `fluffy1`, etc., e.g. `<pkg>-<version>-fluffy0.squashfs`).
       - **Debian-Style Reproducible Builds & Early Cutoff (Avoiding Mass Rebuild Cascades)**:
         - In purely input-addressed systems (Nix/Guix), changing an upstream recipe like `glibc` alters input hashes and forces blind rebuild cascades across every downstream package, even when compiled output binaries would be bit-for-bit identical.
         - By enforcing Debian-style bitwise reproducible builds (`SOURCE_DATE_EPOCH=0`, deterministic squashfs creation, normalized timestamps and filesystem ordering), Fluffy employs an **early cutoff** strategy directly in `swctl`: when an upstream dependency changes and a downstream package is rebuilt, `register_entry` compares `.squashfs.new` against the existing `.squashfs` via `cmp -s`; if they are byte-identical, it preserves `X-fluffy.signature` so all further downstream packages see an unchanged `compute_from` hash and the rebuild cascade stops immediately.
         - **SquashFS vs. Object-Level Hashing**: Unlike OSTree or Git, which hash individual uncompressed files, Fluffy signs the `.squashfs` image directly. A change to `zstd` compression heuristics or `mksquashfs` block layout will change the `.squashfs` SHA-256 even if uncompressed files are identical. However, because `zstd` and `squashfs-tools` belong to `cross-build` / `fluffy-build`, any change to the compression toolchain automatically triggers a system rebuild anyway—so within a stable toolchain generation, deterministic `mksquashfs` is completely sufficient without needing an extra object-hashing layer.
     - **Native OS Detection (`/etc/os-release`) & Local User Packages (`sw/local`)**:
       - Using `/etc/os-release` (`ID=fluffy`) and `$ON`, `swctl` knows when it is running natively on Fluffy Linux vs. bootstrapping from a foreign host, ensuring users on Fluffy never re-trigger `pass1`/`pass2` cross-compilation because `ON=fluffy-build` packages are self-contained.
       - Users can define local packages and even a `sw/local` pseudopackage (`NEEDS=(world userpkg1 userpkg2)`), where `world` resolves from signed upstream bottles while `userpkg1` and `userpkg2` build locally.
     - **Setuid Embedded-Script `swctl` Binary, `build` Group & User vs. System Squashfs Separation**:
       - Because the Linux kernel ignores the `setuid` bit on `#!` scripts, `swctl` can be packaged as a dedicated setuid binary built from a special-purpose `bash` (with the `swctl` script embedded in `.rodata` and `-c` / interactive flags disabled) or a small C wrapper.
       - A `build` group and separate storage/namespace boundaries between system squashfs images (requiring `CAP_SYS_ADMIN` / system install privileges) and user-built squashfs images allow unprivileged users to run `swctl build` out of their own home-directory recipe clones (and even drop into a shell with a custom `fstab` software set) without granting them unrestricted root access to the system.
   - **Host vs. Native Detection via `$FLUFFY` & `/sw` Bind-Mount Normalization**:
     - `FLUFFY` (pointing to e.g. `/mnt/fluffy`, `DESTDIR`/`LFS`-style) is the sole indicator that `swctl` is running on a foreign host rather than natively on a Fluffy system.
     - When `FLUFFY` is set, `swctl` immediately enters a private mount namespace (`unshare(CLONE_NEWNS)`, `MS_REC | MS_PRIVATE`) and bind-mounts `$FLUFFY/sw` onto `/sw`. This normalizes all paths so `swctl` can refer directly to `/sw/.build/fstab`, `/sw/.build/release.sec`, `/sw/.build/destdir`, and `/sw/<pkg>-<ver>.squashfs` without conditional `$FLUFFY` prefixes (and keeps metadata hidden under `.build` so `/sw/*` wildcard globs skip it automatically).
     - When `FLUFFY` is unset, `swctl` is running natively on Fluffy Linux (or inside the `$FLUFFY` chroot after `unset FLUFFY`) and rejects `ON=host-build` packages.
     - For `ON != host-build` when `FLUFFY` is set, `build_single_pkg` mounts `$ON` onto `/sw`, recursively bind-mounts `/sw` onto `$FLUFFY/sw`, `chroot`s into `$FLUFFY`, unsets `FLUFFY`, and re-execs `swctl build <pkg>`.
   - **Unprivileged Builder Lifecycle**:
     - Immediately upon launch via `sudo`, the build engine drops real/effective UID and GID to `$SUDO_UID:$SUDO_GID` (`setresgid`/`setresuid` keeping saved UID/GID `0` only for mount setup), so all downloaded archives and extracted files under `work/` (`work/archives`, `work/src`, `work/installed`, `work/test-results`, `work/test-work`) are naturally owned by the calling user.
   - **Dependency DAG & Resolution**:
     - Package definitions in `sw/` declare runtime dependencies via `NEEDS=()` and phase-specific build dependencies via `MAKE_NEEDS=()`, `CHECK_NEEDS=()`, and `INSTALL_NEEDS=()`.
     - For each phase, the build engine mounts strictly the topological dependency closure via `install_targets`.
   - **`PREPARE`**: Downloads and SHA-256 verifies tarballs and `file://` patches into `work/archives/`, extracts into `work/src/` as the calling user.
   - **`lockdown` (for `MAKE`, `CHECK`, `INSTALL`)**:
     - Even when running inside a chroot, `lockdown` enforces hermetic sandbox boundaries.
     - Regains saved UID `0` inside the subshell (`setresuid 0 0 0`), enters private network and mount namespaces (`unshare(CLONE_NEWNET | CLONE_NEWNS)`), sets `/` propagation to `MS_REC | MS_PRIVATE`.
     - Mounts only the resolved dependency closure for that phase under `/sw/*`.
     - Phase-specific writable mounts:
       - `MAKE`: `$wd` bind-mounted read-write at `/work`.
       - `CHECK`: `overlayfs` mounted at `/work` over `$wd` (`upperdir=$work_dir/test-results`, `workdir=$work_dir/test-work`) so tests cannot dirty the build tree before `INSTALL`, while leaving `test-results` behind on failure for inspection.
       - `INSTALL`: `$wd` bind-mounted read-write at `/work`. `$work_dir/installed` is bind-mounted at `/sw/.build/destdir/sw/$mount_pkg`.
     - **Universal `DESTDIR=/sw/.build/destdir` Staging**:
       - `DESTDIR=/sw/.build/destdir` and `MAKEFLAGS="$MAKEFLAGS DESTDIR=/sw/.build/destdir"` are exported automatically during `INSTALL`.
       - Packages install their files into `$(DESTDIR)/sw/$mount_pkg`, writing directly into `$work_dir/installed` without touching or over-mounting `/sw/$mount_pkg`.
       - Running dependencies mounted at `/sw/$mount_pkg` (such as `glibc-pass1` on `/sw/glibc` during a native `glibc` rebuild) remain fully active and accessible to dynamic linkers and maintainer utilities throughout `INSTALL`.
       - Eliminates all package collision detection and staging remapping complexity.
     - Remounts `/` read-only (`MS_BIND | MS_REMOUNT | MS_RDONLY`) and mounts a fresh private `tmpfs` at `/tmp` (with `HOME=/tmp`).
     - Permanently drops root (real, effective, and saved UID/GID all set to `$SUDO_UID:$SUDO_GID`), clearing all kernel capabilities (`CAP_SYS_ADMIN`, etc.).
   - **`SQUASHFS`**: Packs `work/installed` into `/sw/$pkg-$VERSION.squashfs` directly as root in the `SQUASHFS` subshell, leaving all intermediate files owned by `$SUDO_UID:$SUDO_GID`.

6. **Self-Signed Repository Manifest as a Literal `fstab` (`/sw/.build/fstab`) & Embedded Trust Root**
   - The repository manifest is formatted as a single, self-signed `fstab(5)` file at `/sw/.build/fstab`:
     ```fstab
     # fluffy.signature=<base64-ed25519-signature-over-remaining-lines>
     /sw/foo-1.23.squashfs /sw/foo squashfs X-mount.mkdir,X-fluffy.signature=<base64-sig>,X-fluffy.needs="bar,baz",X-fluffy.from=<sha256> 0 0
     /sw/bar-2.0.squashfs /sw/bar squashfs X-mount.mkdir,X-fluffy.signature=<base64-sig>,X-fluffy.needs="bar,baz",X-fluffy.from=<sha256> 0 0
     ```
   - **Why this design is so powerful**:
     - **Directly mountable by standard tools**: `libmount`, `mount -a -T`, and `systemd-fstab-generator` treat `#` as a comment line by default. No stripping or pre-processing is needed to use `/sw/.build/fstab` as a mount table.
     - **Standard Userspace Options (`X-appname.option`)**: In accordance with the `mount(8)` and `libmount` standard specification, all user-space / application-specific mount options are prefixed with `X-<appname>.<option>` without leading hyphens:
       - `X-fluffy.signature=<base64-signature>`: package-level verification signature created by signing the `.squashfs` image with `signify` at registration time (and preserved across rebuilds when `cmp -s` confirms the new `.squashfs` is byte-identical).
       - `X-fluffy.needs="<dep1>,<dep2>"`: comma-separated list of runtime dependency packages.
       - `X-fluffy.from=<sha256>`: sha256 checksum of the package recipe in `sw/<pkg>` combined with the sorted `<canon_pkg>:<X-fluffy.signature>` pairs of its transitive mounted dependency closure (`compute_from`), recording both recipe and dependency provenance without mutating recipe files on disk.
     - **Compact Ed25519 signatures**: Raw Ed25519 signatures are exactly 64 bytes (88 base64 characters; 100 characters in OpenBSD signify format)—no massive ASCII armor blocks or multi-kilobyte RSA blobs.
     - **Single-file verification**: The signature on line 1 covers lines 2 through EOF. Verifying line 1 against the trusted public key validates the entire repository index in one shot (all package filenames, mountpoints, squashfs signatures, and dependency closures) without needing separate detached `.sig` files:
       ```bash
       sig=$(sed -n '1s/^# fluffy\.signature=//p' /sw/.build/fstab)
       # Verify lines 2..EOF against the embedded signature
       ```
     - **Trust Root / Bootstrap**: The distro release signing public key cannot live inside a package squashfs (which would be circular). Instead, it lives alongside the manifest at `/sw/.build/release.pub` (or embedded in the bootstrap script / initramfs), providing the root of trust from day one.
     - **In-process parsing & mounting**: `libmount` (`<libmount/libmount.h>` called via `ctypes.sh`) parses the manifest, resolves dependencies, checks options (`X-mount.mkdir`, `X-fluffy.signature`, `X-fluffy.needs`, `X-fluffy.from`), and mounts the squashfs images directly in-process.

7. **Runtime State Separation (`/var/<pkg>`) & Dynamic Users**
   - Packages in `/sw/<pkg>` are strictly immutable, code/asset-only squashfs images packed with `-all-root` (everything owned by `root:root`).
   - Packages that require persistent mutable runtime state (databases, spools, caches) store it in `/var/<pkg>` (e.g. `/var/locate`, `/var/systemd`).
   - To avoid coordinating hardcoded static UIDs across package definitions at build time, runtime services run under dynamic users (e.g. `DynamicUser=yes` with `StateDirectory=` under systemd, or `sysusers.d` allocation at install/boot).
   - This ensures `/var/<pkg>` directories are mode `0700` and accessible only to that specific package's service, with zero UID baked into the package image itself.

8. **Pseudopackages (`*-build`), Manifest-Driven Resolution & Companion Mount Engine**
   - **Pseudopackages (Virtual Packages) with `NEEDS=(...)` Only**:
     - Packages that define *only* `NEEDS=(...)` with no `MAKE()`, `CHECK()`, or `INSTALL()`.
     - When created, pseudopackages produce an empty squashfs and register their dependency closure in `/sw/.build/fstab`.
     - Builder profiles encapsulate the environment for each bootstrap phase:
       - `sw/host-build`: `NEEDS=()` (pure host compilation with no `/sw` mounts).
       - `sw/cross-build`: `NEEDS=(bzip2-pass1 ctypes-sh-pass1 gzip-pass1 signify-pass1 squashfs-tools-pass1 tar-pass1 util-linux-pass1 wget-pass1 xz-pass1)` (the trimmed top-level scaffold needed to run `swctl build` and `PREPARE` inside chroot during Chapter 7; transitive dependencies like `bash-pass1`, `glibc-pass1`, `ncurses-pass1`, `openssl-pass1`, `ca-certificates`, and `coreutils-pass1` are resolved automatically).
       - `sw/fluffy-build`: `NEEDS=(bzip2 ctypes-sh gzip signify squashfs-tools tar util-linux wget xz zstd)` (the final native Fluffy self-hosting environment).
     - Regular package definitions reference these profiles directly via `$ON`, which defaults to `fluffy-build`. `swctl` transitively resolves the builder profile's `NEEDS` to set up the build environment for each stage before mounting package-specific requirements.
   - **Builder Harness Isolation (`/builder`) & Rebuilt Build Dependencies**:
     - **TODO: Post-Boot Priority: Implement `/builder` Harness Isolation**:
       - As observed during Chapter 8 (`zstd` discovering `zlib` and `xz` from `cross-build`), mounting builder tools directly in `/sw/*` allows configure checks to accidentally discover and link against build-harness libraries.
       - Immediately once the system boots natively, rebuild the build harness under `/builder/*` and isolate compiler/linker include/lib search strictly to `/sw/*`.
     - **Problem with Accidental Linkage**: Packages being built can accidentally discover and link against libraries or headers provided by the builder harness (`$ON` profiles like `cross-build` or `fluffy-build`). Post-install closure verification is finicky and brittle; statically linking the entire build harness runs counter to LFS and Glibc design.
     - **Isolation via Dedicated `/builder` Prefix**:
       - Packages belonging to the build toolkit are rebuilt specifically under the assumption of a `/builder/<pkg>` path rather than `/sw/<pkg>`, and packed into squashfs images kept strictly out of `/sw/*`.
       - The build engine mounts these `$ON` build dependencies specially at `/builder/<pkg>`.
     - **Magic Detection via Self-Referential Circular Dependency (`ON=<self>`)**:
       - If a builder profile or recipe (e.g. `sw/foo-builder`) declares `ON=foo-builder` (a synthetic self-referential / circular dependency), the build engine magically detects that this package and all of its transitive dependencies are intended for `/builder`.
       - **Unhardcoding Paths**: Build staging and prefixes transition from hardcoded `/sw` to dynamic root paths (e.g. `$PKG_ROOT` or `$BUILD_PREFIX` resolving to `/builder` vs `/sw`), allowing recipes and build logic to target `/builder` cleanly without duplicating recipe definitions.
     - **Clean Path Semantics**:
       - Environment path execution is straightforward:
         ```bash
         PATH='/builder/*/bin:/sw/*/bin'
         ```
       - Compilers, dynamic linkers, and include preprocessors only scan `/sw/*/{include,lib}` for dependencies. Because the builder harness lives entirely outside `/sw/*`, packages can invoke build tools from `/builder/*/bin` without ever accidentally resolving or linking against build-time harness libraries.
   - **Transitive Dependency Reduction (`./trim`)**:
     - `./trim <pkg...>` performs a transitive reduction over the dependency DAG recorded in `/sw/.build/fstab`.
     - Removes any package from the argument list that is already a direct or transitive dependency of another package in the list.
     - Supports `-1` / `--lines` for newline output, or space-separated by default.
     - Enables concise recipe definitions (`NEEDS`, `MAKE_NEEDS`, `INSTALL_NEEDS`) where only root dependencies need to be specified (e.g. specifying `bash` automatically implies `ncurses` and `glibc`; `ctypes-sh` implies `libffi` and `bash`).
   - **Strict Circular Dependency Detection & Topological Mount Order**:
     - Before performing any mount operations, `swctl install` executes a recursive depth-first search (DFS) tracking node states (0 = unvisited, 1 = visiting/active in-stack, 2 = visited/completed).
     - Any circular dependency (direct or transitive) is rejected immediately with a fatal diagnostic displaying the exact dependency cycle path before touching mounts or namespaces.
     - Dependencies are gathered in DFS post-order, producing a strictly topological mount order where every dependency is mounted prior to the packages that depend on it.
   - **Manifest-Driven Resolution via `/sw/.build/fstab`**:
     - `swctl` stops scanning filesystem glob patterns (`/sw/"$dep"-[0-9]*.squashfs`).
     - `/sw/.build/fstab` is the single source of truth for all built squashfs images, mount targets, package signatures, transitive requirements (`X-fluffy.needs="dep1,dep2"`), and build recipe hashes (`X-fluffy.from="<sha256>"`).
     - After `SQUASHFS` completes, the newly created image is recorded into `/sw/.build/fstab` via `libmount`:
       - Newly built packages append a line.
       - Rebuilt packages report updates in-place for that exact package entry.
   - **Unified Package Manager & Build Tool (`swctl`)**:
     - All mount, unmount, loop device ioctl, namespace preparation, dependency resolution, build orchestration, and `fstab` manipulation logic is unified in `swctl`.
     - `swctl` exposes two primary commands (`swctl build <pkg...>` and `swctl install <pkg...>`):
       - Resolving build and runtime dependency DAGs and detecting circular references.
       - Setting up the outer harness mounts for `$ON`.
       - Cleaning `/sw` inside `lockdown` and mounting strictly the phase dependency closure.
       - Upserting entries into `/sw/.build/fstab` on packaging completion (automatically calculating mount target `/sw/<pkg>`, sourcing recipe `sw/<pkg>` for `NEEDS`, hashing recipe for `X-fluffy.from`, and signing with release keys).
     - **Potential Simplification: Eliding `free` / `mnt_free_*` / `mnt_unref_*` Calls**:
       - Because `( ... )` subshells and `$( ... )` command substitutions in Bash fork separate child processes whose virtual address spaces are torn down by the kernel on exit—and none of `libmount`'s `mnt_free_*` / `mnt_unref_*` functions have external side effects—explicit FFI deallocation (`cleanup` + `trap cleanup EXIT`, `free`, `mnt_free_table`, `mnt_free_iter`, `mnt_free_context`, `mnt_unref_fs`) can be dropped in `swctl` (at least outside loops, or entirely given the small bounded iteration count), saving ~18–22 lines of code.
     - **Runtime / System Package Operations**:
       - Mounting software for system boot and user sessions directly from `/sw/.build/fstab`.

9. **Garbage Collection & Retention Model (`prune`)**
   - **Git-Style Lazy Garbage Collection**:
     - Upgrades and package removals do not delete active `.squashfs` files immediately. They update `/sw/.build/fstab` and rebind mounts in new namespaces.
     - Running processes continue to execute against old `.squashfs` images safely in their private mount namespaces.
   - **Pruning Policy (`<pkgmgr> prune`)**:
     - Scans `/sw/*.squashfs` periodically (cron/timer) or manually.
     - An image is a candidate for deletion if:
       1. It is no longer referenced by the active `/sw/.build/fstab`.
       2. It is not currently held open/mounted in any running mount namespace (verified via `/proc/*/mountinfo`).
       3. Optional retention window: unreferenced, unmounted images can be kept for a grace period (e.g. 30 days) to allow instant rollback to older generations.
   - **Btrfs Snapshot Protection**:
     - System generations and `/etc` are preserved via Btrfs snapshots.
     - Standard Linux POSIX file semantics ensure that even if an image is unlinked while still open in a dying namespace, its disk blocks remain allocated until the last referencing process exits.

10. **Boot Architecture: GRUB Direct-Mount, Kernel Squashfs & `fluffy-initramfs`**
    - **Kernel & Modules in `/sw/linux`**:
      - The Linux kernel and its loadable kernel modules are packaged together in `/sw/linux-<version>.squashfs` and mounted at `/sw/linux`.
      - Modules live in `/sw/linux/lib/modules/<kernel-version>/`.
    - **GRUB Squashfs & Btrfs Native Direct-Mount**:
      - GRUB natively includes filesystem drivers for both Btrfs and Squashfs (`insmod btrfs`, `insmod squash4`).
      - GRUB mounts the Btrfs root filesystem, reads `/sw/.build/fstab` to locate the active kernel squashfs (`/sw/linux-*.squashfs`), and mounts/reads the squashfs image directly on the fly.
      - GRUB streams the kernel (`vmlinuz`) and `initramfs` directly into RAM from the `.squashfs` image without requiring any intermediate unpacking on disk.
    - **The `fluffy-initramfs` Package**:
      - Built like any standard Fluffy package (`sw/fluffy-initramfs`) using `swctl build`.
      - Contains a minimal boot environment (e.g. statically linked BusyBox and a lightweight shell script, or minimal Fluffy C runtime with `libmount`).
      - Extracted or bundled directly with the kernel squashfs image.
    - **Early Boot Sequence (Prior to PID 1)**:
      1. Kernel boots and executes `/init` in `fluffy-initramfs`.
      2. Initramfs mounts the real Btrfs root at `/sysroot`.
      3. Binds the active `/etc` Btrfs subvolume/snapshot to `/sysroot/etc`.
      4. Executes `mount -a -T /sysroot/sw/.build/fstab` to mount **all** system packages under `/sysroot/sw/<pkg>`—zero special-casing for systemd or glibc.
      5. Calls `switch_root /sysroot` and executes `/sw/systemd/lib/systemd/systemd` as PID 1.
    - **Zero-Hack PID 1 Startup**:
      - `systemd` starts with all dynamic libraries (`/sw/*/lib`), unit files (`/sw/*/lib/systemd/system`), and binaries (`/sw/*/bin`) already mounted and available in `/proc/1/ns/mnt`.
      - Kernel modules load directly from `/sw/linux/lib/modules/<version>`.
      - Zero package hooks run during boot; the system starts immediately with full consistency.

11. **Network Independence & TLS Trust Store (`ca-certificates`, `openssl`, `wget`)**
    - **Single Network-Enabled Lockdown Phase (`PREPARE`)**:
      - `PREPARE` is the sole `lockdown` phase executed with network access: it runs in an isolated private mount namespace (`CLONE_NEWNS`) with a read-only root (`/`), unprivileged builder user, and `/etc/resolv.conf`, but without `CLONE_NEWNET`.
      - All subsequent phases (`MAKE`, `CHECK`, `INSTALL`, `SQUASHFS`) are strictly air-gapped via `CLONE_NEWNET`, guaranteeing hermetic, deterministic, offline builds.
      - To download source archives autonomously without host intervention, `cross-build` and `fluffy-build` incorporate `wget`, `openssl`, and `ca-certificates` in their base environment.
    - **Read-Only `/sw/<pkg>/etc` CA Trust Store**:
      - Packages never write to `/etc` during build or install.
      - Upstream Mozilla root CA bundle is packaged directly into `/sw/ca-certificates/etc/ssl/certs/ca-certificates.crt` inside the read-only `ca-certificates` squashfs image.
      - OpenSSL and Wget read certificates directly from `/sw/ca-certificates/etc/ssl/certs` (or `/sw/*/etc/ssl/certs` with `/etc/ssl/certs` overlaid), requiring zero `/etc` mutation or mount-time hooks.
    - **TODO: Universal Timestamp Preservation Across All Patches**:
      - All patches across all recipes must strictly preserve upstream file modification timestamps.
      - Applying patches must never shift file `mtime` values forward, ensuring that timestamp-sensitive dependencies (e.g. Makefile vs configure vs aclocal.m4) do not falsely trigger autotools regeneration or `help2man` rebuilds during compilation.
    - **TODO: Split Shebang / Path Patches from Logic / Bugfix Patches**:
      - Separate `/sw/bash/bin/bash` shebang and interpreter path rewrites from functional logic and bugfix patches.
      - Both types can use the `-fluffy` naming convention, e.g.:
        - `<pkg>-<version>-fluffy-shell.patch`: bulk script shebang and interpreter path adjustments.
        - `<pkg>-<version>-fluffy-<issue>.patch` (e.g. `m4-1.4.21-fluffy-posix-spawn.patch`): surgical upstream logic fixes, glibc compatibility, or testsuite adaptations.
      - Decoupling shebang updates ensures automated path updates can be regenerated cleanly with `mkbashpatch.sh` without clobbering or conflating hand-crafted code fixes.
    - **Timestamp Preservation Across Fluffy Patches**:
      - `mkbashpatch.sh` records `os.stat` timestamps and restores exact nanosecond mtimes/atimes using `os.utime()` after rewriting paths to `/sw/bash/bin/bash`.
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
  - 8.17 `expect` (5.45.4) verified and registered (`expect-5.45.4.squashfs`): TEA configured with late-bound `/sw/*/lib` and `/sw/*/include` discovery; `exec_prefix` isolated to `/sw/expect`.

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
  - Standalone network & trust stack built and verified: `ca-certificates-pass1` (2026.10.20), `openssl-pass1` (4.0.1), `wget-pass1` (1.25.0), and `signify-pass1` (32) registered into `cross-build-1.0.squashfs`.

- **Chapters 5 & 6 Toolchain Complete & Verified (`check-toolchain`)**:
  - Full cross-toolchain (`binutils-pass1`, `gcc-pass1`, `glibc-pass1`, `libstdcpp-pass1`, `linux-headers`) and temporary tools (`m4-pass1`, `ncurses-pass1`, `bash-pass1`, `libffi-pass1`, `ctypes-sh-pass1`, `coreutils-pass1`, `diffutils-pass1`, `file-pass1`, `findutils-pass1`, `gawk-pass1`, `grep-pass1`, `gzip-pass1`, `make-pass1`, `patch-pass1`, `sed-pass1`, `tar-pass1`, `xz-pass1`, `binutils-pass2`, `gcc-pass2`) are built and verified.
  - Verified via [`check-toolchain`](check-toolchain): C and C++ compilation, `<iostream>` and `<ffi.h>` inclusion, `PT_INTERP` pointing to `/sw/glibc/lib/ld-linux-x86-64.so.2`, and dynamic execution—all with zero `-I` and zero `-L` flags.
