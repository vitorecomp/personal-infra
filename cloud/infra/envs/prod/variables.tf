variable "project_id" {
  description = "The GCP Project ID"
  type        = string
  default     = "legacy-gcp-project"
}

variable "region" {
  description = "The region for resources"
  type        = string
  default     = "us-central1"
}

variable "bucket_name" {
  description = "The name of the GCS bucket for nobuffer-site"
  type        = string
  default     = "main-website-legacy-gcp-project"
}

variable "domain" {
  description = "The domain names for nobuffer-site"
  type        = list(string)
  default     = ["www.example.com", "example.com"]
}

variable "portfolio_bucket_name" {
  description = "The name of the GCS bucket for personal-portifolio"
  type        = string
  default     = "portfolio-website-legacy-gcp-project"
}

variable "portfolio_domain" {
  description = "The domain names for personal-portifolio (routed via host rules on the shared load balancer)"
  type        = list(string)
  default     = ["cases.example.com", "me.example.com"]
}

variable "blog_domain" {
  description = "The domain names for personal-blog (routed to Cloud Run via Serverless NEG on the shared load balancer)"
  type        = list(string)
  default     = ["blog.example.com"]
}

variable "blog_service_name" {
  description = "The Cloud Run service name for personal-blog"
  type        = string
  default     = "personal-blog"
}

variable "blog_ar_repo_name" {
  description = "The Artifact Registry Docker repository name for personal-blog"
  type        = string
  default     = "personal-blog"
}

variable "blog_image" {
  description = "Container image URI for the personal-blog Cloud Run service"
  type        = string
  default     = "docker.io/library/ghost:5-alpine"
}

variable "blog_content_bucket_name" {
  description = "Optional GCS bucket name for persisting Ghost uploaded media/images across Cloud Run restarts"
  type        = string
  default     = "blog-content-legacy-gcp-project"
}

variable "blog_db_instance_name" {
  description = "The Cloud SQL MySQL 8.0 instance name for personal-blog"
  type        = string
  default     = "personal-blog-mysql"
}

variable "blog_db_tier" {
  description = "The Cloud SQL machine tier for personal-blog"
  type        = string
  default     = "db-f1-micro"
}

variable "blog_db_name" {
  description = "The MySQL database name for Ghost on Cloud SQL"
  type        = string
  default     = "ghost"
}

variable "blog_db_user" {
  description = "The MySQL database username for Ghost on Cloud SQL"
  type        = string
  default     = "ghost"
}

variable "blog_db_password" {
  description = "Optional MySQL password for the Ghost Cloud SQL user (auto-generated if empty)"
  type        = string
  default     = ""
  sensitive   = true
}

variable "blog_db_deletion_protection" {
  description = "Whether to enable deletion protection on the Cloud SQL instance"
  type        = bool
  default     = true
}
