data "google_project" "current" {}

locals {
  enable_portfolio    = var.portfolio_bucket_name != ""
  enable_blog         = length(var.blog_domain) > 0
  enable_blog_storage = local.enable_blog && var.blog_content_bucket_name != ""
  all_domains = distinct(concat(
    var.domain,
    local.enable_portfolio ? var.portfolio_domain : [],
    local.enable_blog ? var.blog_domain : []
  ))
}

# Create the GCS Bucket for nobuffer-site static website hosting
resource "google_storage_bucket" "website_bucket" {
  name          = var.bucket_name
  location      = "US"
  force_destroy = true

  uniform_bucket_level_access = true
  public_access_prevention    = "inherited"

  website {
    main_page_suffix = "index.html"
    not_found_page   = "404.html"
  }
}

# Make the nobuffer-site bucket public for static website hosting
resource "google_storage_bucket_iam_member" "public_read" {
  bucket = google_storage_bucket.website_bucket.name
  role   = "roles/storage.objectViewer"
  member = "allUsers"
}

# Create the GCS Bucket for personal-portifolio static website hosting
resource "google_storage_bucket" "portfolio_bucket" {
  count         = local.enable_portfolio ? 1 : 0
  name          = var.portfolio_bucket_name
  location      = "US"
  force_destroy = true

  uniform_bucket_level_access = true
  public_access_prevention    = "inherited"

  website {
    main_page_suffix = "index.html"
    not_found_page   = "404.html"
  }
}

# Make the personal-portifolio bucket public for static website hosting
resource "google_storage_bucket_iam_member" "portfolio_public_read" {
  count  = local.enable_portfolio ? 1 : 0
  bucket = google_storage_bucket.portfolio_bucket[0].name
  role   = "roles/storage.objectViewer"
  member = "allUsers"
}

# Create Artifact Registry repository for personal-blog container images
resource "google_artifact_registry_repository" "blog_repo" {
  count         = local.enable_blog ? 1 : 0
  location      = var.region
  repository_id = var.blog_ar_repo_name
  description   = "Docker repository for personal-blog (Ghost 5 + vitorx86-garage)"
  format        = "DOCKER"
}

# Optional private GCS Bucket for persisting Ghost SQLite database and media on Cloud Run
resource "google_storage_bucket" "blog_content_bucket" {
  count         = local.enable_blog_storage ? 1 : 0
  name          = var.blog_content_bucket_name
  location      = var.region
  force_destroy = false

  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
}

