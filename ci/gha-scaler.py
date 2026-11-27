#!/usr/bin/env python3
"""ci/gha-scaler.py: start GitHub-hosted runners for the gha queue's jobs.

Run by .github/workflows/buildkite-agent.yml's scaler job, one per branch
(its concurrency group), on a push and every 15 minutes.  Every 30 s it
reads the gha queue from Buildkite's agent metrics and starts agent runs
of the same workflow (workflow_dispatch) while jobs wait beyond the idle
agents and the agent runs not yet started, keeping at most MAX agent runs
in flight.  Being the only one deciding, the cap is exact.  It exits after
QUIET seconds with no job waiting or running and no agent run in flight.

Environment: BUILDKITE_AGENT_TOKEN (any agent token of the cluster, for the
metrics), GITHUB_TOKEN (actions: write), GITHUB_REPOSITORY, GITHUB_REF_NAME;
MAX (4) and QUIET (300) optional.  The tokens are never printed.
"""
import json, os, time, urllib.request

BK, GH = os.environ["BUILDKITE_AGENT_TOKEN"], os.environ["GITHUB_TOKEN"]
REPO, REF = os.environ["GITHUB_REPOSITORY"], os.environ["GITHUB_REF_NAME"]
MAX, QUIET = int(os.environ.get("MAX", "4")), int(os.environ.get("QUIET", "300"))
API = f"https://api.github.com/repos/{REPO}/actions/workflows/buildkite-agent.yml"


def call(url, auth, method="GET", body=None):
    req = urllib.request.Request(url, method=method,
        headers={"Authorization": auth, "Accept": "application/vnd.github+json"},
        data=None if body is None else json.dumps(body).encode())
    with urllib.request.urlopen(req, timeout=30) as resp:
        text = resp.read()
        return json.loads(text) if text else {}


quiet_since = time.time()
while True:
    try:
        m = call("https://agent.buildkite.com/v3/metrics", "Token " + BK)
        jobs = m.get("jobs", {}).get("queues", {}).get("gha", {})
        agents = m.get("agents", {}).get("queues", {}).get("gha", {})
        waiting, running = int(jobs.get("scheduled", 0)), int(jobs.get("running", 0))
        idle = int(agents.get("idle", 0))
        runs = [r for s in ("queued", "in_progress")
                for r in call(f"{API}/runs?status={s}&event=workflow_dispatch&per_page=50",
                              "Bearer " + GH).get("workflow_runs", [])]
        queued = sum(1 for r in runs if r["status"] == "queued")
        want = max(0, min(waiting - idle - queued, MAX - len(runs)))
        for _ in range(want):
            call(f"{API}/dispatches", "Bearer " + GH, "POST", {"ref": REF})
        print(time.strftime("%H:%M:%S"), f"waiting={waiting} running={running} idle={idle} "
              f"agent runs={len(runs)} (queued {queued}): started {want}", flush=True)
        if waiting or running or runs:
            quiet_since = time.time()
        elif time.time() - quiet_since >= QUIET:
            print("quiet: done", flush=True)
            break
    except Exception as e:
        print(time.strftime("%H:%M:%S"), "error:", type(e).__name__, flush=True)
    time.sleep(30)
