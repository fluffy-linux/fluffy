terraform {
  required_version = ">= 1.6"

  # Settings in backend.hcl, written from infra/bootstrap's output:
  #   terraform -chdir=infra/terraform init -backend-config=backend.hcl
  backend "azurerm" {}

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }
}

# Authenticates as the az login user.  Storage data-plane access uses Entra
# ID, not account keys, which are disabled.
provider "azurerm" {
  features {}
  storage_use_azuread = true
}