# Cloud Run v2 Service for personal-blog (Ghost 5)
resource "google_cloud_run_v2_service" "blog" {
  count    = local.enable_blog ? 1 : 0
  name     = var.blog_service_name
  location = var.region
  ingress  = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"

  template {
    execution_environment = "EXECUTION_ENVIRONMENT_GEN2"

    scaling {
      min_instance_count = 0
      max_instance_count = 1
    }

    dynamic "volumes" {
      for_each = local.enable_blog_storage ? [1] : []
      content {
        name = "blog-storage"
        gcs {
          bucket    = google_storage_bucket.blog_content_bucket[0].name
          read_only = false
        }
      }
    }

    containers {
      image = var.blog_image

      ports {
        container_port = 2368
      }

      env {
        name  = "NODE_ENV"
        value = "production"
      }

      env {
        name  = "url"
        value = "https://${var.blog_domain[0]}"
      }

      env {
        name  = "database__client"
        value = "sqlite3"
      }

      env {
        name  = "database__connection__filename"
        value = "/var/lib/ghost/content/data/ghost.db"
      }

      dynamic "env" {
        for_each = local.enable_blog_storage ? [1] : []
        content {
          name  = "GHOST_STORAGE_SYNC_DIR"
          value = "/mnt/blog-storage"
        }
      }

      dynamic "volume_mounts" {
        for_each = local.enable_blog_storage ? [1] : []
        content {
          name       = "blog-storage"
          mount_path = "/mnt/blog-storage"
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [
      template[0].containers[0].image,
      client,
      client_version,
    ]
  }
}

# Allow public invocation of the Cloud Run blog service via the Load Balancer
resource "google_cloud_run_v2_service_iam_member" "blog_public_invoker" {
  count    = local.enable_blog ? 1 : 0
  location = google_cloud_run_v2_service.blog[0].location
  name     = google_cloud_run_v2_service.blog[0].name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

# Serverless Network Endpoint Group (NEG) for the personal-blog Cloud Run service
resource "google_compute_region_network_endpoint_group" "blog_neg" {
  count                 = local.enable_blog ? 1 : 0
  name                  = "personal-blog-neg"
  network_endpoint_type = "SERVERLESS"
  region                = var.region

  cloud_run {
    service = google_cloud_run_v2_service.blog[0].name
  }
}

# Backend Service routing Load Balancer traffic to the personal-blog Serverless NEG
resource "google_compute_backend_service" "blog_backend" {
  count                 = local.enable_blog ? 1 : 0
  name                  = "personal-blog-backend"
  protocol              = "HTTP"
  port_name             = "http"
  timeout_sec           = 30
  load_balancing_scheme = "EXTERNAL_MANAGED"

  backend {
    group = google_compute_region_network_endpoint_group.blog_neg[0].id
  }
}

# Reserve a shared static external IP address
resource "google_compute_global_address" "nobuffer_site_ip" {
  name = "nobuffer-site-ip"
}

# Create a Backend Bucket with CDN enabled for nobuffer-site
resource "google_compute_backend_bucket" "nobuffer_site_backend" {
  name        = "nobuffer-site-backend"
  bucket_name = google_storage_bucket.website_bucket.name
  enable_cdn  = true

  cdn_policy {
    cache_mode        = "CACHE_ALL_STATIC"
    client_ttl        = 3600
    default_ttl       = 3600
    max_ttl           = 86400
    negative_caching  = true
    serve_while_stale = 86400
  }
}

# Create a Backend Bucket with CDN enabled for personal-portifolio
resource "google_compute_backend_bucket" "portfolio_backend" {
  count       = local.enable_portfolio ? 1 : 0
  name        = "personal-portifolio-backend"
  bucket_name = google_storage_bucket.portfolio_bucket[0].name
  enable_cdn  = true

  cdn_policy {
    cache_mode        = "CACHE_ALL_STATIC"
    client_ttl        = 3600
    default_ttl       = 3600
    max_ttl           = 86400
    negative_caching  = true
    serve_while_stale = 86400
  }
}

# Create a URL Map with host-based routing across static site buckets and Cloud Run backends
resource "google_compute_url_map" "nobuffer_site_url_map" {
  name            = "nobuffer-site-url-map"
  default_service = google_compute_backend_bucket.nobuffer_site_backend.id

  dynamic "host_rule" {
    for_each = local.enable_portfolio && length(var.portfolio_domain) > 0 ? [1] : []
    content {
      hosts        = var.portfolio_domain
      path_matcher = "portfolio-matcher"
    }
  }

  dynamic "path_matcher" {
    for_each = local.enable_portfolio && length(var.portfolio_domain) > 0 ? [1] : []
    content {
      name            = "portfolio-matcher"
      default_service = google_compute_backend_bucket.portfolio_backend[0].id
    }
  }

  dynamic "host_rule" {
    for_each = local.enable_blog ? [1] : []
    content {
      hosts        = var.blog_domain
      path_matcher = "blog-matcher"
    }
  }

  dynamic "path_matcher" {
    for_each = local.enable_blog ? [1] : []
    content {
      name            = "blog-matcher"
      default_service = google_compute_backend_service.blog_backend[0].id
    }
  }
}

# Create a Managed SSL Certificate covering all configured domains
resource "google_compute_managed_ssl_certificate" "nobuffer_site_cert" {
  name = "nobuffer-site-cert-v2"
  managed {
    domains = local.all_domains
  }
  lifecycle {
    create_before_destroy = true
  }
}

# Create a Target HTTPS Proxy
resource "google_compute_target_https_proxy" "nobuffer_site_https_proxy" {
  name             = "nobuffer-site-https-proxy"
  url_map          = google_compute_url_map.nobuffer_site_url_map.id
  ssl_certificates = [google_compute_managed_ssl_certificate.nobuffer_site_cert.id]
}

# Create a Global Forwarding Rule for HTTPS
resource "google_compute_global_forwarding_rule" "nobuffer_site_forwarding_rule_https" {
  name                  = "nobuffer-site-forwarding-rule-https-v2"
  target                = google_compute_target_https_proxy.nobuffer_site_https_proxy.id
  port_range            = "443"
  ip_address            = google_compute_global_address.nobuffer_site_ip.address
  load_balancing_scheme = "EXTERNAL_MANAGED"
}

# Create a URL Map for HTTP to HTTPS redirect
resource "google_compute_url_map" "nobuffer_site_redirect_map" {
  name = "nobuffer-site-redirect-map"
  default_url_redirect {
    https_redirect = true
    strip_query    = false
  }
}

# Create a Target HTTP Proxy for redirect
resource "google_compute_target_http_proxy" "nobuffer_site_http_proxy" {
  name    = "nobuffer-site-http-proxy"
  url_map = google_compute_url_map.nobuffer_site_redirect_map.id
}

# Create a Global Forwarding Rule for HTTP (redirect)
resource "google_compute_global_forwarding_rule" "nobuffer_site_forwarding_rule" {
  name                  = "nobuffer-site-forwarding-rule-v2"
  target                = google_compute_target_http_proxy.nobuffer_site_http_proxy.id
  port_range            = "80"
  ip_address            = google_compute_global_address.nobuffer_site_ip.address
  load_balancing_scheme = "EXTERNAL_MANAGED"
}
