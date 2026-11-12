# Single Compute Engine VM that hosts one docker compose stack behind Caddy.
#
# Free-tier friendly by default (e2-micro + 30 GB pd-standard in us-central1).
# The VM gets its own VPC so the project's other firewall rules never apply to it,
# a reserved static IPv4 (DNS records are managed by hand), and a dedicated
# service account instead of the Editor-scoped default compute account.
#
# Data-safety guards: deletion_protection on the instance, prevent_destroy on the
# instance and address, and ignore_changes on the boot image so a new Ubuntu image
# release never plans a replacement.

locals {
  network_tag = "${var.name}-vm"
}

resource "google_compute_network" "this" {
  name                    = "${var.name}-vpc"
  auto_create_subnetworks = false
  description             = "Dedicated network for the ${var.name} compose VM"
}

resource "google_compute_subnetwork" "this" {
  name          = "${var.name}-subnet"
  region        = var.region
  network       = google_compute_network.this.id
  ip_cidr_range = var.subnet_cidr
}

resource "google_compute_firewall" "ssh" {
  name          = "${var.name}-allow-ssh"
  network       = google_compute_network.this.name
  description   = "SSH for admin access and GitHub Actions deploys (key-only, hardened sshd)"
  direction     = "INGRESS"
  source_ranges = var.ssh_source_cidrs
  target_tags   = [local.network_tag]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

resource "google_compute_firewall" "web" {
  name          = "${var.name}-allow-web"
  network       = google_compute_network.this.name
  description   = "HTTP/HTTPS to Caddy (restricted to the operator IP until DNS cutover)"
  direction     = "INGRESS"
  source_ranges = var.web_source_cidrs
  target_tags   = [local.network_tag]

  allow {
    protocol = "tcp"
    ports    = ["80", "443"]
  }
}

resource "google_compute_firewall" "icmp" {
  name          = "${var.name}-allow-icmp"
  network       = google_compute_network.this.name
  description   = "ICMP for path MTU discovery and basic reachability checks"
  direction     = "INGRESS"
  source_ranges = ["0.0.0.0/0"]
  target_tags   = [local.network_tag]

  allow {
    protocol = "icmp"
  }
}

resource "google_compute_address" "this" {
  name         = "${var.name}-ip"
  region       = var.region
  address_type = "EXTERNAL"
  network_tier = "PREMIUM"
  description  = "Static public IPv4 for ${var.name} (referenced by manually managed DNS)"

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_service_account" "vm" {
  account_id   = "${var.name}-vm"
  display_name = "${var.name} VM runtime identity"
  description  = "Minimal identity for the ${var.name} compose VM (logs/metrics only)"
}

resource "google_project_iam_member" "vm" {
  for_each = toset(["roles/logging.logWriter", "roles/monitoring.metricWriter"])

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.vm.email}"
}

resource "google_compute_instance" "this" {
  name                      = var.name
  zone                      = var.zone
  machine_type              = var.machine_type
  tags                      = [local.network_tag]
  labels                    = var.labels
  deletion_protection       = var.deletion_protection
  allow_stopping_for_update = true

  boot_disk {
    initialize_params {
      image = var.image
      size  = var.boot_disk_size_gb
      type  = var.boot_disk_type
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.this.id

    access_config {
      nat_ip       = google_compute_address.this.address
      network_tier = "PREMIUM"
    }
  }

  metadata = {
    enable-oslogin = "FALSE"
    ssh-keys       = "${var.admin_username}:${trimspace(var.admin_ssh_public_key)}"
  }

  service_account {
    email  = google_service_account.vm.email
    scopes = ["cloud-platform"]
  }

  scheduling {
    automatic_restart   = true
    on_host_maintenance = "MIGRATE"
    preemptible         = false
    provisioning_model  = "STANDARD"
  }

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [boot_disk[0].initialize_params[0].image]
  }

  depends_on = [google_project_iam_member.vm]
}

resource "google_compute_resource_policy" "snapshots" {
  count = var.enable_snapshots ? 1 : 0

  name   = "${var.name}-daily-snapshots"
  region = var.region

  snapshot_schedule_policy {
    schedule {
      daily_schedule {
        days_in_cycle = 1
        start_time    = "04:00"
      }
    }

    retention_policy {
      max_retention_days    = var.snapshot_retention_days
      on_source_disk_delete = "KEEP_AUTO_SNAPSHOTS"
    }
  }
}

resource "google_compute_disk_resource_policy_attachment" "snapshots" {
  count = var.enable_snapshots ? 1 : 0

  name = google_compute_resource_policy.snapshots[0].name
  disk = google_compute_instance.this.name # boot disk inherits the instance name
  zone = var.zone
}
