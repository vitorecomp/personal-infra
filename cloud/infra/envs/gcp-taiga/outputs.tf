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

output "blog_backup_bucket" {
  description = "restic repository URL for the blog VM (.env RESTIC_REPOSITORY)"
  value       = "s3:https://storage.googleapis.com/${google_storage_bucket.blog_backups.name}/personal-blog"
}

output "blog_backup_writer_email" {
  description = "Service account to create the blog restic HMAC key for"
  value       = google_service_account.blog_backup_writer.email
}
