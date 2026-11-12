# State lives in a versioned GCS bucket created once by hand
# (see documentation/vm-provisioning.md, "One-time prerequisites").
terraform {
  backend "gcs" {
    bucket = "my-gcp-project-tfstate"
    prefix = "vms/gcp-taiga"
  }
}
