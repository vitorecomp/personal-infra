terraform {
  required_version = ">= 1.9, < 2.0"

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 9.0"
    }
  }
}
