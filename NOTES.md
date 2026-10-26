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

4. **No Symlink Farms & Static `PATH` via `@SW`**
   - Instead of symlink farms or huge dynamic `PATH`/`PKG_CONFIG_PATH`/`CFLAGS` variables, core tools understand the `/sw/*` layout natively:
     - **`PATH` (`@SW` sentinel)**: `glibc` (`execvp`/`execvpe`/`posix_spawnp`), `bash`, and `which` expand `@SW` to `/sw/*/bin` (and `/sw/*/sbin`). Because a process's mount namespace never changes during its lifetime, the `/sw/*` traversal can be cached once per process.
     - **Dynamic linker (`ld.so`)**: Iterates `/sw/*/lib` to resolve shared libraries at runtime.
     - **Linker (`binutils` `ld`) & Compiler (`gcc`)**: Linker scripts and compiler search paths iterate `/sw/*/lib` and `/sw/*/include` (and `/sw/glibc/lib` for startfiles `crt1.o`/`crti.o`/`crtn.o` and `PT_INTERP` `/sw/glibc/lib/ld-linux-x86-64.so.2`).
     - **Result**: `pkg-config` becomes mostly unnecessary because headers and libraries are discovered automatically from whichever `/sw/<pkg>` mounts exist in the current mount namespace.

5. **Hermetic, Unprivileged Builds (`build/create`)**
   - `PREPARE`: Downloads and MD5-verifies tarballs into `archives/`, extracts into `work/` owned by `builder:builder`.
   - `lockdown` (for `MAKE`, `CHECK`, `INSTALL`):
     - Enters private network and mount namespaces (`unshare(CLONE_NEWNET | CLONE_NEWNS)`), sets `/` propagation to `MS_REC | MS_PRIVATE`.
     - Mounts only the declared dependencies (`MAKE_NEEDS`, `CHECK_NEEDS`, `INSTALL_NEEDS`) under `/sw/*` (TODO).
     - Phase-specific writable mounts:
       - `MAKE`: `$wd` bind-mounted read-write.
       - `CHECK`: `overlayfs` mounted over `$wd` (`upperdir=$root/work/test-results`, `workdir=$root/work/test-work`) so tests cannot dirty the build tree before `INSTALL`, while leaving `test-results` behind on failure for inspection.
       - `INSTALL`: `$wd` bind-mounted read-write, plus `$root/work/installed` bind-mounted at `/sw/$pkg`.
     - Remounts `/` read-only (`MS_BIND | MS_REMOUNT | MS_RDONLY`) and mounts a fresh private `tmpfs` at `/tmp`.
     - Drops supplementary groups and switches to `builder:builder` (`setgroups`, `setresgid`, `setresuid`), clearing all capabilities (`CAP_SYS_ADMIN`, etc.).
   - `SQUASHFS`: Packs `$root/work/installed` into `sw/<archive_name>.squashfs`.

## Open Bootstrap / Init Questions (Future)

- **Bootstrapping into pure `/sw/*`**:
  - Need a transition path from the current LFS `/usr` environment (either via `Dockerfile` cross/temp-tools stage that targets `/sw/glibc`, `/sw/gcc`, `/sw/binutils`, `/sw/bash`, or a nested chroot/root image).
- **PID 1 (`systemd`) & Early Boot**:
  - `systemd` needs `/sw/*` mounted before execing (or an initramfs / tiny static init helper that mounts the `/sw/*.squashfs` packages and `exec`s `/sw/systemd/...` + `systemctl daemon-reexec` on package changes).
