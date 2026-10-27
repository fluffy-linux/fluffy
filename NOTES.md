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
     - **`PATH` (`@SW` sentinel)**: `glibc` (`execvp`/`execvpe`/`posix_spawnp`), `bash`, and `which` expand `@SW` to `/sw/*/bin` (and `/sw/*/sbin`), cached once per process.
     - **Dynamic linker (`ld.so`)**: Iterates `/sw/*/lib` (`_dl_init_paths`) to resolve shared libraries at runtime.
     - **Linker (`binutils` `ld`) & Compiler (`gcc`)**: Linker scripts and compiler search paths iterate `/sw/*/lib`, `/sw/*/include` (and `/sw/*/include/c++/<ver>` for C++ headers), and `/sw/*/bin` (plus `/sw/*/<target>/bin`)—requiring zero `-I`, `-L`, or `--with-*` path flags in package definitions.

5. **Hermetic, Unprivileged Builds & Dependency DAG (`create`)**
   - Immediately upon launch via `sudo`, `create` drops real/effective UID and GID to `$SUDO_UID:$SUDO_GID` (`setresgid`/`setresuid` keeping saved UID/GID `0` only for mount setup), so all downloaded archives and extracted files under `work/` (`work/archives`, `work/src`, `work/installed`, `work/test-results`, `work/test-work`) are naturally owned by the calling user.
   - Package definitions in `sw/` declare runtime dependencies via `NEEDS=()` and phase-specific build dependencies via `MAKE_NEEDS=()`, `CHECK_NEEDS=()`, and `INSTALL_NEEDS=()`.
   - For each phase, `create` starts from `${phase}_NEEDS` and transitively mounts each dependency's `NEEDS` DAG under `/sw/<pkg>` (stripping any `-pass*` suffix from the mountpoint).
   - `PREPARE`: Downloads and SHA-256 verifies tarballs and `file://` patches into `work/archives/`, extracts into `work/src/` as the calling user.
   - `lockdown` (for `MAKE`, `CHECK`, `INSTALL`):
     - Briefly regains saved UID `0` inside the subshell (`setresuid 0 0 0`), enters private network and mount namespaces (`unshare(CLONE_NEWNET | CLONE_NEWNS)`), sets `/` propagation to `MS_REC | MS_PRIVATE`.
     - Mounts only the resolved dependency closure for that phase under `/sw/*`.
     - Phase-specific writable mounts:
       - `MAKE`: `$wd` bind-mounted read-write at `/work`.
       - `CHECK`: `overlayfs` mounted at `/work` over `$wd` (`upperdir=$work_dir/test-results`, `workdir=$work_dir/test-work`) so tests cannot dirty the build tree before `INSTALL`, while leaving `test-results` behind on failure for inspection.
       - `INSTALL`: `$wd` bind-mounted read-write at `/work`, plus `$work_dir/installed` bind-mounted at `/sw/$mount_pkg`.
     - Remounts `/` read-only (`MS_BIND | MS_REMOUNT | MS_RDONLY`) and mounts a fresh private `tmpfs` at `/tmp` (with `HOME=/tmp`).
     - Permanently drops root (real, effective, and saved UID/GID all set to `$SUDO_UID:$SUDO_GID`), clearing all kernel capabilities (`CAP_SYS_ADMIN`, etc.).
   - `SQUASHFS`: Packs `work/installed` into `work/$pkg-$VERSION.squashfs` as the calling user and moves it into `$sw_dir/$pkg-$VERSION.squashfs`.

