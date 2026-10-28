# Fluffy Packaging & System Architecture Notes

## Core Design Principles

1. **Per-Package Squashfs Images (`/sw/<pkg>`)**
   - Every package builds and installs into `/sw/<pkg>` (e.g. `/sw/man-pages`, `/sw/zlib`), which is packaged as `sw/<name>-<version>.squashfs` with `-all-root -comp zstd`.
   - At runtime and build time, the squashfs image is mounted at its unversioned mountpoint `/sw/<pkg>`.
   - Upgrading a package means mounting a newer `.squashfs` at `/sw/<pkg>` in the new mount namespace—no RPATH or path rewriting needed.

2. **Immutable Mount Namespaces (Zero Torn Installs, Zero-Logout Desktop UX)**
   - Running processes keep their existing mount namespace (`CLONE_NEWNS`) across package installs/upgrades.
   - Installing or upgrading a package updates the canonical system mount namespace (`/proc/1/ns/mnt`).
   - A running process can never experience a torn upgrade (e.g. halfway through loading shared libraries or reading data files while files change underneath).
   - **Desktop / Interactive UX**: Users do *not* need to log out to use newly installed or upgraded software. Opening a new shell/terminal tab or launching an application enters `/proc/1/ns/mnt` (`setns`), immediately forks a fresh private mount namespace (`unshare(CLONE_NEWNS)`) with `MS_PRIVATE`, and execs the shell/app—so new shells and newly launched apps see the new environment immediately while already-running apps continue uninterrupted until restarted.
   - Old `.squashfs` mounts stay alive in existing namespaces until the last process using them exits.

3. **Versioned `/etc` via Btrfs Snapshots & Idempotent Package Configuration**
   - The root filesystem uses **btrfs**, and `/etc` is managed as versioned btrfs subvolumes/snapshots across package operations:
     - Each package can provide an **idempotent configuration script/hook** responsible for installing or upgrading `/etc` configuration to account for version changes (e.g. adding users/groups, updating config files).
     - Before a package install/upgrade:
       - The previous `/etc` subvolume stays bound in old processes' mount namespaces (and is marked read-only so old processes still see the exact `/etc` they started with, and users/processes cannot mutate stale `/etc` state).
       - A new writable btrfs snapshot of `/etc` is created for the new generation, the package's idempotent config hook runs against it, and the new mount namespace binds the new `/etc` snapshot alongside the new `/sw/<pkg>` mounts.
       - If the install/config hook fails, the new snapshot is simply discarded (atomic rollback).

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
       - **Zero `-I`/`-L` Flags & Deprecation of `pkg-config`**: Because GCC, LD, and LD.SO dynamically iterate all `/sw/*/{include,lib}`, packages built for Fluffy never need `-I` or `-L` directory path flags or `pkg-config` path overrides. Upstream packages link against external libraries simply with `-l<name>`.
     - **Systemd Unit Files (`/sw/*/lib/systemd/system`)**: `systemd` (`lookup_paths_init` in `sd-path/path-lookup.c`) iterates `/sw/*/lib/systemd/system` (and `/sw/*/lib/systemd/user`) so services install their own `.service` / `.socket` files directly in `/sw/<pkg>/lib/systemd/system/` (via a heredoc or local file in `INSTALL()`), eliminating any need for external meta-packages like `blfs-systemd-units`.

