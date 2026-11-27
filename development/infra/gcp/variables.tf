variable "project_id" {
  description = "GCP project ID where resources will be deployed (supplied from active gcloud config by deploy.sh)."
  type        = string
}

variable "region" {
  description = "GCP region for VPC, Cloud NAT, GCS cache bucket, and multi-zone GPU Regional Managed Instance Group resources."
  type        = string
  default     = "europe-west4"
}

variable "zones" {
  description = "Target zones within `region` for the multi-zone Regional MIG; when empty, uses `zone` if set or all zones in `region`."
  type        = list(string)
  default     = []
}

variable "zone" {
  description = "Optional single-zone override within `region` for backward compatibility (ignored when `zones` is non-empty)."
  type        = string
  default     = ""
}

variable "name_prefix" {
  description = "Prefix applied to all created resources."
  type        = string
  default     = "dev-gpu"
}

variable "cache_bucket_name" {
  description = "Optional GCS bucket name for persistent Hugging Face weights, stack config, and runner state; defaults to `<project_id>-<name_prefix>-cache-<region>`."
  type        = string
  default     = ""
}

variable "cache_bucket_force_destroy" {
  description = "Allow Terraform destroy to delete non-empty GCS cache bucket objects."
  type        = bool
  default     = false
}

variable "use_spot" {
  description = "Provision the GPU VM in the Managed Instance Group as a Spot VM (true) or Standard on-demand VM (false)."
  type        = bool
  default     = true
}

variable "machine_type" {
  description = "GCE machine type for the GPU VM in the Managed Instance Group."
  type        = string
  default     = "g4-standard-192"
}

variable "boot_image" {
  description = "Boot disk OS image for the GPU VM."
  type        = string
  default     = "ubuntu-os-cloud/ubuntu-2404-lts-amd64"
}

variable "boot_disk_type" {
  description = "Boot disk type for the GPU VM (G4 requires Hyperdisk)."
  type        = string
  default     = "hyperdisk-balanced"
}

variable "boot_disk_size_gb" {
  description = "Boot disk size in GB for the GPU VM (includes headroom for OS, kernel headers, and NVIDIA drivers)."
  type        = number
  default     = 50
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
  description = "Ephemeral Hyperdisk data disk type for the GPU VM (G4 requires Hyperdisk; persistent state is synced to the regional GCS cache bucket)."
  type        = string
  default     = "hyperdisk-balanced"
}

variable "data_disk_size_gb" {
  description = "Ephemeral Hyperdisk data disk size in GB mounted at /mnt/data on the GPU VM (auto-deleted on recreation/zone failover)."
  type        = number
  default     = 3000
}

# Model loading (475 GiB, mmap page faults) is IOPS-bound: with 16 MiB readahead the reads average ~92 KiB, so a
# full-size replica measured 357 MB/s at 4,000 IOPS (~20 min per cold load) vs ~40 min at the old 3,060 IOPS /
# 200 MiB/s cap. 8,000 IOPS / 750 MiB/s targets ~700 MB/s (~11 min). europe-west4 list price beyond the free 3,000 IOPS /
# 140 MiB/s: $0.005 per IOPS-month and $0.042 per MiB/s-month, i.e. ~$51/month on top of capacity.
variable "data_disk_iops" {
  description = "Provisioned IOPS for the GPU VM ephemeral data Hyperdisk (throughput may be at most IOPS / 4 MiB/s)."
  type        = number
  default     = 8000
}

variable "data_disk_throughput_mbps" {
  description = "Provisioned throughput (MiB/s) for the GPU VM ephemeral data Hyperdisk."
  type        = number
  default     = 750
}

variable "enable_shielded_vm" {
  description = "Enable Shielded VM (Secure Boot, vTPM, Integrity Monitoring)."
  type        = bool
  default     = true
}

variable "use_default_vpc" {
  description = "Attach the GPU MIG and firewall rules to an existing VPC network ('default' by default) instead of creating a custom VPC and subnetwork."
  type        = bool
  default     = false
}

variable "default_vpc_name" {
  description = "Name of the existing VPC network to use when use_default_vpc = true."
  type        = string
  default     = "default"
}

variable "default_subnetwork_name" {
  description = "Optional regional subnetwork name override when use_default_vpc = true (defaults to default_vpc_name, e.g. 'default' for auto-mode networks)."
  type        = string
  default     = ""
}

variable "subnet_cidr" {
  description = "Primary CIDR range for the custom VPC subnet (used when use_default_vpc = false)."
  type        = string
  default     = "10.10.0.0/24"
}

variable "enable_external_ip" {
  description = "Attach an ephemeral external IP on nic0 (true) or route outbound traffic via Cloud Router and Cloud NAT (false)."
  type        = bool
  default     = true
}

variable "enable_ingress_firewalls" {
  description = "Manage VPC ingress firewall rules (optional SSH proxy + default deny). Disable in projects where external policy controllers manage VPC ingress."
  type        = bool
  default     = true
}

variable "enable_public_ingress" {
  description = "Allow direct public SSH ingress from allowed_ssh_cidrs when enable_external_ip = true. Disabled by default."
  type        = bool
  default     = false
}

variable "ssh_proxy_cidrs" {
  description = "Proxy CIDR ranges allowed to reach TCP port 22 for optional admin debugging (defaults to Google Cloud IAP 35.235.240.0/20)."
  type        = list(string)
  default     = ["35.235.240.0/20"]

  validation {
    condition     = length(var.ssh_proxy_cidrs) > 0 && !contains(var.ssh_proxy_cidrs, "0.0.0.0/0")
    error_message = "ssh_proxy_cidrs must be non-empty and must not contain 0.0.0.0/0."
  }
}

variable "allowed_ssh_cidrs" {
  description = "Optional source CIDR allowlist for direct SSH when enable_public_ingress = true (never 0.0.0.0/0)."
  type        = list(string)
  default     = []

  validation {
    condition     = !contains(var.allowed_ssh_cidrs, "0.0.0.0/0")
    error_message = "allowed_ssh_cidrs must not contain 0.0.0.0/0."
  }
}

variable "ssh_hostname_template" {
  description = "Optional SSH hostname template override for optional admin debugging (supports {instance}, {zone}, {project})."
  type        = string
  default     = ""
}

variable "enable_os_login" {
  description = "Enable Cloud OS Login on the GPU instance metadata (required on projects enforcing constraints/compute.requireOsLogin)."
  type        = bool
  default     = true
}

variable "github_repo" {
  description = "GitHub owner/repo (e.g. owner/repo) the GPU instance self-registers against on boot."
  type        = string
  default     = ""
}

variable "runner_name" {
  description = "Self-hosted runner name registered in GitHub (defaults to <name_prefix>-runner when empty)."
  type        = string
  default     = ""
}

variable "runner_labels" {
  description = "Comma-separated labels attached to the self-hosted runner."
  type        = string
  default     = "self-hosted,linux,x64,gcp-gpu"
}

variable "runner_username" {
  description = "Dedicated non-root local user created on the GPU VM for the GitHub Actions self-hosted runner."
  type        = string
  default     = "github-runner"
}

variable "runner_token" {
  description = "Short-lived GitHub Actions runner registration token minted by deploy.sh for initial registration."
  type        = string
  default     = ""
  sensitive   = true
}

variable "runner_pat" {
  description = "Optional repo-scoped Fine-Grained PAT (Administration: Read & Write) allowing autonomous token minting across stateless recreations."
  type        = string
  default     = ""
  sensitive   = true
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
