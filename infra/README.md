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
- `packer/` (next): the agent VM image.
- The agent VM itself (after that): one spot VM, started per build and
  deallocated after.

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
