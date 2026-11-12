# GCP free-tier footprint (project personal-project-514501):
#   * e2-micro VM running the blog + the shared edge Caddy (docker compose)
#   * Taiga on Cloud Run (scale to zero), image in Artifact Registry, media in GCS,
#     secrets in Secret Manager; database on Neon (outside GCP)
#   * the GCS bucket that receives every stack's restic backups
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
    "run.googleapis.com",
    "artifactregistry.googleapis.com",
    "secretmanager.googleapis.com",
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

# --- Taiga on Cloud Run (free tier) ------------------------------------------
# Terraform owns the service's existence, identity and public access; deploys
# (cloud/taiga/deploy-cloudrun.sh, run on the VM by deploy_stack.py) own the revision
# template (image, env, secrets, volumes), hence ignore_changes on template.
# Free-tier guardrails: max 1 instance, scale to zero, request-based CPU, a single
# image version kept in Artifact Registry, 3 secret versions.

locals {
  taiga_secrets = toset(["taiga-secret-key", "taiga-db-password"])
  vm_sa_member  = "serviceAccount:${module.taiga_vm.service_account_email}"
}

resource "google_artifact_registry_repository" "taiga" {
  location               = var.region
  repository_id          = "taiga"
  format                 = "DOCKER"
  description            = "Taiga images built on the VM (only the newest version is kept: 0.5 GB free tier)"
  cleanup_policy_dry_run = false

  cleanup_policies {
    id     = "keep-newest"
    action = "KEEP"
    most_recent_versions {
      keep_count = 1
    }
  }

  cleanup_policies {
    id     = "delete-older"
    action = "DELETE"
    condition {
      tag_state  = "ANY"
      older_than = "86400s"
    }
  }

  depends_on = [google_project_service.this]
}

resource "google_storage_bucket" "taiga_media" {
  name                        = var.taiga_media_bucket_name
  location                    = upper(var.region)
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false
  labels                      = merge(local.labels, { purpose = "media" })

  depends_on = [google_project_service.this]
}

resource "google_service_account" "taiga_run" {
  account_id   = "taiga-run"
  display_name = "Taiga Cloud Run runtime"
  description  = "Runtime identity of the taiga Cloud Run service (media bucket + its secrets only)"

  depends_on = [google_project_service.this]
}

resource "google_storage_bucket_iam_member" "taiga_run_media" {
  bucket = google_storage_bucket.taiga_media.name
  role   = "roles/storage.objectUser"
  member = "serviceAccount:${google_service_account.taiga_run.email}"
}

resource "google_secret_manager_secret" "taiga" {
  for_each  = local.taiga_secrets
  secret_id = each.value
  labels    = local.labels

  replication {
    user_managed {
      replicas {
        location = var.region
      }
    }
  }

  depends_on = [google_project_service.this]
}

resource "google_secret_manager_secret_iam_member" "taiga_run_access" {
  for_each  = local.taiga_secrets
  secret_id = google_secret_manager_secret.taiga[each.value].id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.taiga_run.email}"
}

resource "google_cloud_run_v2_service" "taiga" {
  name                = "taiga"
  location            = var.region
  ingress             = "INGRESS_TRAFFIC_ALL"
  deletion_protection = false

  scaling {
    min_instance_count = 0
    max_instance_count = 1
  }

  template {
    service_account = google_service_account.taiga_run.email
    containers {
      image = "us-docker.pkg.dev/cloudrun/container/hello" # placeholder until the first deploy
    }
  }

  lifecycle {
    ignore_changes = [template, client, client_version]
  }

  depends_on = [google_project_service.this]
}

resource "google_cloud_run_v2_service_iam_member" "taiga_public" {
  name     = google_cloud_run_v2_service.taiga.name
  location = google_cloud_run_v2_service.taiga.location
  role     = "roles/run.invoker"
  member   = "allUsers"
}

# --- The VM deploys Taiga (keyless: its own service account) ---------------

resource "google_project_iam_member" "vm_run_developer" {
  project = var.project_id
  role    = "roles/run.developer"
  member  = local.vm_sa_member
}

resource "google_service_account_iam_member" "vm_acts_as_taiga_run" {
  service_account_id = google_service_account.taiga_run.name
  role               = "roles/iam.serviceAccountUser"
  member             = local.vm_sa_member
}

resource "google_artifact_registry_repository_iam_member" "vm_push" {
  location   = google_artifact_registry_repository.taiga.location
  repository = google_artifact_registry_repository.taiga.name
  role       = "roles/artifactregistry.writer"
  member     = local.vm_sa_member
}

resource "google_storage_bucket_iam_member" "vm_media" {
  bucket = google_storage_bucket.taiga_media.name
  role   = "roles/storage.objectAdmin" # one-off media copy + nightly backup of the bucket
  member = local.vm_sa_member
}

resource "google_storage_bucket_iam_member" "vm_media_bucket_read" {
  bucket = google_storage_bucket.taiga_media.name
  role   = "roles/storage.legacyBucketReader" # storage.buckets.get, needed by `gcloud storage rsync` (backups)
  member = local.vm_sa_member
}

resource "google_secret_manager_secret_iam_member" "vm_secret_versions" {
  for_each  = local.taiga_secrets
  secret_id = google_secret_manager_secret.taiga[each.value].id
  role      = "roles/secretmanager.secretVersionManager"
  member    = local.vm_sa_member
}

resource "google_secret_manager_secret_iam_member" "vm_secret_access" {
  for_each  = local.taiga_secrets
  secret_id = google_secret_manager_secret.taiga[each.value].id
  role      = "roles/secretmanager.secretAccessor" # compare before adding a version
  member    = local.vm_sa_member
}
