#!/bin/bash

PROJECT_ID=$(gcloud config get-value project)
REGION="europe-west1"
STATE_BUCKET="${PROJECT_ID}-tf-state-bucket"
GAR_REPO="ai-proxy-repo"
SA_NAME="github-actions-deployer"
SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

echo "===================================================="
echo " ⚠️  DANGER ZONE: Teardown GCP Bootstrap Resources"
echo "===================================================="
echo "CRITICAL: Have you destroyed your Terraform infrastructure yet?"
echo "If you delete the state bucket before running 'terraform destroy', "
echo "your GCP resources (Load Balancer, VMs) will be orphaned and cost money!"
echo ""
read -p "Type 'YES' to confirm and proceed with destruction: " CONFIRM

if [ "$CONFIRM" != "YES" ]; then
    echo "Teardown aborted."
    exit 0
fi

echo "[!] Deleting Artifact Registry Repository..."
gcloud artifacts repositories delete $GAR_REPO --location=$REGION --quiet

echo "[!] Deleting CI/CD Service Account..."
gcloud iam service-accounts delete $SA_EMAIL --quiet

echo "[!] Deleting Terraform State Bucket (including all state history)..."
gsutil rm -r gs://$STATE_BUCKET

echo "===================================================="
echo " ✅ Teardown Complete. Bootstrap resources destroyed."
echo "===================================================="