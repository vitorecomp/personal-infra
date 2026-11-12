variable "project_id" {
  description = "GCP project ID that owns the VM"
  type        = string
}

variable "name" {
  description = "Base name for the VM and its network resources (e.g. taiga)"
  type        = string
}

variable "region" {
  description = "Region (free tier: us-west1, us-central1 or us-east1)"
  type        = string
}

variable "zone" {
  description = "Zone inside var.region"
  type        = string
}

variable "machine_type" {
  description = "Machine type. e2-micro is the always-free shape; e2-small is the in-place upgrade path"
  type        = string
  default     = "e2-micro"
}

variable "image" {
  description = "Boot image (only used at creation; later image releases are ignored)"
  type        = string
  default     = "ubuntu-os-cloud/ubuntu-2404-lts-amd64"
}

variable "boot_disk_size_gb" {
  description = "Boot disk size. 30 GB pd-standard is covered by the free tier"
  type        = number
  default     = 30
}

variable "boot_disk_type" {
  description = "Boot disk type. Only pd-standard is free-tier eligible"
  type        = string
  default     = "pd-standard"
}

variable "subnet_cidr" {
  description = "CIDR for the dedicated subnet"
  type        = string
  default     = "10.20.0.0/24"
}

variable "admin_username" {
  description = "Initial admin user created from instance metadata"
  type        = string
  default     = "ubuntu"
}

variable "admin_ssh_public_key" {
  description = "OpenSSH public key for the initial admin user"
  type        = string
}

variable "ssh_source_cidrs" {
  description = "CIDRs allowed to reach tcp/22 (GitHub-hosted runners use dynamic IPs, hence 0.0.0.0/0)"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "web_source_cidrs" {
  description = "CIDRs allowed to reach tcp/80 and tcp/443. Your /32 during rehearsal, 0.0.0.0/0 after DNS cutover"
  type        = list(string)
}

variable "deletion_protection" {
  description = "GCE deletion protection on the instance"
  type        = bool
  default     = true
}

variable "enable_snapshots" {
  description = "Attach a daily boot-disk snapshot schedule (snapshots are billed; off by default)"
  type        = bool
  default     = false
}

variable "snapshot_retention_days" {
  description = "Days to keep scheduled snapshots"
  type        = number
  default     = 7
}

variable "labels" {
  description = "Labels applied to the instance"
  type        = map(string)
  default     = {}
}
