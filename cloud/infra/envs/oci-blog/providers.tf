terraform {
  required_version = ">= 1.9, < 2.0"

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 9.0"
    }
  }
}

# Authenticates with your API signing key from ~/.oci/config (profile below);
# no credentials are stored in this repository or in GitHub.
provider "oci" {
  config_file_profile = var.oci_profile
  region              = var.region
}
