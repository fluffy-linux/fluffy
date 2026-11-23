terraform {
  required_version = ">= 1.6"

  # State in a GCS bucket made once with gcloud (infra/gcp/README.md):
  #   terraform -chdir=infra/gcp/terraform init
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
  }
}

# Authenticates with the gcloud login's token, in the environment:
#   GOOGLE_OAUTH_ACCESS_TOKEN="$(gcloud auth print-access-token)"
provider "google" {
  project = var.project
  region  = var.region
}
