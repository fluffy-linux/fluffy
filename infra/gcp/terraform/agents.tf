# The CI agents: spot VMs made from one instance template, booted from the
# Packer image (infra/gcp/packer).  Nothing runs until the scaler
# (scaler.tf) creates VMs for waiting jobs; each agent takes jobs back to
# back, exits after 10 idle minutes and deletes its own VM.

resource "google_service_account" "agent" {
  account_id   = "fluffy-ci-agent"
  display_name = "Fluffy CI agent"
  description  = "CI agent VMs: run builds (upstream code), so they get only their own two secrets and the right to delete themselves."
}

# The agent's two secrets, and no others: builds run upstream code, which
# must not reach the mirror's push token or the API token.
resource "google_secret_manager_secret_iam_member" "agent" {
  for_each  = toset(["buildkite-agent-token", "ghcr-token"])
  secret_id = google_secret_manager_secret.secrets[each.key].id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.agent.email}"
}

# Deleting an agent VM (and its boot disk, deleted with it): what the agent
# needs to delete itself, limited to agent VMs by name.
resource "google_project_iam_custom_role" "agent_self_delete" {
  role_id     = "fluffyCiAgentSelfDelete"
  title       = "Fluffy CI agent self-delete"
  permissions = ["compute.instances.delete", "compute.instances.get", "compute.disks.delete"]
}

resource "google_project_iam_member" "agent_self_delete" {
  project = var.project
  role    = google_project_iam_custom_role.agent_self_delete.id
  member  = "serviceAccount:${google_service_account.agent.email}"
  condition {
    title      = "fluffy-ci agent VMs only"
    expression = "resource.name.extract('/instances/{name}').startsWith('fluffy-ci-agent-') || resource.name.extract('/disks/{name}').startsWith('fluffy-ci-agent-')"
  }
}

resource "google_compute_instance_template" "agent" {
  name_prefix      = "fluffy-ci-agent-"
  machine_type     = var.agent_machine_type
  min_cpu_platform = var.agent_min_cpu_platform

  # Spot: deleted when GCP takes the capacity back (Buildkite retries the
  # job elsewhere), and at the latest after agent_max_run_hours.
  scheduling {
    provisioning_model          = "SPOT"
    preemptible                 = true
    automatic_restart           = false
    on_host_maintenance         = "TERMINATE"
    instance_termination_action = "DELETE"
    max_run_duration {
      seconds = var.agent_max_run_hours * 3600
    }
  }

  # The newest image of the family, when each VM is created.
  disk {
    boot         = true
    auto_delete  = true
    source_image = "projects/${var.project}/global/images/family/fluffy-ci-agent"
    disk_type    = "pd-balanced"
    disk_size_gb = var.agent_boot_disk_gb
  }

  dynamic "disk" {
    for_each = range(var.agent_local_ssds)
    content {
      type         = "SCRATCH"
      disk_type    = "local-ssd"
      interface    = "NVME"
      disk_size_gb = 375
      auto_delete  = true
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.agents.id
    access_config {}
  }

  service_account {
    email  = google_service_account.agent.email
    scopes = ["cloud-platform"]
  }

  metadata = {
    user-data = templatefile("${path.module}/agent-cloud-init.yaml", {
      queue          = var.buildkite_queue
      project        = var.project
      cache_registry = var.cache_registry
    })
    # No SSH keys reach the VMs (and no firewall rule lets SSH in).
    block-project-ssh-keys = "TRUE"
  }

  labels = {
    fluffy-ci = "agent"
    queue     = var.buildkite_queue
  }

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [google_project_service.services]
}
