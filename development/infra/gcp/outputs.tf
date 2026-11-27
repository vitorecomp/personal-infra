output "project_id" {
  description = "GCP project ID hosting the GPU Regional Managed Instance Group."
  value       = var.project_id
}

output "region" {
  description = "GCP region for VPC, Cloud NAT, GCS cache bucket, and Regional MIG."
  value       = var.region
}

output "zones" {
  description = "Effective target zones within the region for the multi-zone Regional MIG (empty means all zones in region)."
  value       = local.effective_zones
}

output "vpc_network" {
  description = "VPC network name attached to the GPU instances."
  value       = local.vpc_name
}

output "use_spot" {
  description = "Whether the GPU Regional Managed Instance Group provisions Spot VMs (true) or Standard on-demand VMs (false)."
  value       = var.use_spot
}

output "mig_name" {
  description = "Name of the stateless multi-zone Regional Managed Instance Group."
  value       = google_compute_region_instance_group_manager.gpu.name
}

output "instance_template" {
  description = "Name of the active GCE instance template."
  value       = google_compute_instance_template.gpu.name
}

output "service_account_email" {
  description = "Runtime service account email attached to GPU MIG instances."
  value       = google_service_account.gpu.email
}

output "runner_secret_id" {
  description = "Secret Manager secret ID storing the self-hosted runner bootstrap payload."
  value       = google_secret_manager_secret.runner_bootstrap.secret_id
}

output "runner_name" {
  description = "Effective self-hosted GitHub Actions runner name."
  value       = local.effective_runner_name
}

output "runner_username" {
  description = "Local non-root OS user executing the GitHub Actions self-hosted runner."
  value       = var.runner_username
}

output "cache_bucket_name" {
  description = "Name of the same-region GCS cache bucket storing Hugging Face weights, stack config, and runner state."
  value       = google_storage_bucket.gpu_cache.name
}

output "cache_bucket_url" {
  description = "GCS URL (gs://...) of the same-region GPU cache bucket."
  value       = "gs://${google_storage_bucket.gpu_cache.name}"
}

output "list_instances_command" {
  description = "gcloud command to inspect the current managed GPU instance status across zones."
  value       = "gcloud compute instance-groups managed list-instances ${google_compute_region_instance_group_manager.gpu.name} --region=${var.region} --project=${var.project_id}"
}
