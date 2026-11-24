# The scaler: a Cloud Function (infra/gcp/scaler) that starts agent VMs for
# waiting jobs, called every minute by Cloud Scheduler.  terraform apply
# deploys its code whenever it changes (the source archive's checksum names
# the uploaded object).

resource "google_service_account" "scaler" {
  account_id   = "fluffy-ci-scaler"
  display_name = "Fluffy CI scaler"
}

# The agent token, for Buildkite's agent metrics API.
resource "google_secret_manager_secret_iam_member" "scaler" {
  secret_id = google_secret_manager_secret.secrets["buildkite-agent-token"].id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.scaler.email}"
}

# Listing and creating agent VMs, and attaching the agent's service account
# to them.
resource "google_project_iam_member" "scaler_compute" {
  project = var.project
  role    = "roles/compute.instanceAdmin.v1"
  member  = "serviceAccount:${google_service_account.scaler.email}"
}

resource "google_service_account_iam_member" "scaler_uses_agent" {
  service_account_id = google_service_account.agent.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.scaler.email}"
}

# Cloud Build builds the function's code as this account (newer projects'
# default build account has no permissions).
resource "google_service_account" "scaler_build" {
  account_id   = "fluffy-ci-scaler-build"
  display_name = "Fluffy CI scaler build"
}

resource "google_project_iam_member" "scaler_build" {
  for_each = toset([
    "roles/cloudbuild.builds.builder",
    "roles/logging.logWriter",
    "roles/artifactregistry.writer",
    "roles/storage.objectViewer",
  ])
  project = var.project
  role    = each.key
  member  = "serviceAccount:${google_service_account.scaler_build.email}"
}

resource "random_id" "source_bucket" {
  byte_length = 3
}

resource "google_storage_bucket" "scaler_source" {
  name                        = "fluffy-ci-scaler-src-${random_id.source_bucket.hex}"
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = true
  depends_on                  = [google_project_service.services]
}

data "archive_file" "scaler" {
  type        = "zip"
  source_dir  = "${path.module}/../scaler"
  output_path = "${path.module}/.terraform/scaler.zip"
  excludes    = ["__pycache__", "__pycache__/*"]
}

resource "google_storage_bucket_object" "scaler" {
  name   = "scaler-${data.archive_file.scaler.output_md5}.zip"
  bucket = google_storage_bucket.scaler_source.name
  source = data.archive_file.scaler.output_path
}

resource "google_cloudfunctions2_function" "scaler" {
  name     = "fluffy-ci-scaler"
  location = var.region

  build_config {
    runtime         = "python312"
    entry_point     = "scale_agents"
    service_account = google_service_account.scaler_build.id
    source {
      storage_source {
        bucket = google_storage_bucket.scaler_source.name
        object = google_storage_bucket_object.scaler.name
      }
    }
  }

  service_config {
    available_memory      = "256M"
    timeout_seconds       = 540
    max_instance_count    = 1
    service_account_email = google_service_account.scaler.email
    ingress_settings      = "ALLOW_ALL"
    environment_variables = {
      PROJECT = var.project
      ZONES   = join(",", flatten(values(var.agent_zones)))
      TEMPLATES = jsonencode(merge([
        for region, zones in var.agent_zones : {
          for z in zones : z => google_compute_instance_template.agent[region].name
        }
      ]...))
      QUEUE         = var.buildkite_queue
      MAX_INSTANCES = tostring(var.agent_max_instances)
    }
  }

  depends_on = [
    google_project_iam_member.scaler_build,
    google_secret_manager_secret_iam_member.scaler,
    google_project_iam_member.scaler_compute,
    google_service_account_iam_member.scaler_uses_agent,
  ]
}

# Cloud Scheduler calls the function every minute, as its own account,
# the only one allowed to invoke it.
resource "google_service_account" "scheduler" {
  account_id   = "fluffy-ci-scheduler"
  display_name = "Fluffy CI scheduler"
}

resource "google_cloud_run_service_iam_member" "scheduler_invokes" {
  location = var.region
  service  = google_cloudfunctions2_function.scaler.service_config[0].service
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.scheduler.email}"
}

resource "google_cloud_scheduler_job" "scaler" {
  name             = "fluffy-ci-scaler"
  region           = var.region
  schedule         = "* * * * *"
  attempt_deadline = "540s"
  retry_config {
    retry_count = 0
  }
  http_target {
    http_method = "POST"
    uri         = google_cloudfunctions2_function.scaler.service_config[0].uri
    oidc_token {
      service_account_email = google_service_account.scheduler.email
      audience              = google_cloudfunctions2_function.scaler.service_config[0].uri
    }
  }
  depends_on = [google_cloud_run_service_iam_member.scheduler_invokes]
}
