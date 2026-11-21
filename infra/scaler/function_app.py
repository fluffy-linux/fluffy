"""Scales Fluffy's CI agent scale sets up to meet Buildkite's queues.

Every minute: read Buildkite's agent metrics, and for each queue raise its
scale set's size to the agents it needs (busy agents plus jobs scheduled
and waiting for one), never above the scale set's cap.  It never lowers a
size: lowering would let Azure pick a VM to remove, possibly one running a
job.  Agents leave on their own: after 10 idle minutes each exits and
deletes its VM.

Settings (app settings, from infra/terraform/scaler.tf):
  SCALER_IDENTITY_CLIENT_ID  the function's user-assigned managed identity
  KEY_VAULT                  vault holding the secret buildkite-agent-token
  SUBSCRIPTION_ID, RESOURCE_GROUP
  SCALE_SETS                 JSON: {"<buildkite queue>": {"vmss": "<name>", "max": <n>}}
"""

import json
import logging
import os
import urllib.request

import azure.functions as func
from azure.identity import ManagedIdentityCredential

app = func.FunctionApp()

ARM = "https://management.azure.com"
ARM_API = "2024-07-01"
BUILDKITE_METRICS = "https://agent.buildkite.com/v3/metrics"


def _request(method, url, headers, body=None):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    if data is not None:
        req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, timeout=30) as resp:
        text = resp.read().decode()
    return json.loads(text) if text else {}


def _bearer(credential, scope):
    return {"Authorization": "Bearer " + credential.get_token(scope).token}


def scale(credential, metrics, settings):
    """Raise each queue's scale set to what it needs; returns what it did."""
    arm = _bearer(credential, ARM + "/.default")
    agent_queues = metrics.get("agents", {}).get("queues", {})
    job_queues = metrics.get("jobs", {}).get("queues", {})
    actions = {}
    for queue, cfg in settings["scale_sets"].items():
        busy = int(agent_queues.get(queue, {}).get("busy", 0))
        scheduled = int(job_queues.get(queue, {}).get("scheduled", 0))
        needed = min(int(cfg["max"]), busy + scheduled)

        url = (f"{ARM}/subscriptions/{settings['subscription']}"
               f"/resourceGroups/{settings['resource_group']}"
               f"/providers/Microsoft.Compute/virtualMachineScaleSets/{cfg['vmss']}"
               f"?api-version={ARM_API}")
        current = int(_request("GET", url, arm)["sku"]["capacity"])
        if needed > current:
            _request("PATCH", url, arm, {"sku": {"capacity": needed}})
            actions[queue] = f"{current} -> {needed}"
        else:
            actions[queue] = f"{current} (needs {busy + scheduled}: {busy} busy, {scheduled} scheduled)"
    return actions


def settings_from_env():
    return {
        "client_id": os.environ["SCALER_IDENTITY_CLIENT_ID"],
        "key_vault": os.environ["KEY_VAULT"],
        "subscription": os.environ["SUBSCRIPTION_ID"],
        "resource_group": os.environ["RESOURCE_GROUP"],
        "scale_sets": json.loads(os.environ["SCALE_SETS"]),
    }


@app.timer_trigger(schedule="0 */1 * * * *", arg_name="timer", run_on_startup=False)
def scale_agents(timer: func.TimerRequest) -> None:
    settings = settings_from_env()
    credential = ManagedIdentityCredential(client_id=settings["client_id"])

    secret_url = (f"https://{settings['key_vault']}.vault.azure.net"
                  f"/secrets/buildkite-agent-token?api-version=7.4")
    token = _request("GET", secret_url,
                     _bearer(credential, "https://vault.azure.net/.default"))["value"].strip()

    metrics = _request("GET", BUILDKITE_METRICS, {"Authorization": "Token " + token})
    logging.info("fluffy-ci scaler: %s", json.dumps(scale(credential, metrics, settings)))
