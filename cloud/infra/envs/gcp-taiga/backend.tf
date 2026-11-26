# State lives in a versioned GCS bucket created once by hand
# (pass -backend-config="bucket=$TF_STATE_BUCKET" or backend.hcl to terraform init;
# see documentation/vm-provisioning.md, "One-time prerequisites").
terraform {
  backend "gcs" {
    prefix = "vms/gcp-taiga"
  }
}
