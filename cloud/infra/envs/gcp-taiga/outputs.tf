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
