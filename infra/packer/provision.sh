#!/usr/bin/env bash
# Provisions the CI agent image (run by Packer as root).
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get -y upgrade

# Host tools.  LFS's host requirements (bash, binutils, bison, coreutils,
# diffutils, findutils, gawk, gcc, grep, gzip, m4, make, patch, perl,
# python3, sed, tar, texinfo, xz), and what Fluffy's host-build recipes and
# swctl use besides: the autotools (host-build regenerates with them), git
# (swctl fetches sources), flex (binutils-pass1 and -pass2, built from git,
# generate ld's and binutils' lexers), gettext and autopoint (the pass1
# builds of packages from git run autopoint in autoreconf, before Fluffy's
# own gettext is built), curl, squashfs-tools (host-build packages are
# packaged with the host's mksquashfs), and ctypes.sh's build dependencies.
apt-get -y install --no-install-recommends \
    autoconf automake autopoint bison build-essential bzip2 ca-certificates curl \
    flex gawk gettext git gnupg gzip libdw-dev libelf-dev libffi-dev libltdl-dev libtool m4 patch \
    perl pkg-config python3 squashfs-tools texinfo xz-utils zlib1g-dev

# swctl runs with /sw/bash/bin/bash, and Fluffy has no /bin/sh: on the host
# both are the host's bash.
install -d -m 755 /sw/bash/bin
ln -sfn /usr/bin/bash /sw/bash/bin/bash
ln -sfn bash /sw/bash/bin/sh

# ctypes.sh, which swctl loads (enable -f ctypes.so), from Fluffy's fork.
git init -q /tmp/ctypes.sh
git -C /tmp/ctypes.sh fetch -q --depth 1 \
    https://github.com/fluffy-linux/ctypes.sh.git "$CTYPES_SH_COMMIT"
git -C /tmp/ctypes.sh checkout -q FETCH_HEAD
# In git, configure is a placeholder: regenerate it (its autogen.sh), with
# the image's autotools.
(cd /tmp/ctypes.sh && autoreconf -vif && ./configure && make && make install)
ldconfig
rm -rf /tmp/ctypes.sh

# ORAS, which swctl publishes the binary cache's images with (pinned
# release, checked against its published checksum; mirrored as
# fluffy-linux/oras).
curl -fsSL -o /tmp/oras.tar.gz \
    "https://github.com/oras-project/oras/releases/download/v$ORAS_VERSION/oras_${ORAS_VERSION}_linux_amd64.tar.gz"
echo "$ORAS_SHA256  /tmp/oras.tar.gz" | sha256sum -c -
tar -xzf /tmp/oras.tar.gz -C /usr/local/bin oras
rm -f /tmp/oras.tar.gz
oras version

# The Buildkite agent, from Buildkite's apt repository (its Ubuntu install
# instructions).
curl -fsSL https://keys.openpgp.org/vks/v1/by-fingerprint/32A37959C2FA5C3C99EFBC32A79206696452D198 \
    | gpg --dearmor -o /usr/share/keyrings/buildkite-agent-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/buildkite-agent-archive-keyring.gpg] https://apt.buildkite.com/buildkite-agent stable main" \
    > /etc/apt/sources.list.d/buildkite-agent.list
apt-get update
apt-get -y install buildkite-agent

# Fluffy's agent configuration and boot scripts.  The per-VM settings
# (queue, Key Vault, identity) come from /etc/fluffy-ci/agent.env, which
# the scale set's custom data writes; without it the agent never starts.
install -m 644 /tmp/fluffy-ci/buildkite-agent.cfg /etc/buildkite-agent/buildkite-agent.cfg
install -m 755 /tmp/fluffy-ci/fluffy-ci-agent-token /usr/local/sbin/fluffy-ci-agent-token
install -m 755 /tmp/fluffy-ci/fluffy-ci-self-delete /usr/local/sbin/fluffy-ci-self-delete
install -d -m 755 /etc/systemd/system/buildkite-agent.service.d
install -m 644 /tmp/fluffy-ci/buildkite-agent-fluffy.conf \
    /etc/systemd/system/buildkite-agent.service.d/fluffy.conf
# The pipeline runs bootstrap.sh and swctl with sudo, as today's agent does.
install -m 440 /tmp/fluffy-ci/sudoers /etc/sudoers.d/buildkite-agent
visudo -cf /etc/sudoers.d/buildkite-agent
systemctl enable buildkite-agent

rm -rf /tmp/fluffy-ci
apt-get clean
rm -rf /var/lib/apt/lists/*
