# The CI agents: one VM scale set per Buildkite queue, booted from the
# Packer image.  A scale set sits at 0 instances; the scaler (a function,
# next) raises its size when jobs wait on its queue, and only ever raises
# it: each agent takes jobs back to back, exits after 10 idle minutes and
# deletes its own VM.  Terraform therefore ignores the instance count.

variable "agent_queues" {
  description = <<-EOT
    One scale set per entry: its VM size, the most VMs at once, and the
    Buildkite queue its agents join (buildkite_queue).  Without
    buildkite_queue, agents join the cluster's default queue, as an agent
    with no queue tag does.
  EOT
  type = map(object({
    vm_size         = string
    max_instances   = number
    buildkite_queue = optional(string)
  }))
  default = {
    default = {
      vm_size       = "Standard_D8as_v4"
      max_instances = 1
    }
  }
}

variable "agent_priority" {
  description = "Regular (on-demand) or Spot.  Regular until the subscription's spot vCPU quota is raised."
  type        = string
  default     = "Regular"

  validation {
    condition     = contains(["Regular", "Spot"], var.agent_priority)
    error_message = "agent_priority must be Regular or Spot."
  }
}

variable "spot_max_price" {
  description = "Most to pay per hour for a spot VM, in US dollars; -1 means up to the on-demand price (evicted only for capacity)."
  type        = number
  default     = -1
}

variable "agent_os_disk_gb" {
  description = "Agents' OS disk, which also holds /mnt/ci and the build trees; deleted with the VM."
  type        = number
  default     = 128
}

variable "admin_ssh_public_key" {
  description = "SSH public key for the agents' admin user (Azure requires one; no inbound traffic is allowed, so it serves only for console debugging).  Set in terraform.tfvars."
  type        = string
}

# The agent deletes its own VM when it has been idle long enough (its
# NIC, public IP and OS disk go with it).
resource "azurerm_role_assignment" "agent_self_delete" {
  scope                = azurerm_resource_group.ci.id
  role_definition_name = "Virtual Machine Contributor"
  principal_id         = azurerm_user_assigned_identity.agent.principal_id
}

resource "azurerm_orchestrated_virtual_machine_scale_set" "agents" {
  for_each = var.agent_queues

  name                        = "fluffy-ci-${each.key}"
  resource_group_name         = azurerm_resource_group.ci.name
  location                    = azurerm_resource_group.ci.location
  sku_name                    = each.value.vm_size
  instances                   = 0
  platform_fault_domain_count = 1

  priority        = var.agent_priority
  eviction_policy = var.agent_priority == "Spot" ? "Delete" : null
  max_bid_price   = var.agent_priority == "Spot" ? var.spot_max_price : null

  # The newest version of the Packer image.
  source_image_id = azurerm_shared_image.agent.id

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.agent.id]
  }

  os_profile {
    custom_data = base64encode(templatefile("${path.module}/agent-cloud-init.yaml", {
      queue              = each.value.buildkite_queue
      key_vault          = azurerm_key_vault.ci.name
      identity_client_id = azurerm_user_assigned_identity.agent.client_id
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
    disk_size_gb         = var.agent_os_disk_gb
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

      # The subnet has no default outbound access: each VM gets its own
      # public IP, deleted with it.
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
    azurerm_role_assignment.vault_agent,
    azurerm_role_assignment.images_agent,
    azurerm_role_assignment.agent_self_delete,
  ]
}
