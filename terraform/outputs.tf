output "proxy_url" {
  description = "The public URL for the Cloud Run proxy (Configure Jira Webhook here)"
  value       = google_cloud_run_v2_service.proxy.uri
}

output "internal_lb_ip" {
  description = "The IP address of the internal load balancer"
  value       = module.gce-ilb.ip_address
}