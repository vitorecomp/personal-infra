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

output "blog_sql_connection_name" {
  description = "Cloud SQL MySQL 8.0 instance connection name for personal-blog"
  value       = local.enable_blog ? google_sql_database_instance.blog_db[0].connection_name : null
}

output "taiga_service_uri" {
  description = "Cloud Run service URI for Taiga"
  value       = local.enable_taiga ? google_cloud_run_v2_service.taiga[0].uri : null
}

output "taiga_sql_connection_name" {
  description = "Cloud SQL PostgreSQL 15 instance connection name for Taiga"
  value       = local.enable_taiga ? google_sql_database_instance.taiga_db[0].connection_name : null
}