5. **Hermetic, Unprivileged Builds & Dependency DAG (`create`)**
   - Immediately upon launch via `sudo`, `create` drops real/effective UID and GID to `$SUDO_UID:$SUDO_GID` (`setresgid`/`setresuid` keeping saved UID/GID `0` only for mount setup), so all downloaded archives and extracted files under `work/` (`work/archives`, `work/src`, `work/installed`, `work/test-results`, `work/test-work`) are naturally owned by the calling user.
   - Package definitions in `sw/` declare runtime dependencies via `NEEDS=()` and phase-specific build dependencies via `MAKE_NEEDS=()`, `CHECK_NEEDS=()`, and `INSTALL_NEEDS=()`.
   - For each phase, `create` starts from `${phase}_NEEDS` and transitively mounts each dependency's `NEEDS` DAG under `/sw/<pkg>` (stripping any `-pass*` suffix from the mountpoint). If a dependency's base mountpoint collides with the package being built (e.g. `binutils-pass1` when building `binutils-pass2`), the dependency is mounted at its full name (`/sw/$dep`) so the package's install mount does not shadow the toolchain.
   - `PREPARE`: Downloads and SHA-256 verifies tarballs and `file://` patches into `work/archives/`, extracts into `work/src/` as the calling user.
   - `lockdown` (for `MAKE`, `CHECK`, `INSTALL`):\n     - Briefly regains saved UID `0` inside the subshell (`setresuid 0 0 0`), enters private network and mount namespaces (`unshare(CLONE_NEWNET | CLONE_NEWNS)`), sets `/` propagation to `MS_REC | MS_PRIVATE`.
     - Mounts only the resolved dependency closure for that phase under `/sw/*`.
     - Phase-specific writable mounts:
       - `MAKE`: `$wd` bind-mounted read-write at `/work`.
       - `CHECK`: `overlayfs` mounted at `/work` over `$wd` (`upperdir=$work_dir/test-results`, `workdir=$work_dir/test-work`) so tests cannot dirty the build tree before `INSTALL`, while leaving `test-results` behind on failure for inspection.
       - `INSTALL`: `$wd` bind-mounted read-write at `/work`, plus `$work_dir/installed` bind-mounted at `/sw/$mount_pkg`.
     - Remounts `/` read-only (`MS_BIND | MS_REMOUNT | MS_RDONLY`) and mounts a fresh private `tmpfs` at `/tmp` (with `HOME=/tmp`).
     - Permanently drops root (real, effective, and saved UID/GID all set to `$SUDO_UID:$SUDO_GID`), clearing all kernel capabilities (`CAP_SYS_ADMIN`, etc.).
   - `SQUASHFS`: Packs `work/installed` into `$sw_dir/$pkg-$VERSION.squashfs` directly as root in the `SQUASHFS` subshell, leaving all intermediate files owned by `$SUDO_UID:$SUDO_GID`.

6. **Self-Signed Repository Manifest as a Literal `fstab` (`fluffy.fstab`) & Embedded Trust Root**
   - The repository manifest is formatted as a single, self-signed `fstab(5)` file:
     ```fstab
     # fluffy:sig:<base64-ed25519-signature-over-remaining-lines>
     /sw/foo-1.23.squashfs /sw/foo squashfs X-mount.mkdir,X-fluffy.sha256=abc123,X-fluffy.needs="bar,baz" 0 0
     /sw/bar-2.0.squashfs /sw/bar squashfs X-mount.mkdir,X-fluffy.sha256=def456 0 0
     ```
   - **Why this design is so powerful**:
     - **Directly mountable by standard tools**: `libmount`, `mount -a -T`, and `systemd-fstab-generator` treat `#` as a comment line by default. No stripping or pre-processing is needed to use `fluffy.fstab` as a mount table.
     - **Compact Ed25519 signatures**: Raw Ed25519 signatures are exactly 64 bytes (88 base64 characters)—no massive ASCII armor blocks or multi-kilobyte RSA blobs.
     - **Single-file verification**: The signature on line 1 covers lines 2 through EOF. Verifying line 1 against the trusted public key validates the entire repository index in one shot (all package filenames, mountpoints, SHA-256 digests, and dependency closures) without needing separate detached `.sig` files that can get out of sync or 404:
       ```bash
       sig=$(sed -n '1s/^# fluffy:sig://p' fluffy.fstab)
       sed '1d' fluffy.fstab | verify "$PUBLIC_KEY" "$sig"
       ```
     - **Trust Root / Bootstrap**: The distro release signing public key (32 bytes base64) cannot live inside a package squashfs (which would be circular). Instead, it is embedded directly in the distro's minimal bootstrap script / initramfs (e.g. `/etc/fluffy/keys/release.pub`), providing the root of trust from day one.
     - **In-process parsing & mounting**: `libmount` (`<libmount/libmount.h>` called via `ctypes.sh`) parses the manifest, resolves dependencies, checks options (`X-mount.mkdir`, `X-fluffy.sha256`, `X-fluffy.needs`), and mounts the squashfs images directly in-process.

