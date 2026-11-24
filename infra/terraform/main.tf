# Fluffy's CI on GCP: the project's APIs, its secrets, and the network the
# agents run in.  agents.tf has the agents, scaler.tf what starts them.

locals {
  services = [
    "artifactregistry",
    "cloudbuild",
    "cloudfunctions",
    "cloudscheduler",
    "compute",
    "iam",
    "logging",
    "run",
    "secretmanager",
    "storage",
  ]
}

resource "google_project_service" "services" {
  for_each           = toset(local.services)
  service            = "${each.key}.googleapis.com"
  disable_on_destroy = false
}

# --- Secrets ---------------------------------------------------------------

# The secrets themselves; their values are added out of band, piped into
# `gcloud secrets versions add NAME --data-file=-` (infra/README.md), so
# they never appear in Terraform's state or on a command line.
#   buildkite-agent-token  agents register with it; the scaler reads
#                          Buildkite's agent metrics with it
#   buildkite-api-token    read-only REST API token, for people's tools
#   ghcr-token             publishes the binary cache (agents)
#   github-mirror-token    pushes the forks (the mirror agent, later)
locals {
  secrets = ["buildkite-agent-token", "buildkite-api-token", "ghcr-token", "github-mirror-token"]
}

resource "google_secret_manager_secret" "secrets" {
  for_each  = toset(local.secrets)
  secret_id = each.key
  replication {
    auto {}
  }
  depends_on = [google_project_service.services]
}

# --- Network ---------------------------------------------------------------

# Its own network, with no firewall rules: nothing can reach the agents
# (GCP denies all ingress without a rule); they reach out, each with its
# own ephemeral public IP.
resource "google_compute_network" "ci" {
  name                    = "fluffy-ci"
  auto_create_subnetworks = false
  depends_on              = [google_project_service.services]
}

resource "google_compute_subnetwork" "agents" {
  for_each      = var.agent_zones
  name          = "fluffy-ci-agents-${each.key}"
  network       = google_compute_network.ci.id
  region        = each.key
  ip_cidr_range = var.agent_subnets[each.key]
}
