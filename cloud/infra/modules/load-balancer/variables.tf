variable "region" {
  description = "The GCP region for regional resources (Cloud Run, Artifact Registry, Serverless NEG)"
  type        = string
  default     = "us-central1"
}

variable "bucket_name" {
  description = "The name of the GCS bucket for nobuffer-site"
  type        = string
}

variable "domain" {
  description = "The domain names for nobuffer-site (default backend)"
  type        = list(string)
}

variable "portfolio_bucket_name" {
  description = "The name of the GCS bucket for personal-portifolio (optional)"
  type        = string
  default     = ""
}

variable "portfolio_domain" {
  description = "The domain names routed to personal-portifolio via host-based routing"
  type        = list(string)
  default     = []
}

variable "blog_domain" {
  description = "The domain names routed to the personal-blog Cloud Run service via host-based routing"
  type        = list(string)
  default     = []
}

variable "blog_service_name" {
  description = "The name of the Cloud Run service for personal-blog"
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
  description = "Optional GCS bucket name for persisting Ghost SQLite database and media across Cloud Run restarts"
  type        = string
  default     = ""
}
