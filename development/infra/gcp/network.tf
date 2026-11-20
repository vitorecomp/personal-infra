resource "google_compute_network" "vpc" {
  project                 = var.project_id
  name                    = "${var.name_prefix}-vpc"
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
}

resource "google_compute_subnetwork" "subnet" {
  project                  = var.project_id
  name                     = "${var.name_prefix}-subnet"
  ip_cidr_range            = var.subnet_cidr
  region                   = var.region
  network                  = google_compute_network.vpc.id
  private_ip_google_access = true
}

# Cloud NAT provides outbound internet access only when external IPs are disabled.
resource "google_compute_router" "router" {
  count = var.enable_external_ip ? 0 : 1

  project = var.project_id
  name    = "${var.name_prefix}-router"
  region  = var.region
  network = google_compute_network.vpc.id
}

resource "google_compute_router_nat" "nat" {
  count = var.enable_external_ip ? 0 : 1

  project                            = var.project_id
  name                               = "${var.name_prefix}-nat"
  router                             = google_compute_router.router[0].name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"

  subnetwork {
    name                    = google_compute_subnetwork.subnet.id
    source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
  }

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# Fixed internal IPs so ProxyJump and watchdog targets never change across restarts.
resource "google_compute_address" "controller_internal_ip" {
  project      = var.project_id
  name         = "${var.name_prefix}-controller-internal-ip"
  region       = var.region
  subnetwork   = google_compute_subnetwork.subnet.id
  address_type = "INTERNAL"
  address      = cidrhost(var.subnet_cidr, 10)
}

resource "google_compute_address" "gpu_internal_ip" {
  project      = var.project_id
  name         = "${var.name_prefix}-vm-internal-ip"
  region       = var.region
  subnetwork   = google_compute_subnetwork.subnet.id
  address_type = "INTERNAL"
  address      = cidrhost(var.subnet_cidr, 11)
}

# Fixed regional static external IPs attached to both VMs (survive Spot STOP/start).
resource "google_compute_address" "external_ip" {
  count = var.enable_external_ip ? 1 : 0

  project      = var.project_id
  name         = "${var.name_prefix}-controller-ip"
  region       = var.region
  address_type = "EXTERNAL"
  network_tier = "PREMIUM"
  labels       = var.labels
}

resource "google_compute_address" "gpu_external_ip" {
  count = var.enable_external_ip ? 1 : 0

  project      = var.project_id
  name         = "${var.name_prefix}-vm-ip"
  region       = var.region
  address_type = "EXTERNAL"
  network_tier = "PREMIUM"
  labels       = var.labels
}

# Allows SSH/internal communication inside the VPC between Controller and GPU VMs.
resource "google_compute_firewall" "allow_internal" {
  count = var.enable_ingress_firewalls ? 1 : 0

  project   = var.project_id
  name      = "${var.name_prefix}-allow-internal"
  network   = google_compute_network.vpc.id
  direction = "INGRESS"
  priority  = 950

  source_ranges = [var.subnet_cidr]
  target_tags   = ["${var.name_prefix}-ssh", "${var.name_prefix}-vm"]

  allow {
    protocol = "tcp"
  }

  allow {
    protocol = "udp"
  }

  allow {
    protocol = "icmp"
  }
}

# Allows SSH via Google Cloud Identity-Aware Proxy (IAP).
resource "google_compute_firewall" "allow_iap_ssh" {
  count = var.enable_ingress_firewalls ? 1 : 0

  project   = var.project_id
  name      = "${var.name_prefix}-allow-iap-ssh"
  network   = google_compute_network.vpc.id
  direction = "INGRESS"
  priority  = 1000

  source_ranges = ["35.235.240.0/20"]
  target_tags   = ["${var.name_prefix}-ssh", "${var.name_prefix}-vm"]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

# Optional direct public ingress (disabled by default; SSH uses gcloud IAP via allow_iap_ssh).
resource "google_compute_firewall" "allow_external_ssh" {
  count = var.enable_ingress_firewalls && var.enable_public_ingress && var.enable_external_ip && length(var.allowed_ssh_cidrs) > 0 ? 1 : 0

  project   = var.project_id
  name      = "${var.name_prefix}-allow-ingress"
  network   = google_compute_network.vpc.id
  direction = "INGRESS"
  priority  = 1000

  source_ranges = var.allowed_ssh_cidrs
  target_tags   = ["${var.name_prefix}-ssh", "${var.name_prefix}-vm"]

  allow {
    protocol = "tcp"
    ports    = ["22", "3389"]
  }

  allow {
    protocol = "udp"
    ports    = ["3389"]
  }

  allow {
    protocol = "icmp"
  }
}

# Explicitly deny all other ingress traffic.
resource "google_compute_firewall" "deny_other_ingress" {
  count = var.enable_ingress_firewalls ? 1 : 0

  project   = var.project_id
  name      = "${var.name_prefix}-deny-other-ingress"
  network   = google_compute_network.vpc.id
  direction = "INGRESS"
  priority  = 65534

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["${var.name_prefix}-ssh", "${var.name_prefix}-vm"]

  deny {
    protocol = "all"
  }
}

# Explicitly allow full outbound internet egress via Cloud NAT / Controller NIC.
resource "google_compute_firewall" "allow_egress" {
  project   = var.project_id
  name      = "${var.name_prefix}-allow-egress"
  network   = google_compute_network.vpc.id
  direction = "EGRESS"
  priority  = 1000

  destination_ranges = ["0.0.0.0/0"]
  target_tags        = ["${var.name_prefix}-ssh", "${var.name_prefix}-vm"]

  allow {
    protocol = "all"
  }
}
