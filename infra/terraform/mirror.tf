# The mirror agent: keeps the fluffy-linux forks current with upstream
# (see NOTES.md, "Mirror sync").  One small VM, started on demand like the
# build agents (the scaler raises the scale set when jobs wait on the
# mirror queue) and deleted by the same idle self-delete, which attaches
# a persistent HDD at boot: the bare repositories of the last sync live
# there, so a run never re-clones and moves only new objects.
#
# It has its own identity: it reads the GitHub push token, which the build
# agents (running upstream build scripts) must not be able to read.

variable "mirror_vm_size" {
  description = "The mirror agent's size: small, it only runs git (2 vCPUs fit beside an 8-vCPU build agent in a 10-vCPU regional quota)."
  type        = string
  default     = "Standard_D2as_v4"
}

variable "mirror_disk_gb" {
  description = "The mirror repositories' disk (Standard HDD); all mirrors were about 28 GB in 2026-11."
  type        = number
  default     = 128
}

variable "mirror_buildkite_queue" {
  description = "The Buildkite queue the mirror agent joins."
  type        = string
  default     = "mirror"
}

resource "azurerm_user_assigned_identity" "mirror" {
  name                = "fluffy-ci-mirror"
  resource_group_name = azurerm_resource_group.ci.name
  location            = azurerm_resource_group.ci.location
}

# The whole vault: it holds the agent token and the GitHub push token, and
# runs only Fluffy's own sync script.
resource "azurerm_role_assignment" "vault_mirror" {
  scope                = azurerm_key_vault.ci.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.mirror.principal_id
}

# Attach the disk to itself at boot, and delete itself when idle (the disk
# is detached, not deleted, with the VM).
resource "azurerm_role_assignment" "mirror_vm" {
  scope                = azurerm_resource_group.ci.id
  role_definition_name = "Virtual Machine Contributor"
  principal_id         = azurerm_user_assigned_identity.mirror.principal_id
}

resource "azurerm_managed_disk" "mirror" {
  name                 = "fluffy-ci-mirror-repos"
  resource_group_name  = azurerm_resource_group.ci.name
  location             = azurerm_resource_group.ci.location
  storage_account_type = "Standard_LRS"
  create_option        = "Empty"
  disk_size_gb         = var.mirror_disk_gb

  # The synced repositories: re-creating it would mean re-cloning them all.
  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_orchestrated_virtual_machine_scale_set" "mirror" {
  name                        = "fluffy-ci-mirror"
  resource_group_name         = azurerm_resource_group.ci.name
  location                    = azurerm_resource_group.ci.location
  sku_name                    = var.mirror_vm_size
  instances                   = 0
  platform_fault_domain_count = 1
  priority                    = "Regular"

  source_image_id = azurerm_shared_image.agent_nvme.id

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.mirror.id]
  }

  os_profile {
    custom_data = base64encode(templatefile("${path.module}/mirror-cloud-init.yaml", {
      queue              = var.mirror_buildkite_queue
      key_vault          = azurerm_key_vault.ci.name
      identity_client_id = azurerm_user_assigned_identity.mirror.client_id
      disk_id            = azurerm_managed_disk.mirror.id
    }))

    linux_configuration {
      admin_username                  = "fluffy"
      disable_password_authentication = true

      admin_ssh_key {
        username   = "fluffy"
        public_key = var.admin_ssh_public_key
      }
    }
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
    disk_size_gb         = 32
  }

  network_interface {
    name                          = "nic"
    primary                       = true
    network_security_group_id     = azurerm_network_security_group.agents.id
    enable_accelerated_networking = false

    ip_configuration {
      name      = "ip"
      primary   = true
      subnet_id = azurerm_subnet.agents.id

      public_ip_address {
        name = "pip"
      }
    }
  }

  boot_diagnostics {}

  lifecycle {
    ignore_changes = [instances]
  }

  depends_on = [
    azurerm_role_assignment.vault_mirror,
    azurerm_role_assignment.mirror_vm,
  ]
}

# The scaler raises this scale set too.
resource "azurerm_role_assignment" "scaler_mirror" {
  scope                = azurerm_orchestrated_virtual_machine_scale_set.mirror.id
  role_definition_name = "Virtual Machine Contributor"
  principal_id         = azurerm_user_assigned_identity.scaler.principal_id
}
