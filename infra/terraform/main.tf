# Fluffy's CI on Azure: the parts every agent shares.  The agent VM itself
# (a spot VM booted from the Packer image) comes in a later step.

data "azurerm_client_config" "current" {}

# Storage account and Key Vault names are global: a random suffix keeps
# Fluffy's unique.
resource "random_string" "suffix" {
  length  = 6
  upper   = false
  special = false
}

resource "azurerm_resource_group" "ci" {
  name     = "fluffy-ci"
  location = var.location
}

# The identity the agent VMs run as: it reads the Buildkite agent token
# from Key Vault and reads and writes the image store, so no credentials
# are baked into the VM image.
resource "azurerm_user_assigned_identity" "agent" {
  name                = "fluffy-ci-agent"
  resource_group_name = azurerm_resource_group.ci.name
  location            = azurerm_resource_group.ci.location
}

# --- Network ---------------------------------------------------------------

# Agents only make outbound connections (GitHub, Buildkite, the image
# store).  The subnet has no default outbound access, which Azure is
# retiring; each agent VM gets its own public IP for that, cheaper than a
# NAT gateway for one or a few VMs.  Nothing is allowed in.
resource "azurerm_virtual_network" "ci" {
  name                = "fluffy-ci"
  resource_group_name = azurerm_resource_group.ci.name
  location            = azurerm_resource_group.ci.location
  address_space       = ["10.42.0.0/16"]
}

resource "azurerm_subnet" "agents" {
  name                            = "agents"
  resource_group_name             = azurerm_resource_group.ci.name
  virtual_network_name            = azurerm_virtual_network.ci.name
  address_prefixes                = ["10.42.1.0/24"]
  default_outbound_access_enabled = false
}

resource "azurerm_network_security_group" "agents" {
  name                = "fluffy-ci-agents"
  resource_group_name = azurerm_resource_group.ci.name
  location            = azurerm_resource_group.ci.location

  security_rule {
    name                       = "deny-all-inbound"
    priority                   = 4096
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "agents" {
  subnet_id                 = azurerm_subnet.agents.id
  network_security_group_id = azurerm_network_security_group.agents.id
}

# --- Image store -----------------------------------------------------------

# Built squashfs images, content-addressed: images/<image-checksum>.squashfs
# (written once, never overwritten) and recipes/<recipe-checksum> (the fstab
# line that recipe produced).  See NOTES.md, "a parallel world on Buildkite".
resource "azurerm_storage_account" "images" {
  name                            = "fluffyimages${random_string.suffix.result}"
  resource_group_name             = azurerm_resource_group.ci.name
  location                        = azurerm_resource_group.ci.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  shared_access_key_enabled       = false
}

resource "azurerm_storage_container" "images" {
  name                  = "images"
  storage_account_id    = azurerm_storage_account.images.id
  container_access_type = "private"
}

resource "azurerm_role_assignment" "images_agent" {
  scope                = azurerm_storage_account.images.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.agent.principal_id
}

resource "azurerm_role_assignment" "images_admin" {
  scope                = azurerm_storage_account.images.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = data.azurerm_client_config.current.object_id
}

# --- Secrets ---------------------------------------------------------------

# Holds the Buildkite agent token as the secret "buildkite-agent-token".
# Terraform does not set it (it would land in the state); set it once with
#   az keyvault secret set --vault-name <key_vault_name> \
#       --name buildkite-agent-token --file <file-with-token>
resource "azurerm_key_vault" "ci" {
  name                       = "fluffy-ci-${random_string.suffix.result}"
  resource_group_name        = azurerm_resource_group.ci.name
  location                   = azurerm_resource_group.ci.location
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  rbac_authorization_enabled = true
  purge_protection_enabled   = false
  soft_delete_retention_days = 7
}

resource "azurerm_role_assignment" "vault_agent" {
  scope                = azurerm_key_vault.ci.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.agent.principal_id
}

resource "azurerm_role_assignment" "vault_admin" {
  scope                = azurerm_key_vault.ci.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

# --- VM images -------------------------------------------------------------

# infra/packer publishes the agent image here, one version per build.
resource "azurerm_shared_image_gallery" "ci" {
  name                = "fluffy_ci"
  resource_group_name = azurerm_resource_group.ci.name
  location            = azurerm_resource_group.ci.location
}

resource "azurerm_shared_image" "agent" {
  name                = "fluffy-ci-agent"
  gallery_name        = azurerm_shared_image_gallery.ci.name
  resource_group_name = azurerm_resource_group.ci.name
  location            = azurerm_resource_group.ci.location
  os_type             = "Linux"
  hyper_v_generation  = "V2"

  identifier {
    publisher = "fluffy-linux"
    offer     = "ci-agent"
    sku       = "ubuntu-24.04"
  }
}

# --- Spending --------------------------------------------------------------

# Pay-as-you-go has no hard cap, so this alerts: at 50%, 80% and 100% of
# the month's budget, and when the forecast passes 100%.
resource "azurerm_consumption_budget_resource_group" "ci" {
  name              = "fluffy-ci-monthly"
  resource_group_id = azurerm_resource_group.ci.id
  amount            = var.budget_amount
  time_grain        = "Monthly"

  time_period {
    start_date = var.budget_start
  }

  dynamic "notification" {
    for_each = [50, 80, 100]
    content {
      enabled        = true
      threshold      = notification.value
      operator       = "GreaterThanOrEqualTo"
      threshold_type = "Actual"
      contact_emails = var.alert_emails
    }
  }

  notification {
    enabled        = true
    threshold      = 100
    operator       = "GreaterThanOrEqualTo"
    threshold_type = "Forecasted"
    contact_emails = var.alert_emails
  }

  lifecycle {
    ignore_changes = [time_period]
  }
}
