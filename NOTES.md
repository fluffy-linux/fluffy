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
   - **New Installs vs. Package Upgrades**:
     - **Fresh Package Installs (Additions)**: Do *not* require a new mount namespace. Mounting a brand-new package at `/sw/<pkg>` carries zero risk of torn state since no active process was running against it. Combined with the shared CoW index below, newly installed commands become available immediately in existing shells.
     - **Package Upgrades (Replacements)**: Only package *upgrades* necessitate namespace isolation. Existing processes remain pinned to their older squashfs generation in their private namespace, avoiding torn shared libraries or clobbered assets until restarted.

3. **Versioned `/etc` via Btrfs Snapshots, Namespace Scoping & `fluffy-init`**
   - **Package Creation vs. Package Installation**:
     - Package creation (`create`) builds hermetically and must **never** touch `/etc`. All files install strictly into `/sw/<pkg>`. If package creation wrote to `/etc`, those files would not be in the `.squashfs` image, leaving package installation on another system missing required configuration.
     - Static configuration that literally never changes within a version goes into `/sw/<pkg>/etc/` within the read-only squashfs image (zero copy, zero state).
   - **Conventional Mount Hook (`/sw/<pkg>/bin/fluffy-init`)**:
     - When a squashfs package is mounted, the system convention executes `/sw/<pkg>/bin/fluffy-init` (using shebang `#!/sw/bash/bin/bash`).
     - It is responsible for **idempotent updates** that **strictly keep user modifications** (never blindly overwriting user-edited configuration files).
   - **Namespace-Scoped `/etc` (`/etc/<pkg>/...`) & `/var` (`/var/<pkg>/...`)**:
     - **ALL `/etc` is namespace scoped**: Every package owns and writes only to `/etc/<pkg>/...` (e.g. `/etc/make-ca/...`, `/etc/openssh/...`, including package-scoped user/group records).
     - **Sandboxed Execution**: When `fluffy-init` runs, it executes in an unshared mount namespace with root `/` and all `/sw` read-only. Writable access is dropped **strictly to `/etc/<pkg>` and `/var/<pkg>`**. It cannot mutate or corrupt any other package's `/etc` directory.
   - **Btrfs Snapshot Rollback**:
     - The root filesystem uses **btrfs**, and `/etc` is managed as versioned btrfs subvolumes/snapshots across package operations.
     - Before running `fluffy-init`, a btrfs snapshot of `/etc` (or `/etc/<pkg>`) is taken.
     - If `fluffy-init` succeeds (exit `0`), the new state is committed.
     - If `fluffy-init` fails, the snapshot is restored immediately (atomic rollback) and the package mount aborts.

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
     - **LMDB-Style Copy-on-Write `mmap` Index (`/run/fluffy/index.db`)**:
       - **Problem**: Cold traversal of `/sw/*/bin` across thousands of configure checks (e.g. 15,000 forks during Gnulib/Coreutils) performs repeated `getdents64` and `stat` calls on the filesystem.
       - **Single-Writer Multi-Reader (SWMR) CoW Architecture**:
         - `swctl` maintains an LMDB-style B+ tree index stored in a shared memory-mapped file at `/run/fluffy/index.db`.
         - **Zero-Lock, Zero-Malloc Client Traversal**: Clients (glibc `execvpe`, bash `findcmd`, ld.so) map the index read-only (`PROT_READ | MAP_SHARED`). Lookups are simple pointer traversals in memory ($O(\log N)$ or $O(1)$) with **zero mutexes, zero syscalls, and zero heap allocations**, making it 100% `vfork`/`CLONE_VM`-safe.
         - **Live In-Place Updates for Fresh Installs**: When a new package is installed, `swctl` writes new CoW tree nodes and atomically flips a single 64-bit root pointer in the header. Active shells and processes see new commands instantly without re-opening files or bouncing namespaces.

