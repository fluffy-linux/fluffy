variable "project" {
  description = "The GCP project for CI."
  type        = string
  default     = "fluffy-linux"
}

variable "region" {
  description = "Region for CI: its agents, network and scaler."
  type        = string
  default     = "us-east4"
}

variable "zones" {
  description = "Zones the scaler starts agents in, tried in turn (spot capacity differs by zone)."
  type        = list(string)
  default     = ["us-east4-a", "us-east4-b", "us-east4-c"]
}

variable "buildkite_queue" {
  description = "The Buildkite queue the agents join and the scaler watches.  mufasa is the cluster's default queue, where steps without a queue go."
  type        = string
  default     = "mufasa"
}

variable "agent_max_instances" {
  description = "The most agent VMs at once.  4 x n2d-standard-4 is the region's N2D quota (16 vCPUs)."
  type        = number
  default     = 4
}

variable "agent_machine_type" {
  description = "Agent VM type.  An -lssd type brings its own local SSDs: set agent_local_ssds to 0 for one."
  type        = string
  default     = "n2d-standard-4"
}

variable "agent_min_cpu_platform" {
  description = "Minimum CPU platform for the agents, or null for the type's default."
  type        = string
  default     = "AMD Milan"
}

variable "agent_local_ssds" {
  description = "Local NVMe SSDs (375 GB each) added to each agent; builds run on the first, on /mnt."
  type        = number
  default     = 1
}

variable "agent_boot_disk_gb" {
  description = "Agents' boot disk (deleted with the VM).  Builds run on the local SSD, not here."
  type        = number
  default     = 30
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
