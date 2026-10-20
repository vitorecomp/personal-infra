output "load_balancer_ip" {
  description = "Shared Global External Load Balancer IP address"
  value       = google_compute_global_address.nobuffer_site_ip.address
}

output "website_bucket_name" {
  description = "GCS bucket name for nobuffer-site"
  value       = google_storage_bucket.website_bucket.name
}

output "portfolio_bucket_name" {
  description = "GCS bucket name for personal-portifolio"
  value       = local.enable_portfolio ? google_storage_bucket.portfolio_bucket[0].name : null
}

output "blog_service_uri" {
  description = "Cloud Run service URI for personal-blog"
  value       = local.enable_blog ? google_cloud_run_v2_service.blog[0].uri : null
}