6. **Future Evolution: `fluffy.fstab` as Build & Package Repository Manifest (`X-fluffy.*` + `libmount`)**
   - The repository/package manifest (`fluffy.fstab`)(`fluffy.fstab`) willwill bebe a literalliteral `fstab(5)` file, storing package metadata in `util-linux` `X-*` userspace comment mount options:
     ```fstab
     /sw/foo-1.23.squashfs /sw/foo squashfs X-mount.mkdir,X-fluffy.sha256=abc123,X-fluffy.needs="bar,baz" 0 0
     ```
   - **`build/create` Integration (Replacing Manual `build/sw/*` Sourcing)**:
     - At the end of `SQUASHFS`, `build/create` can update `fluffy.fstab` in place using `libmount` (`mnt_new_table_from_file`, `mnt_table_find_target`, `mnt_fs_set_source`, `mnt_fs_set_options`, `mnt_table_replace_file`) via `ctypes.sh`.
     - Keying entries by target mountpoint (`/sw/<pkg>`) means bootstrap passes (`gcc-pass1` -> `gcc-pass2` -> `gcc`) simply update the `.squashfs` backing `/sw/gcc` in `fluffy.fstab`, so downstream packages can declare canonical names (`MAKE_NEEDS=(gcc)`) without `-pass*` suffixes.
     - In `lockdown()`, instead of sourcing `build/sw/$need_pkg` scripts to discover `$VERSION` and `NEEDS=()` and manually locating `.squashfs` files, `lockdown()` can read `fluffy.fstab` directly to resolve `X-fluffy.needs` and mount the dependency closure by target (e.g. `mount -T fluffy.fstab /sw/{foo,bar,baz}` or via `libmount` `mnt_context_mount` in `ctypes.sh`).
   - **Package Manager (`apt-get`-ish Tool) & Boot Integration**:
     - Using `libmount` (`dlopen libmount.so.1` via `ctypes.sh` or C), an installer/updater can parse a remote `fluffy.fstab`, walk `X-fluffy.needs`, download missing `.squashfs` images, and verify `X-fluffy.sha256`.
     - Producing the system's active mount table (e.g. for `fstab` / `fstab.d` or `mount -a -T ...`) is literally just filtering/grepping the desired package lines out of `fluffy.fstab`.
   - **`create` Integration (Replacing Manual `sw/*` Sourcing)**:
     - At the end of `SQUASHFS`, `create` can update `fluffy.fstab` in place using `libmount` (`mnt_new_table_from_file`, `mnt_table_find_target`, `mnt_fs_set_source`, `mnt_fs_set_options`, `mnt_table_replace_file`) via `ctypes.sh`.
     - Keying entries by target mountpoint (`/sw/<pkg>`) means bootstrap passes (`gcc-pass1` -> `gcc-pass2` -> `gcc`) simply update the `.squashfs` backing `/sw/gcc` in `fluffy.fstab`, so downstream packages can declare canonical names (`MAKE_NEEDS=(gcc)`) without `-pass*` suffixes.
     - In `lockdown()`, instead of sourcing `sw/$need_pkg` scripts to discover `$VERSION` and `NEEDS=()` and manually locating `.squashfs` files, `lockdown()` can read `fluffy.fstab` directly to resolve `X-fluffy.needs` and mount the dependency closure by target (e.g. `mount -T fluffy.fstab /sw/{foo,bar,baz}` or via `libmount` `mnt_context_mount` in `ctypes.sh`).
   - **Package Manager (`apt-get`-ish Tool) & Boot Integration**:
     - Using `libmount` (`dlopen libmount.so.1` via `ctypes.sh` or C), an installer/updater can parse a remote `fluffy.fstab`, walk `X-fluffy.needs`, download missing `.squashfs` images, and verify `X-fluffy.sha256`.
     - Producing the system's active mount table (e.g. for `fstab` / `fstab.d` or `mount -a -T ...`) is literally just filtering/grepping the desired package lines out of `fluffy.fstab`.

## Open Bootstrap / Init Questions (Future)

- **PID 1 (`systemd`) & Early Boot via `initramfs`**:
  - Investigate using an `initramfs` to perform early mounting before `systemd` init runs:
    - Mount the root btrfs filesystem and active `/etc` subvolume.
    - Mount `/sw/glibc`, `/sw/systemd`, and all of `systemd`'s runtime dependencies (`NEEDS` closure)—or all active system `/sw/*.squashfs` packages—under `/sw/<pkg>` in the root mount namespace before `switch_root` / `exec`ing `/sw/systemd/lib/systemd/systemd` as PID 1.
    - Because `systemd`'s dynamic interpreter is `/sw/glibc/lib/ld-linux-x86-64.so.2` and its shared libraries live in `/sw/*/lib`, having the `initramfs` set up these mounts prior to `exec`ing PID 1 means `systemd` starts naturally with zero special-case bootstrap hacks.