5. **Hermetic, Unprivileged Builds & Unified Tooling (`swctl build`, `./chroot.sh`)**
   - **Folding `create` into `swctl` (`swctl build`)**:
     - All package building and recipe orchestration (`create`) is unified under `swctl` (e.g. `swctl build <package>`), eliminating separate utility scripts and consolidating all repository manifest and build lifecycle management.
     - **Registration as a Build Byproduct**: With `swctl build`, registration ceases to exist as a separate manual step. Upon completing `SQUASHFS`, `swctl build` automatically signs the image, writes the `/etc/fluffy/fstab` entry (target `/sw/<pkg>`, `X-fluffy.needs`, `X-fluffy.from`, `X-fluffy.signature`), and re-signs the manifest in a single atomic transaction. Standalone registration is retained only for importing third-party or pre-built squashfs bundles.
   - **External Chroot Orchestration (`./chroot.sh`)**:
     - Host-to-chroot logic is completely extracted out of the build engine into a standalone `./chroot.sh` script.
     - `./chroot.sh` handles entering the `/mnt/fluffy` target (mounting `/dev`, `/dev/pts`, `/proc`, `/sys`, `/run`, `/tmp`, resolv.conf, binding the source repo, and mounting the base builder profile).
     - Build commands for `cross-build` and `fluffy-build` execute directly and natively inside the chroot environment. The build engine remains completely agnostic to whether it is running on a host or in a chroot, eliminating nested re-exec hacks.
   - **Unprivileged Builder Lifecycle**:
     - Immediately upon launch via `sudo`, the build engine drops real/effective UID and GID to `$SUDO_UID:$SUDO_GID` (`setresgid`/`setresuid` keeping saved UID/GID `0` only for mount setup), so all downloaded archives and extracted files under `work/` (`work/archives`, `work/src`, `work/installed`, `work/test-results`, `work/test-work`) are naturally owned by the calling user.
   - **Dependency DAG & Resolution**:
     - Package definitions in `sw/` declare runtime dependencies via `NEEDS=()` and phase-specific build dependencies via `MAKE_NEEDS=()`, `CHECK_NEEDS=()`, and `INSTALL_NEEDS=()`.
     - For each phase, the build engine mounts strictly the topological dependency closure via `swctl mount`.
   - **`PREPARE`**: Downloads and SHA-256 verifies tarballs and `file://` patches into `work/archives/`, extracts into `work/src/` as the calling user.
   - **`lockdown` (for `MAKE`, `CHECK`, `INSTALL`)**:
     - Even when running inside a chroot, `lockdown` enforces hermetic sandbox boundaries.
     - Regains saved UID `0` inside the subshell (`setresuid 0 0 0`), enters private network and mount namespaces (`unshare(CLONE_NEWNET | CLONE_NEWNS)`), sets `/` propagation to `MS_REC | MS_PRIVATE`.
     - Mounts only the resolved dependency closure for that phase under `/sw/*`.
     - Phase-specific writable mounts:
       - `MAKE`: `$wd` bind-mounted read-write at `/work`.
       - `CHECK`: `overlayfs` mounted at `/work` over `$wd` (`upperdir=$work_dir/test-results`, `workdir=$work_dir/test-work`) so tests cannot dirty the build tree before `INSTALL`, while leaving `test-results` behind on failure for inspection.
       - `INSTALL`: `$wd` bind-mounted read-write at `/work`. `$work_dir/installed` is bind-mounted at `/sw/.destdir/sw/$mount_pkg`.
     - **Universal `DESTDIR=/sw/.destdir` Staging**:
       - `DESTDIR=/sw/.destdir` and `MAKEFLAGS="$MAKEFLAGS DESTDIR=/sw/.destdir"` are exported automatically during `INSTALL`.
       - Packages install their files into `$(DESTDIR)/sw/$mount_pkg`, writing directly into `$work_dir/installed` without touching or over-mounting `/sw/$mount_pkg`.
       - Running dependencies mounted at `/sw/$mount_pkg` (such as `glibc-pass1` on `/sw/glibc` during a native `glibc` rebuild) remain fully active and accessible to dynamic linkers and maintainer utilities throughout `INSTALL`.
       - Eliminates all package collision detection and staging remapping complexity.
     - Remounts `/` read-only (`MS_BIND | MS_REMOUNT | MS_RDONLY`) and mounts a fresh private `tmpfs` at `/tmp` (with `HOME=/tmp`).
     - Permanently drops root (real, effective, and saved UID/GID all set to `$SUDO_UID:$SUDO_GID`), clearing all kernel capabilities (`CAP_SYS_ADMIN`, etc.).
   - **`SQUASHFS`**: Packs `work/installed` into `$sw_dir/$pkg-$VERSION.squashfs` directly as root in the `SQUASHFS` subshell, leaving all intermediate files owned by `$SUDO_UID:$SUDO_GID`.

