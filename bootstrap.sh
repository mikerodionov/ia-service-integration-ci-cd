#!/bin/bash

# Configuration Variables
PROJECT_ID=$(gcloud config get-value project)
REGION="europe-west1"
STATE_BUCKET="${PROJECT_ID}-tf-state-bucket"
GAR_REPO="ai-proxy-repo"
SA_NAME="github-actions-deployer"
SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

echo "===================================================="
echo " Bootstrapping GCP Environment for CI/CD Deployment"
echo " Project: $PROJECT_ID"
echo "===================================================="

# 1. Enable Required APIs
echo "[+] Enabling required GCP APIs..."
gcloud services enable \
  compute.googleapis.com \
  run.googleapis.com \
  secretmanager.googleapis.com \
  iam.googleapis.com \
  cloudresourcemanager.googleapis.com \
  artifactregistry.googleapis.com \
  cloudbuild.googleapis.com

# 2. Create GCS Bucket for Terraform State
echo "[+] Creating Terraform State Bucket ($STATE_BUCKET)..."
if ! gsutil ls -b gs://$STATE_BUCKET > /dev/null 2>&1; then
    gsutil mb -l $REGION gs://$STATE_BUCKET
    gsutil versioning set on gs://$STATE_BUCKET
else
    echo "    Bucket already exists. Skipping."
fi

# 3. Create Artifact Registry Repository (Required before GH Actions builds Docker image)
echo "[+] Creating Artifact Registry for Cloud Run images..."
if ! gcloud artifacts repositories describe $GAR_REPO --location=$REGION > /dev/null 2>&1; then
    gcloud artifacts repositories create $GAR_REPO \
        --repository-format=docker \
        --location=$REGION \
        --description="Docker repository for Cloud Run Proxy"
else
    echo "    Repository already exists. Skipping."
fi

# 4. Create Service Account for GitHub Actions
echo "[+] Creating CI/CD Service Account..."
gcloud iam service-accounts create $SA_NAME --display-name="GitHub Actions Deployer" 2>/dev/null || true

# Grant permissions (Owner used here strictly for assignment simplicity since TF creates IAM bindings)
gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:$SA_EMAIL" \
    --role="roles/owner" > /dev/null

# 5. Generate JSON Key
echo "[+] Generating Service Account Key..."
gcloud iam service-accounts keys create sa-key.json --iam-account=$SA_EMAIL > /dev/null

# 6. Inject Secrets into GitHub (Requires 'gh' CLI)
echo "[+] Pushing secrets to GitHub Repository..."
read -p "Enter your Jira Webhook Secret (e.g., my-secret-123): " JIRA_SECRET

gh secret set GCP_PROJECT_ID -b"$PROJECT_ID"
gh secret set GCP_SA_KEY < sa-key.json
gh secret set TF_VAR_jira_webhook_secret -b"$JIRA_SECRET"

# Cleanup
rm sa-key.json

echo "===================================================="
echo " Bootstrap Complete! "
echo " Please update your terraform/providers.tf file with:"
echo " bucket = \"$STATE_BUCKET\""
echo "===================================================="