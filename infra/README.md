# Fluffy's CI on Azure

Infrastructure for running Fluffy's Buildkite CI on Azure spot VMs, in
East US.  No credentials live in this repository: Terraform and Packer
authenticate as your `az login` session, and the agent VMs as a managed
identity, reading the Buildkite agent token from Key Vault.

- `bootstrap/`: the storage account that holds `terraform/`'s state.  Run
  once.
- `terraform/`: the resource group and what every agent shares: network,
  the image store (Blob), Key Vault, the agents' managed identity, the
  image gallery Packer publishes to, and a monthly budget with email
  alerts.  The subscription is pay-as-you-go, so the budget alerts; it
  cannot stop spending.
- `packer/`: the agent VM image, published to the gallery: Ubuntu 24.04
  with Fluffy's host tools, `/sw/bash`, ctypes.sh (from Fluffy's fork) and
  the Buildkite agent, which fetches its token from Key Vault at boot,
  exits after 10 idle minutes, and then deletes its VM.
- After that: a spot VM scale set, normally at size 0, and a small Azure
  Function that polls Buildkite's agent metrics every minute and sets the
  scale set's size from the jobs waiting.  Each agent runs one job and
  deletes its own VM.  Nothing persists between builds except Blob: swctl
  downloads the images whose recipes are unchanged and uploads new ones.

## Once

Install the Azure CLI and log in; Terraform and Packer use that session.

```
az login
az account set --subscription <subscription-id>
```

Create the state storage, keeping the bootstrap's own (small) state outside
the repository, then record where the main state goes:

```
mkdir -p ~/.local/state/fluffy-infra
terraform -chdir=infra/bootstrap init \
    -backend-config=path=$HOME/.local/state/fluffy-infra/bootstrap.tfstate
terraform -chdir=infra/bootstrap apply
terraform -chdir=infra/bootstrap output -raw backend_hcl > infra/terraform/backend.hcl
```

`backend.hcl` holds only resource names, no secrets.

## Shared infrastructure

```
cp infra/terraform/terraform.example.tfvars infra/terraform/terraform.tfvars
$EDITOR infra/terraform/terraform.tfvars      # your alert address; not committed
terraform -chdir=infra/terraform init -backend-config=backend.hcl
terraform -chdir=infra/terraform plan
terraform -chdir=infra/terraform apply
```

Then store the Buildkite agent token (Terraform does not, so it never
reaches the state):

```
az keyvault secret set \
    --vault-name "$(terraform -chdir=infra/terraform output -raw key_vault_name)" \
    --name buildkite-agent-token --file <file-holding-the-token>
```

## The agent image

Needs `infra/terraform` applied first: Packer publishes into its gallery,
and the Key Vault secret above needs its vault.  New pay-as-you-go
subscriptions start with small vCPU quotas (none at all for the v5
families): the build VM is a `Standard_D4as_v4` for that reason, and spot
agents need "Total Regional Low-priority vCPUs" raised (Quotas, Compute,
East US) to at least an agent's size.

```
packer init infra/packer
packer build \
    -var subscription_id="$(az account show --query id -o tsv)" \
    -var image_version=1.0.0 \
    infra/packer
```

Bump `image_version` for each new image.  The image starts no agent by
itself: a VM becomes an agent only when its custom data writes
`/etc/fluffy-ci/agent.env` (the scale sets, next step), with
`BUILDKITE_AGENT_QUEUE`, `FLUFFY_CI_KEY_VAULT` and
`FLUFFY_CI_IDENTITY_CLIENT_ID`.  `FLUFFY_CI_SELF_DELETE=0` keeps a VM after
its agent exits, for debugging.
