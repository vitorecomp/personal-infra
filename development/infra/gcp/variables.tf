variable "project_id" {
  description = "GCP project ID where resources will be deployed (supplied from active gcloud config by deploy.sh)."
  type        = string
}

variable "region" {
  description = "GCP region for VPC, Cloud NAT, static IPs, Controller VM, and GPU VM."
  type        = string
  default     = "europe-west4"
}

variable "zone" {
  description = "Primary GCP zone for the persistent Spot GPU VM (and its Hyperdisk data volume)."
  type        = string
  default     = "europe-west4-a"
}

variable "controller_zone" {
  description = "GCP zone for the always-on small STANDARD controller/watchdog VM (defaults to var.zone when empty)."
  type        = string
  default     = ""
}

variable "name_prefix" {
  description = "Prefix applied to all created resources."
  type        = string
  default     = "dev-gpu"
}

variable "controller_machine_type" {
  description = "Machine type for the small always-on STANDARD controller/bastion VM."
  type        = string
  default     = "e2-small"
}

variable "controller_disk_size_gb" {
  description = "Boot disk size in GB for the controller/runner VM."
  type        = number
  default     = 100
}

variable "controller_disk_type" {
  description = "Boot disk type for the controller VM."
  type        = string
  default     = "pd-balanced"
}

variable "watchdog_poll_interval_sec" {
  description = "Seconds between GPU VM state checks when RUNNING."
  type        = number
  default     = 20
}

variable "watchdog_retry_interval_sec" {
  description = "Seconds to wait between start retries when the Spot GPU VM is stopped/preempted or waiting for capacity."
  type        = number
  default     = 30
}

variable "machine_type" {
  description = "GCE machine type for the main GPU VM."
  type        = string
  default     = "g4-standard-192"
}

variable "provisioning_model" {
  description = "Provisioning model for the GPU VM: SPOT (auto-restarted by controller) or STANDARD."
  type        = string
  default     = "SPOT"

  validation {
    condition     = contains(["SPOT", "STANDARD"], var.provisioning_model)
    error_message = "provisioning_model must be SPOT or STANDARD."
  }
}

variable "subnet_cidr" {
  description = "Primary CIDR range for the custom VPC subnet."
  type        = string
  default     = "10.10.0.0/24"
}

variable "enable_external_ip" {
  description = "Attach fixed regional Static External IPs to the Controller and GPU VMs."
  type        = bool
  default     = true
}

variable "enable_ingress_firewalls" {
  description = "Manage VPC ingress firewall rules (internal VPC + IAP SSH). Disable in projects where external policy controllers manage VPC ingress."
  type        = bool
  default     = true
}

variable "enable_public_ingress" {
  description = "Allow direct public internet ingress (SSH/RDP/ICMP) from allowed_ssh_cidrs. Disabled by default; SSH uses gcloud IAP tunneling."
  type        = bool
  default     = false
}

variable "allowed_ssh_cidrs" {
  description = "Optional source CIDR allowlist when enable_public_ingress = true (never 0.0.0.0/0)."
  type        = list(string)
  default     = []

  validation {
    condition     = !contains(var.allowed_ssh_cidrs, "0.0.0.0/0")
    error_message = "allowed_ssh_cidrs must not contain 0.0.0.0/0."
  }
}

variable "boot_image" {
  description = "Boot disk OS image for both Controller and GPU VMs."
  type        = string
  default     = "ubuntu-os-cloud/ubuntu-2404-lts-amd64"
}

variable "boot_disk_type" {
  description = "Boot disk type for the GPU VM (G4 requires Hyperdisk)."
  type        = string
  default     = "hyperdisk-balanced"
}

variable "boot_disk_size_gb" {
  description = "Boot disk size in GB for the GPU VM."
  type        = number
  default     = 10
}

variable "boot_disk_iops" {
  description = "Provisioned IOPS for the GPU VM boot Hyperdisk."
  type        = number
  default     = 3060
}

variable "boot_disk_throughput_mbps" {
  description = "Provisioned throughput (MiB/s) for the GPU VM boot Hyperdisk."
  type        = number
  default     = 155
}

variable "data_disk_type" {
  description = "Persistent data disk type for the GPU VM (G4 requires Hyperdisk)."
  type        = string
  default     = "hyperdisk-balanced"
}

variable "data_disk_size_gb" {
  description = "Persistent Hyperdisk data disk size in GB mounted at /mnt/data on the GPU VM."
  type        = number
  default     = 3000
}

variable "data_disk_iops" {
  description = "Provisioned IOPS for the GPU VM data Hyperdisk."
  type        = number
  default     = 3060
}

variable "data_disk_throughput_mbps" {
  description = "Provisioned throughput (MiB/s) for the GPU VM data Hyperdisk."
  type        = number
  default     = 200
}

variable "ssh_username" {
  description = "Local sudo username provisioned on both VMs with the Terraform-managed SSH key."
  type        = string
  default     = "dev"
}

variable "runner_username" {
  description = "Dedicated non-root local user created on the controller VM for the GitHub Actions self-hosted runner."
  type        = string
  default     = "github-runner"
}

variable "enable_os_login" {
  description = "Enable Cloud OS Login (required on projects enforcing constraints/compute.requireOsLogin). Set to false on non-restricted projects to use var.ssh_username in instance ssh-keys metadata."
  type        = bool
  default     = true
}

variable "oslogin_user" {
  description = "Google account email for Cloud OS Login SSH key registration (optional; auto-detected from ADC when empty)."
  type        = string
  default     = ""
}

variable "enable_shielded_vm" {
  description = "Enable Shielded VM (Secure Boot, vTPM, Integrity Monitoring)."
  type        = bool
  default     = true
}

variable "labels" {
  description = "Labels applied to supported GCP resources."
  type        = map(string)
  default = {
    managed-by = "terraform"
    repo       = "personal-infra"
    workload   = "dev-gpu"
  }
}
