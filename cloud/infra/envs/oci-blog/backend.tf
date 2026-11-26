# State lives in the same versioned GCS bucket as gcp-taiga (one place for all
# VM state; pass -backend-config="bucket=$TF_STATE_BUCKET" or backend.hcl to terraform init).
# Requires `gcloud auth application-default login` even though the resources
# themselves are on OCI. See documentation/vm-provisioning.md.
terraform {
  backend "gcs" {
    prefix = "vms/oci-blog"
  }
}
