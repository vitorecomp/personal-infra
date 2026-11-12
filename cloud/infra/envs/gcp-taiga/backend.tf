# State lives in a versioned GCS bucket created once by hand
# (see documentation/vm-provisioning.md, "One-time prerequisites").
terraform {
  backend "gcs" {
    bucket = "personal-project-514501-tfstate"
    prefix = "vms/gcp-taiga"
  }
}
