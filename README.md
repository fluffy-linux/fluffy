# Fluffy Linux

it's not ready yet

[![Build status](https://badge.buildkite.com/ecf03d84bc955375d96d639148f973c571271791dbafb4d90c.svg)](https://buildkite.com/fluffy-linux/fluffy)

## Prior art

TODO: write up how each compares with Fluffy. Known so far:

- **Linux From Scratch**: Fluffy's baseline (LFS 13.1-systemd) for versions,
  build steps and patches.
- **distri** (Michael Stapelberg): one read-only SquashFS image per package,
  mounted at run time, the closest to Fluffy's package model.  It finds
  dependencies by exact versioned paths and FUSE exchange directories, where
  Fluffy searches `/sw/*/...` globs.
- **GoboLinux**: each package in its own tree, `/Programs/<Name>/<Version>`.
- **Nix** and **Guix**: sources pinned by commit and content hash, and a
  content-addressed binary cache.
- **Yocto / OpenEmbedded**: recipes that take a git URL plus an exact
  revision (`SRCREV`), like Fluffy's ARCHIVES git entries.
- **Fedora / CentOS source-git** (Packit): a package as upstream's git with
  the distribution's changes as commits on it.
- **Debian**: `git-buildpackage` patch queues and **dgit**.
- **git-ubuntu**: every published Ubuntu source package version imported
  into git, like Fluffy's replays of release tarballs.
