output "public_ip" {
  description = "Reserved public IPv4 of the VM (point the DNS A record here at cutover)"
  value       = oci_core_public_ip.this.ip_address
}

output "instance_ocid" {
  description = "OCID of the compute instance"
  value       = oci_core_instance.this.id
}

output "availability_domain" {
  description = "Availability domain the instance landed in"
  value       = oci_core_instance.this.availability_domain
}

output "image_id" {
  description = "Image OCID the instance was created from"
  value       = oci_core_instance.this.source_details[0].source_id
}

output "admin_ssh" {
  description = "Initial admin SSH target for bootstrap_vm.py"
  value       = "ubuntu@${oci_core_public_ip.this.ip_address}"
}
