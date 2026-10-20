terraform {
  required_version = ">= 1.0"

  backend "gcs" {
    bucket = "compute-bench_cloudbuild"
    prefix = "terraform/state/personal-infra-prod"
  }

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

module "load_balancer" {
  source                      = "../../modules/load-balancer"
  region                      = var.region
  bucket_name                 = var.bucket_name
  domain                      = var.domain
  portfolio_bucket_name       = var.portfolio_bucket_name
  portfolio_domain            = var.portfolio_domain
  blog_domain                 = var.blog_domain
  blog_service_name           = var.blog_service_name
  blog_ar_repo_name           = var.blog_ar_repo_name
  blog_image                  = var.blog_image
  blog_content_bucket_name    = var.blog_content_bucket_name
  blog_db_instance_name       = var.blog_db_instance_name
  blog_db_tier                = var.blog_db_tier
  blog_db_name                = var.blog_db_name
  blog_db_user                = var.blog_db_user
  blog_db_password            = var.blog_db_password
  blog_db_deletion_protection = var.blog_db_deletion_protection
}
