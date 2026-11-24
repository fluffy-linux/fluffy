"""Starts Fluffy's CI agent VMs to meet Buildkite's queue.

Called every minute (Cloud Scheduler): read Buildkite's agent metrics and
start agent VMs until the queue has as many as it needs (busy agents plus
jobs scheduled and waiting for one), never more than the cap.  It never
deletes a VM: agents leave on their own, after 10 idle minutes each exits
and deletes its VM; spot VMs are also deleted when preempted, and every
agent at its maximum run duration.

Settings (environment, from infra/terraform/scaler.tf):
  PROJECT, ZONES (comma-separated, tried in turn), TEMPLATES (JSON: each
  zone's instance template name; one template per region, for its
  subnet), QUEUE, MAX_INSTANCES
"""

import base64
import json
import logging
import os
import secrets
import urllib.error
import urllib.parse
import urllib.request

METADATA = "http://metadata.google.internal/computeMetadata/v1"
COMPUTE = "https://compute.googleapis.com/compute/v1"
SECRETS = "https://secretmanager.googleapis.com/v1"
BUILDKITE_METRICS = "https://agent.buildkite.com/v3/metrics"

# What counts as an agent the queue has: VMs starting or running.  A VM
# stopping or terminated is leaving.
LIVE = {"PROVISIONING", "STAGING", "RUNNING"}


def _request(method, url, headers, body=None):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    if data is not None:
        req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, timeout=30) as resp:
        text = resp.read().decode()
    return json.loads(text) if text else {}


def _google():
    token = _request("GET", f"{METADATA}/instance/service-accounts/default/token",
                     {"Metadata-Flavor": "Google"})["access_token"]
    return {"Authorization": "Bearer " + token}


def _secret(google, project, name):
    reply = _request("GET", f"{SECRETS}/projects/{project}/secrets/{name}/versions/latest:access", google)
    return base64.b64decode(reply["payload"]["data"]).decode().strip()


def _live_agents(google, project, queue):
    url = (f"{COMPUTE}/projects/{project}/aggregated/instances"
           f"?filter=labels.fluffy-ci%3Dagent%20AND%20labels.queue%3D{queue}")
    names = []
    while url:
        reply = _request("GET", url, google)
        for scope in reply.get("items", {}).values():
            names += [i["name"] for i in scope.get("instances", []) if i["status"] in LIVE]
        token = reply.get("nextPageToken")
        url = f"{url.split('&pageToken=')[0]}&pageToken={token}" if token else None
    return names


def _start_agent(google, settings):
    """Create one agent VM, in the first zone that takes it.

    A zone can refuse at once (an HTTP error) or later, in the operation:
    quota and spot capacity are usually reported there.  So wait for each
    create to finish before trying the next zone.
    """
    name = "fluffy-ci-agent-" + secrets.token_hex(4)
    project = settings["project"]
    errors = []
    for zone in settings["zones"]:
        template = urllib.parse.quote(
            f"projects/{project}/global/instanceTemplates/{settings['templates'][zone]}", safe="")
        url = f"{COMPUTE}/projects/{project}/zones/{zone}/instances?sourceInstanceTemplate={template}"
        try:
            op = _request("POST", url, google, {"name": name})
            # operations/wait returns when the operation is done, or after
            # about 2 minutes; creates finish well within that.
            op = _request("POST", f"{COMPUTE}/projects/{project}/zones/{zone}/operations/{op['name']}/wait",
                          google)
        except urllib.error.HTTPError as e:
            errors.append(f"{zone}: {e.code} {e.read().decode()[:300]}")
            continue
        if op.get("status") == "DONE" and "error" not in op:
            return f"{zone}/{name}"
        errors.append(f"{zone}: {json.dumps(op.get('error', op.get('status')))[:300]}")
    raise RuntimeError("no zone took an agent: " + "; ".join(errors))


def scale(settings):
    google = _google()
    token = _secret(google, settings["project"], "buildkite-agent-token")
    metrics = _request("GET", BUILDKITE_METRICS, {"Authorization": "Token " + token})

    queue = settings["queue"]
    busy = int(metrics.get("agents", {}).get("queues", {}).get(queue, {}).get("busy", 0))
    scheduled = int(metrics.get("jobs", {}).get("queues", {}).get(queue, {}).get("scheduled", 0))
    needed = min(settings["max"], busy + scheduled)
    live = _live_agents(google, settings["project"], queue)

    started = [_start_agent(google, settings) for _ in range(needed - len(live))]
    return {"queue": queue, "busy": busy, "scheduled": scheduled,
            "live": len(live), "started": started}


def settings_from_env():
    return {
        "project": os.environ["PROJECT"],
        "zones": os.environ["ZONES"].split(","),
        "templates": json.loads(os.environ["TEMPLATES"]),
        "queue": os.environ["QUEUE"],
        "max": int(os.environ["MAX_INSTANCES"]),
    }


def scale_agents(request):
    """HTTP entry point (Cloud Functions)."""
    logging.getLogger().setLevel(logging.INFO)
    result = scale(settings_from_env())
    logging.info("fluffy-ci scaler: %s", json.dumps(result))
    return json.dumps(result), 200, {"Content-Type": "application/json"}
