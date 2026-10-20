# Shared Cloud Load Balancer & Workloads Module

Provisions a shared Google Cloud Global External HTTPS Load Balancer with Cloud CDN, Managed SSL Certificate, and host-based routing for:

1. **`nobuffer-site`** (default GCS backend bucket `website_bucket` serving `var.domain`)
2. **`personal-portifolio`** (host-routed GCS backend bucket `portfolio_bucket` serving `var.portfolio_domain` when `var.portfolio_bucket_name` is set)
3. **`personal-blog`** (host-routed Cloud Run v2 service `blog` + Cloud SQL for MySQL 8.0 `blog_db` + Serverless NEG + Artifact Registry Docker repo serving `var.blog_domain` when `var.blog_domain` is non-empty)
