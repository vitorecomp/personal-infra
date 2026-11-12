# State lives in the same versioned GCS bucket as gcp-taiga (one place for all
# VM state). Requires `gcloud auth application-default login` even though the
# resources themselves are on OCI. See documentation/vm-provisioning.md.
terraform {
  backend "gcs" {
    bucket = "personal-project-514501-tfstate"
    prefix = "vms/oci-blog"
  }
}