6. **Self-Signed Repository Manifest as a Literal `fstab` (`/etc/fluffy/fstab`) & Embedded Trust Root**
   - The repository manifest is formatted as a single, self-signed `fstab(5)` file:
     ```fstab
     # fluffy.signature=<base64-ed25519-signature-over-remaining-lines>
     /sw/foo-1.23.squashfs /sw/foo squashfs X-mount.mkdir,X-fluffy.signature=<base64-sig>,X-fluffy.needs="bar,baz",X-fluffy.from=<sha256> 0 0
     /sw/bar-2.0.squashfs /sw/bar squashfs X-mount.mkdir,X-fluffy.signature=<base64-sig>,X-fluffy.from=<sha256> 0 0
     ```
   - **Why this design is so powerful**:
     - **Directly mountable by standard tools**: `libmount`, `mount -a -T`, and `systemd-fstab-generator` treat `#` as a comment line by default. No stripping or pre-processing is needed to use `fluffy.fstab` as a mount table.
     - **Standard Userspace Options (`X-appname.option`)**: In accordance with the `mount(8)` and `libmount` standard specification, all user-space / application-specific mount options are prefixed with `X-<appname>.<option>` without leading hyphens:
       - `X-fluffy.signature=<base64-signature>`: package-level verification signature created by signing the `.squashfs` image with `signify` at registration time.
       - `X-fluffy.needs="<dep1>,<dep2>"`: comma-separated list of runtime dependency packages.
       - `X-fluffy.from=<sha256>`: sha256 checksum of the package recipe/build file in `sw/` used to construct the squashfs image, recording recipe provenance and enabling rebuild/change detection.
     - **Compact Ed25519 signatures**: Raw Ed25519 signatures are exactly 64 bytes (88 base64 characters; 100 characters in OpenBSD signify format)—no massive ASCII armor blocks or multi-kilobyte RSA blobs.
     - **Single-file verification**: The signature on line 1 covers lines 2 through EOF. Verifying line 1 against the trusted public key validates the entire repository index in one shot (all package filenames, mountpoints, squashfs signatures, and dependency closures) without needing separate detached `.sig` files:
       ```bash
       sig=$(sed -n '1s/^# fluffy\.signature=//p' /etc/fluffy/fstab)
       # Verify lines 2..EOF against the embedded signature
       ```
     - **Trust Root / Bootstrap**: The distro release signing public key cannot live inside a package squashfs (which would be circular). Instead, it is embedded directly in the distro's minimal bootstrap script / initramfs (e.g. `/etc/fluffy/keys/release.pub`), providing the root of trust from day one.
     - **In-process parsing & mounting**: `libmount` (`<libmount/libmount.h>` called via `ctypes.sh`) parses the manifest, resolves dependencies, checks options (`X-mount.mkdir`, `X-fluffy.signature`, `X-fluffy.needs`, `X-fluffy.from`), and mounts the squashfs images directly in-process.

7. **Runtime State Separation (`/var/<pkg>`) & Dynamic Users**
   - Packages in `/sw/<pkg>` are strictly immutable, code/asset-only squashfs images packed with `-all-root` (everything owned by `root:root`).
   - Packages that require persistent mutable runtime state (databases, spools, caches) store it in `/var/<pkg>` (e.g. `/var/locate`, `/var/systemd`).
   - To avoid coordinating hardcoded static UIDs across package definitions at build time, runtime services run under dynamic users (e.g. `DynamicUser=yes` with `StateDirectory=` under systemd, or `sysusers.d` allocation at install/boot).
   - This ensures `/var/<pkg>` directories are mode `0700` and accessible only to that specific package's service, with zero UID baked into the package image itself.

