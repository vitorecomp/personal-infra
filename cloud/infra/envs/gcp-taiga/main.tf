# Taiga compose VM on the GCP free tier (project personal-project-514501), plus
# the single GCS bucket that receives the restic backups of every compose stack
# (one folder per stack: /taiga, /personal-blog).
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

# --- Backups: one bucket for every stack ------------------------------------
# restic repositories live under /<stack>. The HMAC key each VM uses is created by
# hand (`gcloud storage hmac create`) so the secret never lands in Terraform state.

resource "google_service_account" "backup_writer" {
  account_id   = "stack-backup-writer"
  display_name = "Compose stack restic backup writer"
  description  = "Writes encrypted restic snapshots of the compose stacks to ${var.backup_bucket_name}"

  depends_on = [google_project_service.this]
}

resource "google_storage_bucket" "backups" {
  name                        = var.backup_bucket_name
  location                    = upper(var.region) # us-central1 keeps it inside the 5 GB free tier
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false
  labels                      = merge(local.labels, { stack = "all", purpose = "backups" })

  depends_on = [google_project_service.this]
}

resource "google_storage_bucket_iam_member" "backup_writer" {
  bucket = google_storage_bucket.backups.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.backup_writer.email}"
}
