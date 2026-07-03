variable "project_id" {
  description = "The GCP Project ID"
  type        = string
}

variable "region" {
  description = "The GCP Region"
  type        = string
  default     = "europe-west1"
}

variable "zone" {
  description = "The GCP Zone"
  type        = string
  default     = "europe-west1-b"
}

variable "jira_webhook_secret" {
  description = "The pre-shared secret from Jira"
  type        = string
  sensitive   = true
}

variable "proxy_image" {
  description = "The GAR URI of the Cloud Run proxy image"
  type        = string
}