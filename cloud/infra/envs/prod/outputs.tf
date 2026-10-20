output "load_balancer_ip" {
  description = "Shared Global External Load Balancer IP"
  value       = module.load_balancer.load_balancer_ip
}

output "website_bucket_name" {
  description = "GCS bucket name for nobuffer-site"
  value       = module.load_balancer.website_bucket_name
}

output "portfolio_bucket_name" {
  description = "GCS bucket name for personal-portifolio"
  value       = module.load_balancer.portfolio_bucket_name
}

output "blog_service_uri" {
  description = "Cloud Run service URI for personal-blog"
  value       = module.load_balancer.blog_service_uri
}
