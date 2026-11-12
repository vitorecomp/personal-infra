output "public_ip" {
  description = "Static IPv4 of the Taiga VM (DEPLOY_HOST for taiga-prod; DNS A record at cutover)"
  value       = module.taiga_vm.public_ip
}

output "admin_ssh" {
  description = "Admin SSH target for cloud/scripts/bootstrap_vm.py"
  value       = module.taiga_vm.admin_ssh
}

output "instance_name" {
  description = "Compute Engine instance name"
  value       = module.taiga_vm.instance_name
}

output "zone" {
  description = "Zone of the instance"
  value       = module.taiga_vm.zone
}

output "backup_bucket" {
  description = "GCS bucket holding every stack's restic repository"
  value       = google_storage_bucket.backups.name
}

output "backup_writer_email" {
  description = "Service account to create the restic HMAC keys for (one per VM)"
  value       = google_service_account.backup_writer.email
}

output "taiga_restic_repository" {
  description = "RESTIC_REPOSITORY for the Taiga VM .env"
  value       = "s3:https://storage.googleapis.com/${google_storage_bucket.backups.name}/taiga"
}

output "blog_restic_repository" {
  description = "RESTIC_REPOSITORY for the blog VM .env"
  value       = "s3:https://storage.googleapis.com/${google_storage_bucket.backups.name}/personal-blog"
}

output "taiga_run_url" {
  description = "Cloud Run URL of the taiga service (edge Caddy proxies taiga.vitorx86.dev here)"
  value       = google_cloud_run_v2_service.taiga.uri
}

output "taiga_image_repository" {
  description = "Artifact Registry repository for Taiga images"
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.taiga.repository_id}/taiga"
}

output "taiga_media_bucket" {
  description = "GCS bucket mounted at /mnt/taiga-storage in the Taiga container"
  value       = google_storage_bucket.taiga_media.name
}

output "github_wif_provider" {
  description = "GCP_WIF_PROVIDER repository variable (google-github-actions/auth workload_identity_provider)"
  value       = google_iam_workload_identity_pool_provider.github.name
}

output "github_deployer_email" {
  description = "GCP_DEPLOY_SA repository variable (service account the taiga-prod jobs impersonate)"
  value       = google_service_account.github_deployer.email
}
