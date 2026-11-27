data "google_compute_network" "default" {
  count = var.use_default_vpc ? 1 : 0

  project = var.project_id
  name    = var.default_vpc_name
}

data "google_compute_subnetwork" "default" {
  count = var.use_default_vpc ? 1 : 0

  project = var.project_id
  name    = trimspace(var.default_subnetwork_name) != "" ? trimspace(var.default_subnetwork_name) : var.default_vpc_name
  region  = var.region
}

resource "google_compute_network" "vpc" {
  count = var.use_default_vpc ? 0 : 1

  project                 = var.project_id
  name                    = "${var.name_prefix}-vpc"
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
}

resource "google_compute_subnetwork" "subnet" {
  count = var.use_default_vpc ? 0 : 1

  project                  = var.project_id
  name                     = "${var.name_prefix}-subnet"
  ip_cidr_range            = var.subnet_cidr
  region                   = var.region
  network                  = google_compute_network.vpc[0].id
  private_ip_google_access = true
}

locals {
  vpc_id         = var.use_default_vpc ? data.google_compute_network.default[0].id : google_compute_network.vpc[0].id
  vpc_name       = var.use_default_vpc ? data.google_compute_network.default[0].name : google_compute_network.vpc[0].name
  subnetwork_id  = var.use_default_vpc ? data.google_compute_subnetwork.default[0].id : google_compute_subnetwork.subnet[0].id
  net_res_prefix = var.use_default_vpc ? "${var.name_prefix}-${var.default_vpc_name}" : var.name_prefix
}

# Cloud NAT provides outbound HTTPS (443) to GitHub and Hugging Face when external IPs are disabled.
resource "google_compute_router" "router" {
  count = var.enable_external_ip ? 0 : 1

  project = var.project_id
  name    = "${local.net_res_prefix}-router"
  region  = var.region
  network = local.vpc_id
}

resource "google_compute_router_nat" "nat" {
  count = var.enable_external_ip ? 0 : 1

  project                            = var.project_id
  name                               = "${local.net_res_prefix}-nat"
  router                             = google_compute_router.router[0].name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"

  subnetwork {
    name                    = local.subnetwork_id
    source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
  }

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# Optional SSH via IAP / configured proxy CIDRs for admin debugging only (normal workflow is zero-SSH).
resource "google_compute_firewall" "allow_iap_ssh" {
  count = var.enable_ingress_firewalls ? 1 : 0

  project   = var.project_id
  name      = "${local.net_res_prefix}-allow-iap-ssh"
  network   = local.vpc_id
  direction = "INGRESS"
  priority  = 1000

  source_ranges = var.ssh_proxy_cidrs
  target_tags   = ["${var.name_prefix}-vm"]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

# Optional direct public SSH ingress (disabled by default).
resource "google_compute_firewall" "allow_external_ssh" {
  count = var.enable_ingress_firewalls && var.enable_public_ingress && var.enable_external_ip && length(var.allowed_ssh_cidrs) > 0 ? 1 : 0

  project   = var.project_id
  name      = "${local.net_res_prefix}-allow-ingress"
  network   = local.vpc_id
  direction = "INGRESS"
  priority  = 1000

  source_ranges = var.allowed_ssh_cidrs
  target_tags   = ["${var.name_prefix}-vm"]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

# Explicitly deny all other ingress traffic to the GPU VM.
resource "google_compute_firewall" "deny_other_ingress" {
  count = var.enable_ingress_firewalls ? 1 : 0

  project   = var.project_id
  name      = "${local.net_res_prefix}-deny-other-ingress"
  network   = local.vpc_id
  direction = "INGRESS"
  priority  = 65534

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["${var.name_prefix}-vm"]

  deny {
    protocol = "all"
  }
}

# Allow outbound internet egress for GitHub Actions runner registration, package installs, and model pulls.
resource "google_compute_firewall" "allow_egress" {
  project   = var.project_id
  name      = "${local.net_res_prefix}-allow-egress"
  network   = local.vpc_id
  direction = "EGRESS"
  priority  = 1000

  destination_ranges = ["0.0.0.0/0"]
  target_tags        = ["${var.name_prefix}-vm"]

  allow {
    protocol = "all"
  }
}
