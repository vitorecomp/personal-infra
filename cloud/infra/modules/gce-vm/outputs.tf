output "public_ip" {
  description = "Static public IPv4 of the VM (point the DNS A record here at cutover)"
  value       = google_compute_address.this.address
}

output "instance_name" {
  description = "Compute Engine instance name"
  value       = google_compute_instance.this.name
}

output "zone" {
  description = "Zone of the instance"
  value       = google_compute_instance.this.zone
}

output "service_account_email" {
  description = "Runtime service account attached to the VM"
  value       = google_service_account.vm.email
}

output "admin_ssh" {
  description = "Initial admin SSH target for bootstrap_vm.py"
  value       = "${var.admin_username}@${google_compute_address.this.address}"
}
