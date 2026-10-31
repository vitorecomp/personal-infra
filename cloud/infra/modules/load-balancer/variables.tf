variable "region" {
  description = "The GCP region for regional resources (Cloud Run, Cloud SQL, Artifact Registry, Serverless NEG)"
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

variable "blog_runtime_sa_name" {
  description = "The account ID for the dedicated least-privilege Cloud Run runtime service account for personal-blog"
  type        = string
  default     = "personal-blog-run"
}

variable "blog_ar_repo_name" {
  description = "The Artifact Registry Docker repository name for personal-blog"
  type        = string
  default     = "personal-blog"
}

variable "blog_image" {
  description = "Container image URI for the personal-blog Cloud Run service"
  type        = string
  default     = "us-central1-docker.pkg.dev/compute-bench/personal-blog/personal-blog:latest"
}

variable "blog_content_bucket_name" {
  description = "Optional GCS bucket name for persisting Ghost uploaded media/images across Cloud Run restarts"
  type        = string
  default     = ""
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

variable "taiga_domain" {
  description = "The domain names routed to the Taiga Cloud Run service via host-based routing"
  type        = list(string)
  default     = []
}

variable "taiga_service_name" {
  description = "The name of the Cloud Run service for Taiga"
  type        = string
  default     = "taiga"
}

variable "taiga_runtime_sa_name" {
  description = "The account ID for the dedicated least-privilege Cloud Run runtime service account for Taiga"
  type        = string
  default     = "taiga-run"
}

variable "taiga_ar_repo_name" {
  description = "The Artifact Registry Docker repository name for Taiga"
  type        = string
  default     = "taiga"
}

variable "taiga_image" {
  description = "Initial container image URI for the Taiga Cloud Run service (subsequent updates managed by build-taiga.yml)"
  type        = string
  default     = "us-docker.pkg.dev/cloudrun/container/hello"
}

variable "taiga_content_bucket_name" {
  description = "Optional GCS bucket name for persisting Taiga uploaded media/attachments across Cloud Run restarts"
  type        = string
  default     = ""
}

variable "taiga_db_instance_name" {
  description = "The Cloud SQL PostgreSQL 15 instance name for Taiga"
  type        = string
  default     = "taiga-postgres"
}

variable "taiga_db_tier" {
  description = "The Cloud SQL machine tier for Taiga"
  type        = string
  default     = "db-f1-micro"
}

variable "taiga_db_name" {
  description = "The PostgreSQL database name for Taiga on Cloud SQL"
  type        = string
  default     = "taiga"
}

variable "taiga_db_user" {
  description = "The PostgreSQL database username for Taiga on Cloud SQL"
  type        = string
  default     = "taiga"
}

variable "taiga_db_password" {
  description = "Optional PostgreSQL password for the Taiga Cloud SQL user (auto-generated if empty)"
  type        = string
  default     = ""
  sensitive   = true
}

variable "taiga_secret_key" {
  description = "Optional Django cryptographic secret key for Taiga (auto-generated if empty)"
  type        = string
  default     = ""
  sensitive   = true
}

variable "taiga_db_deletion_protection" {
  description = "Whether to enable deletion protection on the Taiga Cloud SQL instance"
  type        = bool
  default     = true
}

