# 1. Instance Template & MIG (Using official Google Module)
module "mig_template" {
  source       = "terraform-google-modules/vm/google//modules/instance_template"
  version      = "~> 11.0"
  project_id   = var.project_id
  machine_type = "n1-standard-4"
  tags         = ["ai-backend"]
  subnetwork   = google_compute_subnetwork.backend_subnet.id
  service_account = {
    email  = google_service_account.backend_sa.email
    scopes = ["cloud-platform"]
  }

  # Advanced Details: GPU Configuration
  gpu = {
    type  = "nvidia-tesla-t4"
    count = 1
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
  target_size       = 2
  named_ports = [{
    name = "http"
    port = 8000
  }]
}

# 2. Internal Application Load Balancer
module "gce-ilb" {
  source       = "GoogleCloudPlatform/lb-internal/google"
  version      = "~> 6.0" # Or your current pinned version
  project      = var.project_id
  region       = var.region
  name         = "ai-backend-ilb"
  ports        = ["8000"] # The port your FastAPI app runs on
  health_check = google_compute_region_health_check.hc.id
  source_tags  = ["allow-group-traffic", "cloud-run-proxy"]
  target_tags  = ["ai-fastapi-backend"]
  network      = google_compute_network.vpc.name
  subnetwork   = google_compute_subnetwork.subnet.name
  backends = [
    {
      group       = google_compute_region_instance_group_manager.mig.instance_group
      description = "MIG Backend Service"
    }
  ]
}

# 3. Cloud Run Auth Proxy (Direct VPC Egress)
resource "google_cloud_run_v2_service" "proxy" {
  name     = "jira-auth-proxy"
  location = var.region
  ingress  = "INGRESS_TRAFFIC_ALL"

  template {
    service_account = google_service_account.proxy_sa.email

    vpc_access {
      network_interfaces {
        network    = google_compute_network.vpc.name
        subnetwork = google_compute_subnetwork.backend_subnet.name
      }
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
  depends_on = [google_secret_manager_secret_version.jira_secret_version]
}

# Allow public unauthenticated access to the Cloud Run proxy to receive Jira Webhooks
resource "google_cloud_run_service_iam_member" "public_invoker" {
  location = google_cloud_run_v2_service.proxy.location
  service  = google_cloud_run_v2_service.proxy.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}