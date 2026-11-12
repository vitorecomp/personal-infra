variable "oci_profile" {
  description = "Profile name in ~/.oci/config"
  type        = string
  default     = "DEFAULT"
}

variable "region" {
  description = "Tenancy home region identifier (e.g. sa-saopaulo-1). Always Free A1 only exists in the home region"
  type        = string
}

variable "tenancy_ocid" {
  description = "Tenancy OCID (same value as 'tenancy' in ~/.oci/config)"
  type        = string
}

variable "compartment_ocid" {
  description = "OCID of the vitorecomp compartment (use the tenancy OCID if vitorecomp is the root compartment)"
  type        = string
}

variable "ocpus" {
  description = "A1 OCPUs (Always Free pool: 2 per tenancy)"
  type        = number
  default     = 1
}

variable "memory_in_gbs" {
  description = "A1 memory in GB (Always Free pool: 12 per tenancy)"
  type        = number
  default     = 6
}

variable "availability_domain_index" {
  description = "Availability domain index; bump it and re-plan on 'Out of host capacity'"
  type        = number
  default     = 0
}

variable "admin_ssh_public_key" {
  description = "OpenSSH public key for the image's 'ubuntu' user (applied only at creation)"
  type        = string
}

variable "web_source_cidrs" {
  description = "CIDRs allowed on tcp/80,443: your public IP /32 until DNS cutover, then [\"0.0.0.0/0\"]"
  type        = list(string)
}

variable "taiga_backup_bucket_name" {
  description = "Object Storage bucket that receives the GCE Taiga VM's restic backups"
  type        = string
  default     = "taiga-backups"
}
