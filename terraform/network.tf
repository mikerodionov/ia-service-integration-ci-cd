resource "google_compute_network" "vpc" {
  name                    = "ai-vpc"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "backend_subnet" {
  name          = "ai-backend-snet"
  ip_cidr_range = "10.0.1.0/24"
  region        = var.region
  network       = google_compute_network.vpc.id
}

resource "google_compute_subnetwork" "serverless_connector_subnet" {
  name          = "ai-serverless-connector-subnet"
  ip_cidr_range = "10.0.3.0/28"
  region        = var.region
  network       = google_compute_network.vpc.id
}

# Required for Internal Application Load Balancer
resource "google_compute_subnetwork" "proxy_subnet" {
  name          = "ai-proxy-only-subnet"
  ip_cidr_range = "10.0.2.0/24"
  region        = var.region
  network       = google_compute_network.vpc.id
  purpose       = "REGIONAL_MANAGED_PROXY"
  role          = "ACTIVE"
}

# Cloud Router & NAT (Backend VMs need internet access to run pip install)
resource "google_compute_router" "router" {
  name    = "ai-router"
  region  = var.region
  network = google_compute_network.vpc.id
}

resource "google_compute_router_nat" "nat" {
  name                               = "ai-nat"
  router                             = google_compute_router.router.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}

resource "google_vpc_access_connector" "proxy_connector" {
  name   = "jira-auth-proxy"
  region = var.region

  subnet {
    name = google_compute_subnetwork.serverless_connector_subnet.name
  }

  machine_type  = "e2-micro"
  min_instances = 2
  max_instances = 3
}

# Allow Health Checks
resource "google_compute_firewall" "allow_health_checks" {
  name    = "allow-health-checks"
  network = google_compute_network.vpc.id
  allow {
    protocol = "tcp"
    ports    = ["8000"]
  }
  source_ranges = ["130.211.0.0/22", "35.191.0.0/16"]
  target_tags   = ["ai-backend"]
}

# Allow Internal Traffic from Proxy Subnet to Backend
resource "google_compute_firewall" "allow_proxy_to_backend" {
  name    = "allow-proxy-to-backend"
  network = google_compute_network.vpc.id
  allow {
    protocol = "tcp"
    ports    = ["8000"]
  }
  source_ranges = [google_compute_subnetwork.proxy_subnet.ip_cidr_range]
  target_tags   = ["ai-backend"]
}