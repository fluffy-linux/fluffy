#!/usr/bin/env bash
# ci/gha-agent.sh: make a GitHub-hosted runner a Fluffy CI agent for the
# gha queue, and run its jobs until it has been idle for 2 minutes.  Called by
# .github/workflows/buildkite-agent.yml, as the runner's user, which has
# passwordless sudo.
#
# The host is set up as the GCP agents' image is: by the infra repository's
# packer/provision.sh (the host tools, /sw/bash, ctypes.sh, ORAS, the
# Buildkite agent), with the versions agent.pkr.hcl pins.  Then, as the
# GCP agents' cloud-init does, the pipeline's root /mnt/ci (a bind mount of
# itself, on the runner's larger /mnt disk) and the build directory.
#
# Environment (from the workflow):
#   BUILDKITE_AGENT_TOKEN   the gha queue's own agent token (an Actions secret)
#   GHCR_TOKEN              the job's GITHUB_TOKEN, packages: write, for the
#                           binary cache
#   INFRA_REF               the infra commit to provision from (default main)
set -euo pipefail

: "${BUILDKITE_AGENT_TOKEN:?the agent token of the gha queue}"
: "${GHCR_TOKEN:?a token that can write ghcr.io/fluffy-linux/sw}"
INFRA_REF="${INFRA_REF:-main}"

echo "--- disk"
# The runner image's preinstalled SDKs stay: removing them took 2.5
# minutes, and without that a runner still has about 65 GB free.
df -h / /mnt

echo "--- provision (infra $INFRA_REF)"
infra=/tmp/fluffy-infra
rm -rf "$infra"
git init -q "$infra"
git -C "$infra" fetch -q --depth 1 https://github.com/fluffy-linux/infra.git "$INFRA_REF"
git -C "$infra" checkout -q FETCH_HEAD
pin() {
    awk -v v="$1" '$1 == "variable" && $2 == "\"" v "\"" { f = 1 }
        f && $1 == "default" { gsub(/"/, "", $3); print $3; exit }' "$infra/packer/agent.pkr.hcl"
}
sudo mkdir -p /tmp/fluffy-ci
sudo cp -r "$infra/packer/files/." /tmp/fluffy-ci/
sudo env DEBIAN_FRONTEND=noninteractive \
    CTYPES_SH_COMMIT="$(pin ctypes_sh_commit)" ORAS_VERSION="$(pin oras_version)" \
    ORAS_SHA256="$(pin oras_sha256)" bash "$infra/packer/provision.sh" > /tmp/provision.log 2>&1 \
    || { tail -40 /tmp/provision.log; exit 1; }
tail -3 /tmp/provision.log

echo "--- kvm"
# GitHub's Linux runners have /dev/kvm; let the agent's user open it, as
# GitHub's documentation does.
echo 'KERNEL=="kvm", GROUP="kvm", MODE="0666", OPTIONS+="static_node=kvm"' \
    | sudo tee /etc/udev/rules.d/99-kvm4all.rules > /dev/null
sudo udevadm control --reload-rules
sudo udevadm trigger --name-match=kvm
ls -l /dev/kvm

echo "--- root"
sudo mkdir -p /mnt/ci /mnt/buildkite/builds
sudo chown "$(id -u):$(id -g)" /mnt/buildkite /mnt/buildkite/builds
grep -q ' /mnt/ci ' /etc/fstab || echo '/mnt/ci /mnt/ci none bind 0 0' | sudo tee -a /etc/fstab > /dev/null
mountpoint -q /mnt/ci || sudo mount /mnt/ci
sudo install -d -m 700 /run/fluffy-ci
printf '%s' "$GHCR_TOKEN" | sudo tee /run/fluffy-ci/ghcr-token > /dev/null
sudo chmod 600 /run/fluffy-ci/ghcr-token

echo "--- agent"
# Jobs back to back while the gha queue has them, as the GCP agents do:
# setting a runner up takes about 2 minutes, and most of a world's steps
# take seconds.  After 2 minutes with no job, the agent exits and the run
# ends (and at the latest at the job's 350-minute limit).
export FLUFFY_CACHE_REGISTRY=ghcr.io/fluffy-linux/sw
export FLUFFY_CACHE_TOKEN_FILE=/run/fluffy-ci/ghcr-token
exec buildkite-agent start \
    --tags queue=gha \
    --name "gha-%hostname-%spawn" \
    --build-path /mnt/buildkite/builds \
    --disconnect-after-idle-timeout 120