8. **Pseudopackages (`*-build`), Manifest-Driven Resolution & Companion Mount Engine**
   - **Pseudopackages (Virtual Packages) with `NEEDS=(...)` Only**:
     - Packages that define *only* `NEEDS=(...)` with no `MAKE()`, `CHECK()`, or `INSTALL()`.
     - When created, pseudopackages produce an empty squashfs and register their dependency closure in `/etc/fluffy/fstab`.
     - Builder profiles encapsulate the environment for each bootstrap phase:
       - `sw/host-build`: `NEEDS=()` (pure host compilation with no `/sw` mounts).
       - `sw/cross-build`: `NEEDS=(ctypes-sh-pass1 gzip-pass1 signify-pass1 tar-pass1 util-linux-pass1 wget-pass1 xz-pass1)` (the trimmed top-level scaffold needed to run `create` and `PREPARE` inside chroot during Chapter 7; transitive dependencies like `bash-pass1`, `glibc-pass1`, `ncurses-pass1`, `openssl-pass1`, `ca-certificates-pass1`, and `coreutils-pass1` are resolved automatically).
       - `sw/fluffy-build`: `NEEDS=(ctypes-sh gzip signify tar util-linux wget xz)` (the final native Fluffy self-hosting environment).
     - Regular package definitions reference these profiles directly via `$ON`, which defaults to `fluffy-build`. `create` transitively resolves the builder profile's `NEEDS` to set up the build environment for each stage before mounting package-specific requirements.
   - **Builder Harness Isolation (`/builder`) & Rebuilt Build Dependencies**:
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
   - **Transitive Dependency Reduction (`swctl trim`)**:
     - `swctl trim <pkg...>` (or `swctl roots <pkg...>`) performs a transitive reduction over the dependency DAG recorded in `/etc/fluffy/fstab`.
     - Removes any package from the argument list that is already a direct or transitive dependency of another package in the list.
     - Supports `-1` / `--lines` for newline output, or space-separated by default.
     - Enables concise recipe definitions (`NEEDS`, `MAKE_NEEDS`, `INSTALL_NEEDS`) where only root dependencies need to be specified (e.g. specifying `bash` automatically implies `ncurses` and `glibc`; `ctypes-sh` implies `libffi` and `bash`).
   - **Strict Circular Dependency Detection & Topological Mount Order**:
     - Before performing any mount operations, `swctl mount` executes a recursive depth-first search (DFS) tracking node states (0 = unvisited, 1 = visiting/active in-stack, 2 = visited/completed).
     - Any circular dependency (direct or transitive) is rejected immediately with a fatal diagnostic displaying the exact dependency cycle path before touching mounts or namespaces.
     - Dependencies are gathered in DFS post-order, producing a strictly topological mount order where every dependency is mounted prior to the packages that depend on it.
   - **Manifest-Driven Resolution via `/etc/fluffy/fstab`**:
     - `create` stops scanning filesystem glob patterns (`/sw/"$dep"-[0-9]*.squashfs`).
     - `/etc/fluffy/fstab` is the single source of truth for all built squashfs images, mount targets, package signatures, transitive requirements (`X-fluffy.needs="dep1,dep2"`), and build recipe hashes (`X-fluffy.from="<sha256>"`).
     - After `SQUASHFS` completes, the newly created image is recorded into `/etc/fluffy/fstab` via `libmount`:
       - Newly built packages append a line.
       - Rebuilt packages or package upgrades (e.g. `pass1` -> final) perform an in-place upsert targeting the mountpoint `/sw/<pkg>`.
   - **Unified Package Manager & Build Tool (`swctl`)**:
     - All mount, unmount, loop device ioctl, namespace preparation, dependency resolution, build orchestration, and `fstab` manipulation logic is unified in `swctl`.
     - `swctl` handles both build-time operations (`swctl build`) and runtime management (`swctl mount`, `swctl register`, `swctl trim`):
       - Resolving dependency DAGs and detecting circular references.
       - Setting up the outer harness mounts for `$ON`.
       - Cleaning `/sw` inside `lockdown` and mounting strictly the phase dependency closure.
       - Upserting entries into `/etc/fluffy/fstab` on packaging completion via `swctl register <squashfs>` (automatically calculating mount target `/sw/<pkg>`, sourcing recipe `sw/<pkg>` for `NEEDS`, hashing recipe for `X-fluffy.from`, and signing with release keys).
     - **Runtime / System Package Operations**:
       - Mounting software for system boot and user sessions.
       - Orchestrating `fluffy-upsert` hooks during installs and upgrades.
       - Managing timestamp state tracking to guarantee once-only execution.
   - **`fluffy-upsert` Hook & Sandboxed Configuration Lifecycle**:
     - Packages requiring initial configuration or schema/version migrations define an idempotent `fluffy-upsert` hook.
     - **Strict Topological Dependency Ordering**:
       - When installing or upgrading packages, the package manager resolves the full dependency DAG.
       - `fluffy-upsert` hooks execute strictly in **topological dependency order**: all dependencies run their `fluffy-upsert` successfully before any dependent package's hook runs.
     - **Sandboxed Lockdown (Only `/etc/<pkg>` Writable)**:
       - The package manager executes each `fluffy-upsert` in its own isolated mount namespace (`CLONE_NEWNS` + `CLONE_NEWNET`).
       - The root filesystem `/` and all `/sw/*` mounts are strictly read-only (`MS_RDONLY`).
       - **Blast-Radius Isolation**: Only `/etc/<pkg>` is bind-mounted read-write (with `/etc` itself backed by the transaction's new Btrfs snapshot). A package hook is physically incapable of mutating, clobbering, or corrupting another package's configuration files.
     - **Once-Only Execution & Timestamp Maintenance**:
       - Handled entirely by the package manager engine.
       - Compares the modification time (`mtime`) of the `.squashfs` image against the target mount directory / state marker.
       - If the `.squashfs` image is newer than the marker:
         1. The package manager spawns the locked-down `fluffy-upsert`.
         2. Upon successful exit (code `0`), the package manager updates the state timestamp marker.
         3. If `fluffy-upsert` fails, the timestamp is not updated, the new Btrfs `/etc` snapshot is discarded, and the transaction is cleanly rolled back with zero side effects.
        - `fluffy-upsert` never runs at boot time; it executes exclusively during package manager transactions.

9. **Garbage Collection & Retention Model (`prune`)**
   - **Git-Style Lazy Garbage Collection**:
     - Upgrades and package removals do not delete active `.squashfs` files immediately. They update `/etc/fluffy/fstab` and rebind mounts in new namespaces.
     - Running processes continue to execute against old `.squashfs` images safely in their private mount namespaces.
   - **Pruning Policy (`<pkgmgr> prune`)**:
     - Scans `/sw/*.squashfs` periodically (cron/timer) or manually.
     - An image is a candidate for deletion if:
       1. It is no longer referenced by the active `/etc/fluffy/fstab`.
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
      - GRUB mounts the Btrfs root filesystem, reads `/etc/fluffy/fstab` to locate the active kernel squashfs (`/sw/linux-*.squashfs`), and mounts/reads the squashfs image directly on the fly.
      - GRUB streams the kernel (`vmlinuz`) and `initramfs` directly into RAM from the `.squashfs` image without requiring any intermediate unpacking on disk.
    - **The `fluffy-initramfs` Package**:
      - Built like any standard Fluffy package (`sw/fluffy-initramfs`) using `create`.
      - Contains a minimal boot environment (e.g. statically linked BusyBox and a lightweight shell script, or minimal Fluffy C runtime with `libmount`).
      - Extracted or bundled directly with the kernel squashfs image.
    - **Early Boot Sequence (Prior to PID 1)**:
      1. Kernel boots and executes `/init` in `fluffy-initramfs`.
      2. Initramfs mounts the real Btrfs root at `/sysroot`.
      3. Binds the active `/etc` Btrfs subvolume/snapshot to `/sysroot/etc`.
      4. Executes `mount -a -T /sysroot/etc/fluffy/fstab` to mount **all** system packages under `/sysroot/sw/<pkg>`—zero special-casing for systemd or glibc.
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
    - **Sandboxed `fluffy-upsert` & CA Trust Architecture**:
      - Packages cannot write to `/etc` directly during build/install.
      - Upstream Mozilla root CA bundle packaged directly via `ca-certificates` using `cacert.pem`.
      - On initial mount (or squashfs upgrade where `.squashfs` mtime > `/etc/<pkg>` mtime), `swctl` executes `/sw/<pkg>/bin/fluffy-upsert` inside an isolated namespace (`CLONE_NEWNS` + `CLONE_NEWNET`, root `/` read-only, only `/etc/<pkg>` read-write).
      - After upsert completion, `swctl` updates the mtime of `/etc/<pkg>`, avoiding separate timestamp state files.
      - OpenSSL and Wget are configured with wildcard CA discovery (`/etc/*/certs/ca-certificates.crt`), allowing decentralized certificates with zero `/etc` contamination.
    - **Timestamp Preservation Across Fluffy Patches**:
      - `mkbashpatch.sh` records `os.stat` timestamps and restores exact nanosecond mtimes/atimes using `os.utime()` after rewriting paths to `/sw/bash/bin/bash`.
      - Diffs are generated in UTC (`TZ=UTC0 LC_ALL=C diff -Naur`) and applied with `patch -Z` (`--set-utc`), perfectly preserving original upstream release file ordering and preventing autotools (`aclocal`, `autoheader`, `automake`) or `help2man` from falsely triggering during compilation.

## Bootstrap Milestones

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
