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
  source                       = "../../modules/load-balancer"
  region                       = var.region
  bucket_name                  = var.bucket_name
  domain                       = var.domain
  portfolio_bucket_name        = var.portfolio_bucket_name
  portfolio_domain             = var.portfolio_domain
  blog_domain                  = var.blog_domain
  blog_service_name            = var.blog_service_name
  blog_runtime_sa_name         = var.blog_runtime_sa_name
  blog_ar_repo_name            = var.blog_ar_repo_name
  blog_image                   = var.blog_image
  blog_content_bucket_name     = var.blog_content_bucket_name
  blog_db_instance_name        = var.blog_db_instance_name
  blog_db_tier                 = var.blog_db_tier
  blog_db_name                 = var.blog_db_name
  blog_db_user                 = var.blog_db_user
  blog_db_password             = var.blog_db_password
  blog_db_deletion_protection  = var.blog_db_deletion_protection
  taiga_domain                 = var.taiga_domain
  taiga_service_name           = var.taiga_service_name
  taiga_runtime_sa_name        = var.taiga_runtime_sa_name
  taiga_ar_repo_name           = var.taiga_ar_repo_name
  taiga_image                  = var.taiga_image
  taiga_content_bucket_name    = var.taiga_content_bucket_name
  taiga_db_instance_name       = var.taiga_db_instance_name
  taiga_db_tier                = var.taiga_db_tier
  taiga_db_name                = var.taiga_db_name
  taiga_db_user                = var.taiga_db_user
  taiga_db_password            = var.taiga_db_password
  taiga_secret_key             = var.taiga_secret_key
  taiga_db_deletion_protection = var.taiga_db_deletion_protection
}
