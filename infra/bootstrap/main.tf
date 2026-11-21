# The storage account that holds infra/terraform's state.  Run once,
# with its own state kept outside the repository (see infra/README.md):
#
#   terraform -chdir=infra/bootstrap init \
#       -backend-config=path=$HOME/.local/state/fluffy-infra/bootstrap.tfstate
#   terraform -chdir=infra/bootstrap apply
#
# then write its outputs into infra/terraform/backend.hcl.

terraform {
  required_version = ">= 1.6"

  backend "local" {}

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "azurerm" {
  features {}
  storage_use_azuread = true
}

variable "location" {
  description = "Azure region."
  type        = string
  default     = "eastus"
}

# Storage account names are global: a random suffix keeps this one unique.
resource "random_string" "suffix" {
  length  = 6
  upper   = false
  special = false
}

resource "azurerm_resource_group" "state" {
  name     = "fluffy-tfstate"
  location = var.location
}

resource "azurerm_storage_account" "state" {
  name                            = "fluffytfstate${random_string.suffix.result}"
  resource_group_name             = azurerm_resource_group.state.name
  location                        = azurerm_resource_group.state.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  shared_access_key_enabled       = false

  blob_properties {
    versioning_enabled = true
  }
}

resource "azurerm_storage_container" "state" {
  name                  = "tfstate"
  storage_account_id    = azurerm_storage_account.state.id
  container_access_type = "private"
}

# Whoever applies this (the az login user) may read and write the state.
data "azurerm_client_config" "current" {}

resource "azurerm_role_assignment" "state" {
  scope                = azurerm_storage_account.state.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = data.azurerm_client_config.current.object_id
}

output "backend_hcl" {
  description = "The contents of infra/terraform/backend.hcl."
  value       = <<-EOT
    resource_group_name  = "${azurerm_resource_group.state.name}"
    storage_account_name = "${azurerm_storage_account.state.name}"
    container_name       = "${azurerm_storage_container.state.name}"
    key                  = "fluffy-ci.tfstate"
    use_azuread_auth     = true
  EOT
}
