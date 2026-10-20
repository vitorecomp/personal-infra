# Declarative Terraform 1.5+ import blocks to reconcile pre-existing GCP resources
# in compute-bench into the remote GCS Terraform state. Once imported into state,
# these blocks become no-ops on subsequent runs.

import {
  to = module.load_balancer.google_storage_bucket.website_bucket
  id = "main-website-compute-bench"
}

import {
  to = module.load_balancer.google_storage_bucket.portfolio_bucket[0]
  id = "portfolio-website-compute-bench"
}

import {
  to = module.load_balancer.google_storage_bucket.blog_content_bucket[0]
  id = "blog-content-compute-bench"
}

import {
  to = module.load_balancer.google_service_account.blog_runtime[0]
  id = "projects/compute-bench/serviceAccounts/personal-blog-run@compute-bench.iam.gserviceaccount.com"
}

import {
  to = module.load_balancer.google_artifact_registry_repository.blog_repo[0]
  id = "projects/compute-bench/locations/us-central1/repositories/personal-blog"
}

import {
  to = module.load_balancer.google_sql_database_instance.blog_db[0]
  id = "projects/compute-bench/instances/personal-blog-mysql"
}

import {
  to = module.load_balancer.google_sql_database.blog_database[0]
  id = "projects/compute-bench/instances/personal-blog-mysql/databases/ghost"
}

import {
  to = module.load_balancer.google_cloud_run_v2_service.blog[0]
  id = "projects/compute-bench/locations/us-central1/services/personal-blog"
}

import {
  to = module.load_balancer.google_compute_region_network_endpoint_group.blog_neg[0]
  id = "projects/compute-bench/regions/us-central1/networkEndpointGroups/personal-blog-neg"
}

import {
  to = module.load_balancer.google_compute_backend_service.blog_backend[0]
  id = "projects/compute-bench/global/backendServices/personal-blog-backend"
}

import {
  to = module.load_balancer.google_compute_global_address.nobuffer_site_ip
  id = "projects/compute-bench/global/addresses/nobuffer-site-ip"
}

import {
  to = module.load_balancer.google_compute_backend_bucket.nobuffer_site_backend
  id = "projects/compute-bench/global/backendBuckets/nobuffer-site-backend"
}

import {
  to = module.load_balancer.google_compute_backend_bucket.portfolio_backend[0]
  id = "projects/compute-bench/global/backendBuckets/personal-portifolio-backend"
}

import {
  to = module.load_balancer.google_compute_url_map.nobuffer_site_url_map
  id = "projects/compute-bench/global/urlMaps/nobuffer-site-url-map"
}

import {
  to = module.load_balancer.google_compute_managed_ssl_certificate.nobuffer_site_cert
  id = "projects/compute-bench/global/sslCertificates/nobuffer-site-cert-v2"
}

import {
  to = module.load_balancer.google_compute_managed_ssl_certificate.portfolio_cert[0]
  id = "projects/compute-bench/global/sslCertificates/personal-portifolio-cert"
}

import {
  to = module.load_balancer.google_compute_managed_ssl_certificate.blog_cert[0]
  id = "projects/compute-bench/global/sslCertificates/personal-blog-cert"
}

import {
  to = module.load_balancer.google_compute_target_https_proxy.nobuffer_site_https_proxy
  id = "projects/compute-bench/global/targetHttpsProxies/nobuffer-site-https-proxy"
}

import {
  to = module.load_balancer.google_compute_global_forwarding_rule.nobuffer_site_forwarding_rule_https
  id = "projects/compute-bench/global/forwardingRules/nobuffer-site-forwarding-rule-https-v2"
}

import {
  to = module.load_balancer.google_compute_url_map.nobuffer_site_redirect_map
  id = "projects/compute-bench/global/urlMaps/nobuffer-site-redirect-map"
}

import {
  to = module.load_balancer.google_compute_target_http_proxy.nobuffer_site_http_proxy
  id = "projects/compute-bench/global/targetHttpProxies/nobuffer-site-http-proxy"
}

import {
  to = module.load_balancer.google_compute_global_forwarding_rule.nobuffer_site_forwarding_rule
  id = "projects/compute-bench/global/forwardingRules/nobuffer-site-forwarding-rule-v2"
}
