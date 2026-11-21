# The CI agent's VM image: Ubuntu 24.04 with Fluffy's host tools, the
# Buildkite agent and its boot scripts, published to the Compute Gallery
# that infra/terraform creates.  Build with your az login session:
#
#   packer init infra/packer
#   packer build -var subscription_id=<id> -var image_version=1.0.0 infra/packer
#
# Each build publishes a new version; agents boot the latest.

packer {
  required_plugins {
    azure = {
      source  = "github.com/hashicorp/azure"
      version = "~> 2"
    }
  }
}

variable "subscription_id" {
  description = "The Azure subscription."
  type        = string
}

variable "image_version" {
  description = "Gallery image version to publish, major.minor.patch."
  type        = string
}

variable "location" {
  type    = string
  default = "eastus"
}

variable "resource_group" {
  description = "infra/terraform's resource group, holding the gallery."
  type        = string
  default     = "fluffy-ci"
}

variable "gallery_name" {
  type    = string
  default = "fluffy_ci"
}

variable "image_name" {
  type    = string
  default = "fluffy-ci-agent"
}

# A family with quota on the subscription (new pay-as-you-go subscriptions
# start with none for the v5 families) and SCSI disks, as the Ubuntu image
# expects.
variable "build_vm_size" {
  description = "Size of the temporary VM Packer provisions the image on."
  type        = string
  default     = "Standard_D4as_v4"
}

# Fluffy's ctypes.sh fork (fluffy/v1.3), which swctl loads on the host.
variable "ctypes_sh_commit" {
  type    = string
  default = "78125e34c214e4fabf8539010c5a5f85289c5754"
}

source "azure-arm" "agent" {
  use_azure_cli_auth = true
  subscription_id    = var.subscription_id

  os_type         = "Linux"
  image_publisher = "Canonical"
  image_offer     = "ubuntu-24_04-lts"
  image_sku       = "server"

  location = var.location
  vm_size  = var.build_vm_size

  shared_image_gallery_destination {
    subscription         = var.subscription_id
    resource_group       = var.resource_group
    gallery_name         = var.gallery_name
    image_name           = var.image_name
    image_version        = var.image_version
    replication_regions  = [var.location]
    storage_account_type = "Standard_LRS"
  }

  azure_tags = {
    purpose = "fluffy-ci-agent-image"
  }
}

build {
  sources = ["source.azure-arm.agent"]

  provisioner "file" {
    source      = "${path.root}/files/"
    destination = "/tmp/fluffy-ci"
  }

  provisioner "shell" {
    execute_command  = "chmod +x {{ .Path }}; {{ .Vars }} sudo -E bash {{ .Path }}"
    environment_vars = ["CTYPES_SH_COMMIT=${var.ctypes_sh_commit}"]
    script           = "${path.root}/provision.sh"
  }

  # Generalize, as Azure requires for an image (Packer's azure-arm docs).
  provisioner "shell" {
    execute_command = "chmod +x {{ .Path }}; {{ .Vars }} sudo -E sh '{{ .Path }}'"
    inline          = ["/usr/sbin/waagent -force -deprovision+user && export HISTSIZE=0 && sync"]
    inline_shebang  = "/bin/sh -x"
  }
}