7. **Runtime State Separation (`/var/<pkg>`) & Dynamic Users**
   - Packages in `/sw/<pkg>` are strictly immutable, code/asset-only squashfs images packed with `-all-root` (everything owned by `root:root`).
   - Packages that require persistent mutable runtime state (databases, spools, caches) store it in `/var/<pkg>` (e.g. `/var/locate`, `/var/systemd`).
   - To avoid coordinating hardcoded static UIDs across package definitions at build time, runtime services run under dynamic users (e.g. `DynamicUser=yes` with `StateDirectory=` under systemd, or `sysusers.d` allocation at install/boot).
   - This ensures `/var/<pkg>` directories are mode `0700` and accessible only to that specific package's service, with zero UID baked into the package image itself.

8. **Pseudopackages (`*-builder`), Manifest-Driven Resolution & Companion Mount Engine**
   - **Pseudopackages (Virtual Packages) with `ON=""`**:
     - Packages that define *only* `NEEDS=(...)` with no `MAKE()`, `CHECK()`, or `INSTALL()`.
     - Pseudopackages declare `ON=""` (empty) as a sentinel so `create` knows they are non-buildable dependency sets and will never recurse trying to build a builder.
     - Builder profiles encapsulate the environment for each bootstrap phase:
       - `sw/host-builder`: `ON=""`, `NEEDS=()` (pure host compilation with no `/sw` mounts).
       - `sw/bootstrap-builder`: `ON=""`, `NEEDS=(glibc-pass1 ncurses-pass1 bash-pass1 libffi-pass1 ctypes-sh-pass1 coreutils-pass1 tar-pass1 xz-pass1 gzip-pass1 ...)` (the frozen temporary toolchain scaffold needed to run `create` and `PREPARE` inside chroot during Chapters 7 & 8).
       - `sw/fluffy-builder`: `ON=""`, `NEEDS=(glibc ncurses bash libffi ctypes-sh coreutils tar xz gzip ...)` (the final native Fluffy self-hosting environment).
     - Regular package definitions reference these profiles directly via `ON=bootstrap-builder` or `ON=fluffy-builder`, completely eliminating hardcoded package lists inside `create`.
   - **Strict Circular Dependency Detection**:
     - Before performing any mount operations, the dependency traversal executes a cycle check (depth-first search tracking unvisited, active in-stack, and completed nodes).
     - Any circular dependency (direct or transitive) is rejected immediately with a fatal diagnostic displaying the exact dependency loop path before touching mounts or namespaces.
   - **Manifest-Driven Resolution via `/sw/fluffy.fstab`**:
     - `create` stops scanning filesystem glob patterns (`/sw/"$dep"-[0-9]*.squashfs`).
     - `/sw/fluffy.fstab` is the single source of truth for all built squashfs images, mount targets, checksums, and transitive requirements (`X-fluffy.needs="dep1,dep2"`).
     - After `SQUASHFS` completes, the newly created image is recorded into `/sw/fluffy.fstab` via `libmount`:
       - Newly built packages append a line.
       - Rebuilt packages or package upgrades (e.g. `pass1` -> final) perform an in-place upsert targeting the mountpoint `/sw/<pkg>`.
   - **Decoupled Companion Mount Engine (Package Manager Seed)**:
     - All mount, unmount, loop device ioctl, namespace preparation, dependency resolution, and `fstab` manipulation logic is extracted out of `create` into a standalone companion script (name TBD by user, e.g. sitting alongside `create`).
     - `create` calls this companion tool liberally:
       - Resolving dependency DAGs and detecting circular references.
       - Setting up the outer harness mounts for `$ON`.
       - Cleaning `/sw` inside `lockdown` and mounting strictly the phase dependency closure.
       - Upserting entries into `fluffy.fstab` on packaging completion.
     - **Runtime / System Package Operations**:
       - Mounting software for system boot and user sessions.
       - Orchestrating `fluffy-init` hooks during installs and upgrades.
       - Managing timestamp state tracking to guarantee once-only execution.
   - **`fluffy-init` Hook & Sandboxed Configuration Lifecycle**:
     - Packages requiring initial configuration or schema/version migrations define an idempotent `fluffy-init` hook.
     - **Strict Topological Dependency Ordering**:
       - When installing or upgrading packages, the package manager resolves the full dependency DAG.
       - `fluffy-init` hooks execute strictly in **topological dependency order**: all dependencies run their `fluffy-init` successfully before any dependent package's hook runs.
     - **Sandboxed Lockdown (Only `/etc/<pkg>` Writable)**:
       - The package manager executes each `fluffy-init` in its own isolated mount namespace (`CLONE_NEWNS` + `CLONE_NEWNET`).
       - The root filesystem `/` and all `/sw/*` mounts are strictly read-only (`MS_RDONLY`).
       - **Blast-Radius Isolation**: Only `/etc/<pkg>` is bind-mounted read-write (with `/etc` itself backed by the transaction's new Btrfs snapshot). A package hook is physically incapable of mutating, clobbering, or corrupting another package's configuration files.
     - **Once-Only Execution & Timestamp Maintenance**:
       - Handled entirely by the package manager engine.
       - Compares the modification time (`mtime`) of the `.squashfs` image against the target mount directory / state marker.
       - If the `.squashfs` image is newer than the marker:
         1. The package manager spawns the locked-down `fluffy-init`.
         2. Upon successful exit (code `0`), the package manager updates the state timestamp marker.
         3. If `fluffy-init` fails, the timestamp is not updated, the new Btrfs `/etc` snapshot is discarded, and the transaction is cleanly rolled back with zero side effects.

## Bootstrap Milestones

- **Chapter 7 In-Chroot Native Compilation Active**:
  - `zstd-pass1` and `squashfs-tools-pass1` cross-compiled with `$FLUFFY_TGT-gcc` on host.
  - `create` executes inside a pure Fluffy chroot for `ON=fluffy`, mounting a minimal 9-package base (`glibc-pass1`, `ncurses-pass1`, `bash-pass1`, `libffi-pass1`, `ctypes-sh-pass1`, `coreutils-pass1`, `tar-pass1`, `xz-pass1`, `gzip-pass1`).
  - Isolated `lockdown SQUASHFS` phase mounts strictly `SQUASHFS_NEEDS` (`squashfs-tools-pass1`, `gcc-pass2`, transitively `zstd-pass1` and `glibc-pass1`), completely isolating packaging tools from `MAKE`, `CHECK`, and `INSTALL`.
  - `gettext-pass1` (1.0) built, installed, and packaged into `gettext-pass1-1.0.squashfs` inside the chroot with zero FHS symlinks and zero `sbin`.
  - `bison-pass1` (3.8.2) built, installed, and packaged into `bison-pass1-3.8.2.squashfs` (1.7M) inside the chroot; `bison` and `yacc` verified.
  - `perl-pass1` (5.44.0) built, installed, and packaged into `perl-pass1-5.44.0.squashfs` (13M) inside the chroot; native `/sw/perl/bin/perl` verified with zero `/bin/sh` or `/usr` references.

- **Chapters 5 & 6 Toolchain Complete & Verified (`check-toolchain`)**:
  - Full cross-toolchain (`binutils-pass1`, `gcc-pass1`, `glibc-pass1`, `libstdcpp-pass1`, `linux-headers`) and temporary tools (`m4-pass1`, `ncurses-pass1`, `bash-pass1`, `libffi-pass1`, `ctypes-sh-pass1`, `coreutils-pass1`, `diffutils-pass1`, `file-pass1`, `findutils-pass1`, `gawk-pass1`, `grep-pass1`, `gzip-pass1`, `make-pass1`, `patch-pass1`, `sed-pass1`, `tar-pass1`, `xz-pass1`, `binutils-pass2`, `gcc-pass2`) are built and verified.
  - Verified via [`check-toolchain`](check-toolchain): C and C++ compilation, `<iostream>` and `<ffi.h>` inclusion, `PT_INTERP` pointing to `/sw/glibc/lib/ld-linux-x86-64.so.2`, and dynamic execution—all with zero `-I` and zero `-L` flags.

## Open Bootstrap / Init Questions (Future)

- **PID 1 (`systemd`) & Early Boot via `initramfs`**:
  - Investigate using an `initramfs` to perform early mounting before `systemd` init runs:
    - Mount the root btrfs filesystem and active `/etc` subvolume.
    - Mount `/sw/glibc`, `/sw/systemd`, and all of `systemd`'s runtime dependencies (`NEEDS` closure)—or all active system `/sw/*.squashfs` packages—under `/sw/<pkg>` in the root mount namespace before `switch_root` / `exec`ing `/sw/systemd/lib/systemd/systemd` as PID 1.
    - Because `systemd`'s dynamic interpreter is `/sw/glibc/lib/ld-linux-x86-64.so.2` and its shared libraries live in `/sw/*/lib`, having the `initramfs` set up these mounts prior to `exec`ing PID 1 means `systemd` starts naturally with zero special-case bootstrap hacks.
