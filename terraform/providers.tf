terraform {
  required_version = ">= 1.3.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }

  backend "gcs" {
    bucket = "YOUR_TERRAFORM_STATE_BUCKET_NAME" # Update this
    prefix = "terraform/state/ia-service"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}