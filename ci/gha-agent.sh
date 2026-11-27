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
#   GHCR_TOKEN              the job's GITHUB_TOKEN: packages: write for the
#                           binary cache, actions: write for the scaler
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
# The agent's own token, in a file only this user can read (the build
# chroot can't see the host's /run).  The agent itself starts with a clean
# environment, so no job inherits a token: not BUILDKITE_AGENT_TOKEN, not
# GITHUB_TOKEN, not the Actions runtime's.
agent_cfg=/run/fluffy-ci-agent.cfg
sudo install -m 600 -o "$(id -u)" -g "$(id -g)" /dev/null "$agent_cfg"
printf 'token="%s"\n' "$BUILDKITE_AGENT_TOKEN" > "$agent_cfg"

# The scaler, in every runner: every 30 s, while gha has more jobs waiting
# than idle agents and runs not yet started, start more runs of this
# workflow (workflow_dispatch, which GITHUB_TOKEN may trigger), up to
# about SCALE_MAX in flight.  A soft cap: two runners deciding at once can
# go one over.  New jobs only become runnable when a running one finishes,
# and its runner lives 2 more minutes, so some runner always sees them.
cat > /tmp/gha-scale.py << "PYEOF"
import json, os, time, urllib.request
BK, GH = os.environ["SCALE_BK"], os.environ["SCALE_GH"]
REPO, REF = os.environ["GITHUB_REPOSITORY"], os.environ["SCALE_REF"]
MAX = int(os.environ.get("SCALE_MAX", "4"))
API = f"https://api.github.com/repos/{REPO}/actions/workflows/buildkite-agent.yml"

def call(url, auth, method="GET", body=None):
    req = urllib.request.Request(url, method=method,
        headers={"Authorization": auth, "Accept": "application/vnd.github+json"},
        data=None if body is None else json.dumps(body).encode())
    with urllib.request.urlopen(req, timeout=30) as resp:
        text = resp.read()
        return json.loads(text) if text else {}

while True:
    try:
        m = call("https://agent.buildkite.com/v3/metrics", "Token " + BK)
        waiting = int(m.get("jobs", {}).get("queues", {}).get("gha", {}).get("scheduled", 0))
        idle = int(m.get("agents", {}).get("queues", {}).get("gha", {}).get("idle", 0))
        runs = [r for s in ("queued", "in_progress")
                for r in call(f"{API}/runs?status={s}&per_page=50", "Bearer " + GH).get("workflow_runs", [])]
        queued = sum(1 for r in runs if r["status"] == "queued")
        want = min(waiting - idle - queued, MAX - len(runs))
        for _ in range(max(want, 0)):
            call(f"{API}/dispatches", "Bearer " + GH, "POST", {"ref": REF})
        if want > 0:
            print(f"scale: waiting={waiting} idle={idle} runs={len(runs)}: started {want}", flush=True)
    except Exception as e:
        print("scale: error:", type(e).__name__, flush=True)
    time.sleep(30)
PYEOF
SCALE_BK="$BUILDKITE_AGENT_TOKEN" SCALE_GH="$GHCR_TOKEN" SCALE_REF="$GITHUB_REF_NAME" \
    python3 -I /tmp/gha-scale.py &
scaler=$!
trap 'kill "$scaler" 2>/dev/null || true' EXIT

# Jobs back to back while the gha queue has them, as the GCP agents do:
# setting a runner up takes about 2 minutes, and most of a world's steps
# take seconds.  After 2 minutes with no job, the agent exits and the run
# ends (and at the latest at the job's 350-minute limit).
env -i PATH="$PATH" HOME="$HOME" USER="$USER" LANG=C.UTF-8 \
    FLUFFY_CACHE_REGISTRY=ghcr.io/fluffy-linux/sw \
    FLUFFY_CACHE_TOKEN_FILE=/run/fluffy-ci/ghcr-token \
    buildkite-agent start \
        --config "$agent_cfg" \
        --tags queue=gha \
        --name "gha-%hostname-%spawn" \
        --build-path /mnt/buildkite/builds \
        --disconnect-after-idle-timeout 120
