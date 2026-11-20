output "project_id" {
  value = var.project_id
}

output "region" {
  value = var.region
}

output "zone" {
  value = var.zone
}

output "controller_zone" {
  value = local.controller_zone
}

output "controller_name" {
  value = google_compute_instance.controller.name
}

output "controller_external_ip" {
  description = "Fixed regional Static External IP attached to the always-on STANDARD Controller VM."
  value       = var.enable_external_ip ? google_compute_address.external_ip[0].address : null
}

output "controller_internal_ip" {
  value = google_compute_address.controller_internal_ip.address
}

output "gpu_vm_name" {
  value = google_compute_instance.gpu_vm.name
}

output "gpu_external_ip" {
  description = "Fixed regional Static External IP attached to the Spot GPU VM (preserved across STOP/start)."
  value       = var.enable_external_ip ? google_compute_address.gpu_external_ip[0].address : null
}

output "gpu_vm_internal_ip" {
  value = google_compute_address.gpu_internal_ip.address
}

output "ssh_username" {
  value = var.enable_os_login ? local.oslogin_username : var.ssh_username
}

output "local_ssh_username" {
  value = var.ssh_username
}

output "runner_username" {
  value = var.runner_username
}

output "ssh_public_key" {
  value = local.ssh_public_key
}

output "ssh_private_key" {
  value     = tls_private_key.ssh.private_key_openssh
  sensitive = true
}

output "controller_host_public_key" {
  value = "${trimspace(tls_private_key.ssh_host_controller.public_key_openssh)} ${local.controller_vm_name}-host"
}

output "gpu_host_public_key" {
  value = "${trimspace(tls_private_key.ssh_host_gpu.public_key_openssh)} ${local.gpu_vm_name}-host"
}

output "known_hosts_entries" {
  description = "Deterministic known_hosts entries for Controller and GPU VMs."
  value = join("\n", compact([
    var.enable_external_ip ? "${google_compute_address.external_ip[0].address} ${trimspace(tls_private_key.ssh_host_controller.public_key_openssh)}" : "",
    "${google_compute_address.controller_internal_ip.address} ${trimspace(tls_private_key.ssh_host_controller.public_key_openssh)}",
    var.enable_external_ip ? "${google_compute_address.gpu_external_ip[0].address} ${trimspace(tls_private_key.ssh_host_gpu.public_key_openssh)}" : "",
    "${google_compute_address.gpu_internal_ip.address} ${trimspace(tls_private_key.ssh_host_gpu.public_key_openssh)}",
  ]))
}

output "controller_ssh_command" {
  description = "Connect to the Controller VM via gcloud IAP tunnel (public ingress disabled)."
  value       = "gcloud compute ssh ${google_compute_instance.controller.name} --zone=${local.controller_zone} --project=${var.project_id} --tunnel-through-iap"
}

output "gpu_ssh_command" {
  description = "Connect directly to the GPU VM via gcloud IAP tunnel (public ingress disabled)."
  value       = "gcloud compute ssh ${google_compute_instance.gpu_vm.name} --zone=${var.zone} --project=${var.project_id} --tunnel-through-iap"
}
