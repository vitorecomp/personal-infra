# Taiga compose VM on the GCP free tier (project personal-project-514501), plus
# the GCS bucket that receives the *blog* VM's restic backups (backups always
# live in the other cloud so losing one account never takes its backups with it).
#
# Applied manually from a workstation: documentation/vm-provisioning.md.

locals {
  labels = {
    managed-by = "terraform"
    repo       = "personal-infra"
    stack      = "taiga"
  }
}

resource "google_project_service" "this" {
  for_each = toset([
    "compute.googleapis.com",
    "iam.googleapis.com",
    "storage.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
  ])

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

module "taiga_vm" {
  source = "../../modules/gce-vm"

  project_id           = var.project_id
  name                 = "taiga"
  region               = var.region
  zone                 = var.zone
  machine_type         = var.machine_type
  admin_ssh_public_key = var.admin_ssh_public_key
  web_source_cidrs     = var.web_source_cidrs
  enable_snapshots     = var.enable_snapshots
  labels               = local.labels

  depends_on = [google_project_service.this]
}

# --- Cross-cloud backup target for the Oracle blog VM -----------------------
# The HMAC key restic uses is created by hand (`gcloud storage hmac create`)
# so the secret never lands in Terraform state.

resource "google_service_account" "blog_backup_writer" {
  account_id   = "blog-backup-writer"
  display_name = "Blog restic backup writer"
  description  = "Writes encrypted restic snapshots of the Oracle blog VM to ${var.blog_backup_bucket_name}"

  depends_on = [google_project_service.this]
}

resource "google_storage_bucket" "blog_backups" {
  name                        = var.blog_backup_bucket_name
  location                    = upper(var.region) # us-central1 keeps it inside the 5 GB free tier
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false
  labels                      = merge(local.labels, { stack = "personal-blog", purpose = "backups" })

  depends_on = [google_project_service.this]
}

resource "google_storage_bucket_iam_member" "blog_backup_writer" {
  bucket = google_storage_bucket.blog_backups.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.blog_backup_writer.email}"
}
