# 1. Instance Template & MIG (official Google Module)
module "mig_template" {
  source       = "terraform-google-modules/vm/google//modules/instance_template"
  version      = "~> 11.0"
  project_id   = var.project_id
  machine_type = "e2-micro"
  tags         = ["ai-backend"]
  subnetwork   = google_compute_subnetwork.backend_subnet.id
  service_account = {
    email  = google_service_account.backend_sa.email
    scopes = ["cloud-platform"]
  }

  metadata = {
    startup-script = file("${path.module}/../app/backend/startup.sh")
  }
}

module "mig" {
  source            = "terraform-google-modules/vm/google//modules/mig"
  version           = "~> 11.0"
  project_id        = var.project_id
  hostname          = "ai-backend"
  region            = var.region
  instance_template = module.mig_template.self_link
  autoscaling_enabled = "true"
  min_replicas        = 1
  max_replicas        = 3
  cooldown_period     = 60
  autoscaling_cpu = [{
    target            = 0.8
    predictive_method = "NONE"
  }]
  named_ports = [{
    name = "http"
    port = 8000
  }]
}

# 2. Internal Application Load Balancer
module "gce-ilb" {
  source  = "GoogleCloudPlatform/lb-internal/google"
  version = "~> 6.0"
  project = var.project_id
  region  = var.region
  name    = "ai-backend-ilb"
  ports   = ["8000"]
  # This module expects a health_check object and creates the health check itself.
  health_check = {
    type                = "http"
    check_interval_sec  = 5
    healthy_threshold   = 2
    timeout_sec         = 5
    unhealthy_threshold = 2
    port                = 8000
    request_path        = "/health"
    enable_log          = false
  }
  source_tags                  = []
  target_tags                  = ["ai-backend"]
  create_backend_firewall      = false
  create_health_check_firewall = false
  network                      = google_compute_network.vpc.name
  subnetwork                   = google_compute_subnetwork.backend_subnet.name
  backends = [
    {
      group       = module.mig.instance_group
      description = "MIG Backend Service"
    }
  ]

  depends_on = [
    google_compute_network.vpc,
    google_compute_subnetwork.backend_subnet,
  ]
}

# 3. Cloud Run Auth Proxy
resource "google_cloud_run_v2_service" "proxy" {
  name     = "jira-auth-proxy"
  location = var.region
  ingress  = "INGRESS_TRAFFIC_ALL"

  template {
    service_account = google_service_account.proxy_sa.email

    vpc_access {
      connector = google_vpc_access_connector.proxy_connector.id
      egress = "PRIVATE_RANGES_ONLY"
    }

    containers {
      image = var.proxy_image

      env {
        name = "EXPECTED_SECRET"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.jira_secret.secret_id
            version = "latest"
          }
        }
      }
      env {
        name  = "BACKEND_URL"
        value = "http://${module.gce-ilb.ip_address}:8000/process-ticket"
      }
    }
  }
  depends_on = [
    google_secret_manager_secret_version.jira_secret_version,
    google_secret_manager_secret_iam_member.proxy_secret_access,
    google_vpc_access_connector.proxy_connector,
  ]
}

# Allow public unauthenticated access to the Cloud Run proxy to receive Jira Webhooks
resource "google_cloud_run_service_iam_member" "public_invoker" {
  location = google_cloud_run_v2_service.proxy.location
  service  = google_cloud_run_v2_service.proxy.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}