# Single OCI Ampere A1 VM that hosts one docker compose stack behind Caddy.
#
# Always Free friendly by default (VM.Standard.A1.Flex 1 OCPU / 6 GB, 50 GB boot
# volume; the free A1 pool is 2 OCPU / 12 GB per tenancy, home region only).
# Network: dedicated VCN + public subnet + security list. The instance gets a
# RESERVED public IP so DNS (managed by hand) survives instance re-creation.
#
# Data-safety guards: prevent_destroy on the instance and reserved IP, and
# ignore_changes on the image and metadata (both force replacement on OCI).
# NOTE: Canonical's OCI Ubuntu images also ship host iptables rules that REJECT
# inbound traffic except SSH; cloud/scripts/bootstrap_vm.py opens 80/443 there.

locals {
  availability_domain = data.oci_identity_availability_domains.this.availability_domains[var.availability_domain_index].name
  image_id            = var.image_ocid != "" ? var.image_ocid : data.oci_core_images.ubuntu.images[0].id
  web_rules           = setproduct(var.web_source_cidrs, [80, 443])
}

data "oci_identity_availability_domains" "this" {
  compartment_id = var.tenancy_ocid
}

data "oci_core_images" "ubuntu" {
  compartment_id           = var.compartment_ocid
  operating_system         = "Canonical Ubuntu"
  operating_system_version = var.ubuntu_version
  shape                    = var.shape
  state                    = "AVAILABLE"
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"

  # Exclude "Minimal" images; keep the full aarch64 Canonical build.
  filter {
    name   = "display_name"
    values = ["^Canonical-Ubuntu-${replace(var.ubuntu_version, ".", "\\.")}-aarch64-.*$"]
    regex  = true
  }
}

resource "oci_core_vcn" "this" {
  compartment_id = var.compartment_ocid
  display_name   = "${var.name}-vcn"
  cidr_blocks    = [var.vcn_cidr]
  dns_label      = substr(replace(var.name, "-", ""), 0, 15)
  freeform_tags  = var.freeform_tags
}

resource "oci_core_internet_gateway" "this" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.name}-igw"
  enabled        = true
  freeform_tags  = var.freeform_tags
}

resource "oci_core_route_table" "this" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.name}-rt"
  freeform_tags  = var.freeform_tags

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.this.id
  }
}

resource "oci_core_security_list" "this" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.name}-sl"
  freeform_tags  = var.freeform_tags

  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
    stateless   = false
  }

  dynamic "ingress_security_rules" {
    for_each = toset(var.ssh_source_cidrs)
    content {
      description = "SSH (admin + GitHub Actions deploys)"
      protocol    = "6"
      source      = ingress_security_rules.value
      stateless   = false
      tcp_options {
        min = 22
        max = 22
      }
    }
  }

  dynamic "ingress_security_rules" {
    for_each = { for pair in local.web_rules : "${pair[0]}-${pair[1]}" => pair }
    content {
      description = "Caddy tcp/${ingress_security_rules.value[1]}"
      protocol    = "6"
      source      = ingress_security_rules.value[0]
      stateless   = false
      tcp_options {
        min = ingress_security_rules.value[1]
        max = ingress_security_rules.value[1]
      }
    }
  }

  # ICMP type 3 code 4 (fragmentation needed) keeps path MTU discovery working.
  ingress_security_rules {
    description = "ICMP path MTU discovery"
    protocol    = "1"
    source      = "0.0.0.0/0"
    stateless   = false
    icmp_options {
      type = 3
      code = 4
    }
  }
}

resource "oci_core_subnet" "this" {
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.this.id
  display_name               = "${var.name}-subnet"
  cidr_block                 = var.subnet_cidr
  dns_label                  = "public"
  route_table_id             = oci_core_route_table.this.id
  security_list_ids          = [oci_core_security_list.this.id]
  prohibit_public_ip_on_vnic = false
  freeform_tags              = var.freeform_tags
}

resource "oci_core_instance" "this" {
  compartment_id      = var.compartment_ocid
  availability_domain = local.availability_domain
  display_name        = var.name
  shape               = var.shape
  freeform_tags       = var.freeform_tags

  shape_config {
    ocpus         = var.ocpus
    memory_in_gbs = var.memory_in_gbs
  }

  source_details {
    source_type             = "image"
    source_id               = local.image_id
    boot_volume_size_in_gbs = var.boot_volume_size_in_gbs
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.this.id
    display_name     = "${var.name}-vnic"
    hostname_label   = substr(replace(var.name, "-", ""), 0, 15)
    assign_public_ip = false # the reserved public IP below is attached instead
  }

  metadata = {
    ssh_authorized_keys = trimspace(var.admin_ssh_public_key)
  }

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [source_details[0].source_id, metadata]
  }
}

data "oci_core_vnic_attachments" "this" {
  compartment_id = var.compartment_ocid
  instance_id    = oci_core_instance.this.id
}

data "oci_core_private_ips" "primary" {
  vnic_id = data.oci_core_vnic_attachments.this.vnic_attachments[0].vnic_id
}

resource "oci_core_public_ip" "this" {
  compartment_id = var.compartment_ocid
  display_name   = "${var.name}-ip"
  lifetime       = "RESERVED"
  private_ip_id  = data.oci_core_private_ips.primary.private_ips[0].id
  freeform_tags  = var.freeform_tags

  lifecycle {
    prevent_destroy = true
  }
}
