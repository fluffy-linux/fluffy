# The CI agent's VM image on GCP: Ubuntu 24.04 with Fluffy's host tools,
# the Buildkite agent and its boot scripts, in image family
# fluffy-ci-agent; agents boot the family's newest image.  The image is the
# same as the Azure one (infra/packer: provision.sh and its files), except
# for the two cloud-specific boot scripts in files/ here: the token fetch
# (Secret Manager) and the self-delete (Compute Engine).
#
# Build with your gcloud login, its token passed in the environment (never
# on the command line):
#
#   packer init infra/gcp/packer
#   PKR_VAR_access_token="$(gcloud auth print-access-token)" packer build infra/gcp/packer

packer {
  required_plugins {
    googlecompute = {
      source  = "github.com/hashicorp/googlecompute"
      version = "~> 1"
    }
  }
}

variable "access_token" {
  description = "An OAuth access token for the project (gcloud auth print-access-token)."
  type        = string
  sensitive   = true
}

variable "project" {
  type    = string
  default = "fluffy-linux"
}

variable "zone" {
  type    = string
  default = "us-east4-a"
}

# Provisioning is mostly downloads and one small build (ctypes.sh).
variable "build_machine_type" {
  description = "The temporary VM Packer provisions the image on."
  type        = string
  default     = "n2d-standard-2"
}

# Pinned the same as infra/packer/agent.pkr.hcl.
variable "ctypes_sh_commit" {
  type    = string
  default = "78125e34c214e4fabf8539010c5a5f85289c5754"
}

variable "oras_version" {
  type    = string
  default = "1.3.6"
}

variable "oras_sha256" {
  type    = string
  default = "66fb0ad7206f3f6fa77ed5b552049d364ccf4b50b1684554f731f76302b52ca0"
}

locals {
  stamp = formatdate("YYYYMMDD-hhmmss", timestamp())
}

source "googlecompute" "agent" {
  project_id   = var.project
  zone         = var.zone
  access_token = var.access_token

  source_image_family     = "ubuntu-2404-lts-amd64"
  source_image_project_id = ["ubuntu-os-cloud"]
  machine_type            = var.build_machine_type
  disk_size               = 20
  disk_type               = "pd-balanced"
  ssh_username            = "packer"

  image_name        = "fluffy-ci-agent-${local.stamp}"
  image_family      = "fluffy-ci-agent"
  image_description = "Fluffy Linux CI agent (infra/gcp/packer)"
  image_labels = {
    purpose = "fluffy-ci-agent-image"
  }
}

build {
  sources = ["source.googlecompute.agent"]

  # The file provisioner uploads a directory's contents ("files/") into a
  # destination directory that must already exist.  The shared files
  # first, then GCP's boot scripts over Azure's.
  provisioner "shell" {
    inline = ["mkdir -p /tmp/fluffy-ci"]
  }

  provisioner "file" {
    source      = "${path.root}/../../packer/files/"
    destination = "/tmp/fluffy-ci"
  }

  provisioner "file" {
    source      = "${path.root}/files/"
    destination = "/tmp/fluffy-ci"
  }

  provisioner "shell" {
    execute_command = "chmod +x {{ .Path }}; {{ .Vars }} sudo -E bash {{ .Path }}"
    environment_vars = [
      "CTYPES_SH_COMMIT=${var.ctypes_sh_commit}",
      "ORAS_VERSION=${var.oras_version}",
      "ORAS_SHA256=${var.oras_sha256}",
    ]
    script = "${path.root}/../../packer/provision.sh"
  }
}
