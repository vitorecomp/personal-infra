variable "tenancy_ocid" {
  description = "Tenancy OCID (availability domains are listed at tenancy level)"
  type        = string
}

variable "compartment_ocid" {
  description = "Compartment OCID that owns every resource (vitorecomp)"
  type        = string
}

variable "name" {
  description = "Base name for the VM and its network resources (e.g. blog)"
  type        = string
}

variable "shape" {
  description = "Compute shape. VM.Standard.A1.Flex is the Always Free Ampere shape"
  type        = string
  default     = "VM.Standard.A1.Flex"
}

variable "ocpus" {
  description = "OCPUs for the flex shape (Always Free A1 pool: 2 OCPU per tenancy)"
  type        = number
  default     = 1
}

variable "memory_in_gbs" {
  description = "Memory for the flex shape (Always Free A1 pool: 12 GB per tenancy)"
  type        = number
  default     = 6
}

variable "boot_volume_size_in_gbs" {
  description = "Boot volume size (min 47 GB; counts against the 200 GB Always Free block pool)"
  type        = number
  default     = 50
}

variable "availability_domain_index" {
  description = "Index into the tenancy's availability domains; change it when A1 reports 'Out of host capacity'"
  type        = number
  default     = 0
}

variable "ubuntu_version" {
  description = "Canonical Ubuntu version used to look up the newest aarch64 image"
  type        = string
  default     = "24.04"
}

variable "image_ocid" {
  description = "Explicit image OCID; empty means the newest Canonical Ubuntu aarch64 image (only used at creation)"
  type        = string
  default     = ""
}

variable "vcn_cidr" {
  description = "CIDR for the dedicated VCN"
  type        = string
  default     = "10.30.0.0/16"
}

variable "subnet_cidr" {
  description = "CIDR for the public subnet"
  type        = string
  default     = "10.30.1.0/24"
}

variable "admin_ssh_public_key" {
  description = "OpenSSH public key for the image's default user (ubuntu). Only applied at creation"
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

variable "freeform_tags" {
  description = "Freeform tags applied to every resource"
  type        = map(string)
  default     = {}
}
