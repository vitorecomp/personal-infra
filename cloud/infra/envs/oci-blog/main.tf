# Ghost blog compose VM on OCI Always Free (compartment vitorecomp), plus the
# Object Storage bucket that receives the *Taiga* VM's restic backups (backups
# always live in the other cloud).
#
# Applied manually from a workstation: documentation/vm-provisioning.md.

locals {
  freeform_tags = {
    "managed-by" = "terraform"
    "repo"       = "personal-infra"
    "stack"      = "personal-blog"
  }
}

module "blog_vm" {
  source = "../../modules/oci-vm"

  tenancy_ocid              = var.tenancy_ocid
  compartment_ocid          = var.compartment_ocid
  name                      = "blog"
  ocpus                     = var.ocpus
  memory_in_gbs             = var.memory_in_gbs
  availability_domain_index = var.availability_domain_index
  admin_ssh_public_key      = var.admin_ssh_public_key
  web_source_cidrs          = var.web_source_cidrs
  freeform_tags             = local.freeform_tags
}

# --- Cross-cloud backup target for the GCE Taiga VM -------------------------
# The S3-compatible Customer Secret Key restic uses is created by hand in the
# console so the secret never lands in Terraform state.

data "oci_objectstorage_namespace" "this" {
  compartment_id = var.tenancy_ocid
}

resource "oci_objectstorage_bucket" "taiga_backups" {
  compartment_id = var.compartment_ocid
  namespace      = data.oci_objectstorage_namespace.this.namespace
  name           = var.taiga_backup_bucket_name
  access_type    = "NoPublicAccess"
  storage_tier   = "Standard"
  versioning     = "Disabled"
  freeform_tags  = merge(local.freeform_tags, { "stack" = "taiga", "purpose" = "backups" })
}
