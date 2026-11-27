output "project_id" {
  description = "GCP project ID hosting the GPU Managed Instance Group."
  value       = var.project_id
}

output "region" {
  description = "GCP region for VPC, Cloud NAT, and instance template."
  value       = var.region
}

output "zone" {
  description = "GCP zone for the stateful GPU Managed Instance Group."
  value       = var.zone
}

output "gpu_zone" {
  description = "Alias for the GCP zone hosting the GPU Managed Instance Group."
  value       = var.zone
}

output "vpc_network" {
  description = "VPC network name attached to the GPU instances."
  value       = local.vpc_name
}

output "use_spot" {
  description = "Whether the GPU Managed Instance Group provisions Spot VMs (true) or Standard on-demand VMs (false)."
  value       = var.use_spot
}

output "mig_name" {
  description = "Name of the stateful zonal Managed Instance Group."
  value       = google_compute_instance_group_manager.gpu.name
}

output "data_disk_iops" {
  description = "Desired provisioned IOPS of the stateful data disk (deploy.sh applies it to the existing disk)."
  value       = var.data_disk_iops
}

output "data_disk_throughput_mbps" {
  description = "Desired provisioned throughput (MiB/s) of the stateful data disk (deploy.sh applies it in place)."
  value       = var.data_disk_throughput_mbps
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

output "list_instances_command" {
  description = "gcloud command to inspect the current managed GPU instance status."
  value       = "gcloud compute instance-groups managed list-instances ${google_compute_instance_group_manager.gpu.name} --zone=${var.zone} --project=${var.project_id}"
}
