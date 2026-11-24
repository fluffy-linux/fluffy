terraform {
  required_version = ">= 1.6"

  # State in a GCS bucket made once with gcloud (infra/README.md):
  #   terraform -chdir=infra/terraform init
  backend "gcs" {
    bucket = "fluffy-linux-tfstate"
    prefix = "ci"
  }

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    buildkite = {
      source  = "buildkite/buildkite"
      version = "~> 1.0"
    }
  }
}

# Authenticates with the gcloud login's token, in the environment:
#   GOOGLE_OAUTH_ACCESS_TOKEN="$(gcloud auth print-access-token)"
provider "google" {
  project = var.project
  region  = var.region
}

# Buildkite, with an API token that can write pipelines and clusters
# (Secret Manager: buildkite-terraform-token), in the environment:
#   BUILDKITE_API_TOKEN="$(gcloud secrets versions access latest --secret buildkite-terraform-token)"
provider "buildkite" {
  organization = "fluffy-linux"
}
