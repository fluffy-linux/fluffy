# Fluffy's CI on GCP

Fluffy's Buildkite CI agents run on GCP spot VMs, in project
`fluffy-linux`, regions `us-east4` and `us-east1` (the scaler and the
rest are in `us-east4`).  CI ran on Azure until 2026-11-23; that setup is
in the git history.

No credentials live in this repository.  Terraform and Packer use your
`gcloud` login's access token, passed in the environment.  The VMs use
service accounts, and read their secrets from Secret Manager.

- `packer/`: the agent image, in family `fluffy-ci-agent`. It is Ubuntu
  24.04 with Fluffy's host tools, `/sw/bash`, ctypes.sh and the Buildkite
  agent. At boot the agent reads its token from Secret Manager. After 10
  idle minutes it exits, and the VM deletes itself.
- `terraform/`:
  - the project's APIs;
  - the secrets (values are added separately, below);
  - a network with no firewall rules, so nothing reaches the agents;
  - the agents' service account: it can read two secrets
    (`buildkite-agent-token`, `ghcr-token`) and delete agent VMs, nothing
    else, because builds run upstream code;
  - a subnet and a spot instance template per agent region;
  - the scaler.
- `scaler/`: a Cloud Function, called every minute by Cloud Scheduler. It
  reads Buildkite's agent metrics and starts agent VMs until the queue
  `mufasa` has one per busy or waiting job, up to `agent_max_instances`.
  That is 2 `c4d-standard-16-lssd`: the project has 32 vCPUs and C4D 24
  per region, so in practice one per region. A world is mostly one long
  chain of steps, so fast agents matter more than many. It tries zones in
  turn, and waits for each create to finish, because quota and spot
  capacity failures show up in the operation. It never deletes VMs: agents
  leave on their own. Spot VMs are also deleted when preempted, and every
  VM at `agent_max_run_hours`.

Nothing persists on the agents. swctl fetches unchanged recipes' images
from the binary cache, the public package `ghcr.io/fluffy-linux/sw`, and
publishes new ones there (with `ghcr-token`, a classic token with
`write:packages`).

## Once

Log in with gcloud as the CI account, then create the bucket that holds
Terraform's state:

```
gcloud auth login
gcloud config set project fluffy-linux
gcloud storage buckets create gs://fluffy-linux-tfstate --location us-east4 \
    --uniform-bucket-level-access --public-access-prevention
gcloud storage buckets update gs://fluffy-linux-tfstate --versioning
```

## Apply

The instance template needs the image, so a new project goes in three
steps. First, everything but the template and the scaler:

```
export GOOGLE_OAUTH_ACCESS_TOKEN="$(gcloud auth print-access-token)"
terraform -chdir=infra/terraform init
terraform -chdir=infra/terraform apply \
    -target=google_project_service.services \
    -target=google_secret_manager_secret.secrets \
    -target=google_secret_manager_secret_iam_member.agent \
    -target=google_service_account.agent \
    -target=google_compute_subnetwork.agents
```

Then add each secret's value. Pipe it in, so it never appears on a command
line or in Terraform's state:

```
<command printing the token> | gcloud secrets versions add buildkite-agent-token --data-file=-
```

The secrets are:
- `buildkite-agent-token`: the agent token for the cluster.
- `buildkite-api-token`: a read-only REST API token.
- `ghcr-token`: a classic token with `write:packages`.
- `github-mirror-token`: a classic token with `public_repo` and `workflow`.

Then the image, then everything else:

```
packer init infra/packer
PKR_VAR_access_token="$(gcloud auth print-access-token)" packer build infra/packer
terraform -chdir=infra/terraform apply
```

A new image needs no apply: each VM boots the family's newest image when
it is created. A reused agent keeps the image it booted with, though, so
after an image change delete any live agents before pushing:

```
gcloud compute instances list --filter=labels.fluffy-ci=agent
gcloud compute instances delete <name> --zone <zone>
```

## Debugging

The scaler's log:

```
gcloud functions logs read fluffy-ci-scaler --region us-east4
```

An agent's serial console shows its boot and cloud-init:

```
gcloud compute instances get-serial-port-output <name> --zone <zone>
```

To keep a VM after its agent exits, set `FLUFFY_CI_SELF_DELETE=0` in its
`/etc/fluffy-ci/agent.env`. Nothing can SSH in, by design. To look inside
a VM, add a firewall rule and a key for that one VM, and remove both
afterwards.
