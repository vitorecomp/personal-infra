output "public_ip" {
  description = "Reserved IPv4 of the blog VM (DEPLOY_HOST for blog-prod; DNS A record at cutover)"
  value       = module.blog_vm.public_ip
}

output "admin_ssh" {
  description = "Admin SSH target for cloud/scripts/bootstrap_vm.py"
  value       = module.blog_vm.admin_ssh
}

output "instance_ocid" {
  description = "OCID of the blog instance"
  value       = module.blog_vm.instance_ocid
}

output "availability_domain" {
  description = "Availability domain the instance landed in"
  value       = module.blog_vm.availability_domain
}

output "taiga_backup_repository" {
  description = "restic repository URL for the Taiga VM (.env RESTIC_REPOSITORY)"
  value       = "s3:https://${data.oci_objectstorage_namespace.this.namespace}.compat.objectstorage.${var.region}.oraclecloud.com/${oci_objectstorage_bucket.taiga_backups.name}/taiga"
}
