variable "project" {
  description = "The GCP project for CI."
  type        = string
  default     = "fluffy-linux"
}

variable "region" {
  description = "Region for CI's scaler and its other regional parts."
  type        = string
  default     = "us-east4"
}

variable "scaler_region" {
  description = <<-EOT
    Region for the scaler (function, its source bucket, its schedule).  Not
    us-east4: since 2026-11-24 Cloud Build refuses every build there for
    this project (PERMISSION_DENIED even for the owner; builds elsewhere
    work), and the function's Cloud Run address there answered 404.
  EOT
  type        = string
  default     = "us-central1"
}

variable "agent_zones" {
  description = <<-EOT
    The zones the scaler starts agents in, by region, tried in turn: spot
    capacity differs by zone, and quotas (C4D: 24 vCPUs) by region.  Each
    region gets a subnet and an instance template.
  EOT
  type        = map(list(string))
  default = {
    "us-east4" = ["us-east4-a", "us-east4-b", "us-east4-c"]
    "us-east1" = ["us-east1-b", "us-east1-c", "us-east1-d"]
  }
}

variable "agent_subnets" {
  description = "Each agent region's subnet range."
  type        = map(string)
  default = {
    "us-east4" = "10.20.0.0/20"
    "us-east1" = "10.20.16.0/20"
  }
}

variable "buildkite_queue" {
  description = "The Buildkite queue the agents join and the scaler watches.  mufasa is the cluster's default queue, where steps without a queue go."
  type        = string
  default     = "mufasa"
}

variable "agent_max_instances" {
  description = "The most agent VMs at once.  2 x c4d-standard-16-lssd fit the project's 32 vCPUs, one per region (C4D: 24 per region)."
  type        = number
  default     = 2
}

variable "agent_machine_type" {
  description = "Agent VM type.  An -lssd type brings its own local SSDs: set agent_local_ssds to 0 for one."
  type        = string
  default     = "c4d-standard-16-lssd"
}

variable "agent_min_cpu_platform" {
  description = "Minimum CPU platform for the agents, or null for the type's default."
  type        = string
  default     = null
}

variable "agent_local_ssds" {
  description = "Local NVMe SSDs (375 GB each) added to each agent; builds run on the first, on /mnt.  0 for an -lssd type, which has its own."
  type        = number
  default     = 0
}

variable "agent_boot_disk_gb" {
  description = "Agents' boot disk (deleted with the VM).  Builds run on the local SSD, not here."
  type        = number
  default     = 30
}

variable "agent_boot_disk_type" {
  description = "Agents' boot disk type: C4D takes only Hyperdisk; N2D takes pd-balanced."
  type        = string
  default     = "hyperdisk-balanced"
}

variable "agent_max_run_hours" {
  description = "GCP deletes an agent VM after this long, whatever it is doing: a backstop for a VM whose agent never started or never exited."
  type        = number
  default     = 8
}

variable "cache_registry" {
  description = "The binary cache: an OCI registry package, public, holding each recipe's image as <pkg>.<recipe-checksum>."
  type        = string
  default     = "ghcr.io/fluffy-linux/sw"
}
