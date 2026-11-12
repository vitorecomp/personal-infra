variable "project_id" {
  description = "GCP project for the Taiga VM"
  type        = string
  default     = "personal-project-514501"
}

variable "region" {
  description = "Region (free tier: us-west1, us-central1 or us-east1)"
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "Zone for the VM"
  type        = string
  default     = "us-central1-a"
}

variable "machine_type" {
  description = "e2-micro (always free) or e2-small (in-place upgrade if 1 GB is not enough)"
  type        = string
  default     = "e2-micro"
}

variable "admin_ssh_public_key" {
  description = "OpenSSH public key for the initial 'ubuntu' admin user"
  type        = string
}

variable "web_source_cidrs" {
  description = "CIDRs allowed on tcp/80,443: your public IP /32 until DNS cutover, then [\"0.0.0.0/0\"]"
  type        = list(string)
}

variable "enable_snapshots" {
  description = "Daily boot-disk snapshots (billed; restic backups are the primary safety net)"
  type        = bool
  default     = false
}

variable "blog_backup_bucket_name" {
  description = "Globally unique GCS bucket that receives the Oracle blog VM's restic backups"
  type        = string
  default     = "vitorx86-blog-backups"
}
