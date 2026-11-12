terraform {
  required_version = ">= 1.9, < 2.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.0"
    }
  }
}

# Authenticates with your own Application Default Credentials
# (`gcloud auth application-default login`); no service-account keys involved.
provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}
