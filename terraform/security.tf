resource "google_service_account" "proxy_sa" {
  account_id   = "cloud-run-proxy-sa"
  display_name = "Cloud Run Auth Proxy Service Account"
}

resource "google_service_account" "backend_sa" {
  account_id   = "compute-backend-sa"
  display_name = "Compute Engine AI Backend Service Account"
}

# Secret Manager for Jira Webhook
resource "google_secret_manager_secret" "jira_secret" {
  secret_id = "jira-webhook-secret"
  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "jira_secret_version" {
  secret      = google_secret_manager_secret.jira_secret.id
  secret_data = var.jira_webhook_secret
}

# Allow Cloud Run to access the secret
resource "google_secret_manager_secret_iam_member" "proxy_secret_access" {
  secret_id = google_secret_manager_secret.jira_secret.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.proxy_sa.email}"
}