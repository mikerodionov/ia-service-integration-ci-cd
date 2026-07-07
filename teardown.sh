#!/bin/bash
set -euo pipefail

PROJECT_ID=$(gcloud config get-value project)
REGION="europe-west1"
STATE_BUCKET="${PROJECT_ID}-tf-state-bucket"
GAR_REPO="ai-proxy-repo"
SA_NAME="github-actions-deployer"
SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
POOL_ID="github-actions-pool-oidc"
PROVIDER_ID="github-provider-oidc"

delete_if_exists() {
    local description="$1"
    local check_cmd="$2"
    local delete_cmd="$3"

    if eval "$check_cmd" >/dev/null 2>&1; then
        echo "[!] Deleting $description..."
        eval "$delete_cmd"
    else
        echo "[-] $description not found. Skipping."
    fi
}

delete_github_secret_if_present() {
    local secret_name="$1"
    local repo_nwo="$2"

    if gh secret list --repo "$repo_nwo" --json name --jq '.[].name' 2>/dev/null | grep -qx "$secret_name"; then
        echo "[!] Deleting GitHub secret: $secret_name"
        gh secret delete "$secret_name" --repo "$repo_nwo" >/dev/null
    else
        echo "[-] GitHub secret $secret_name not found. Skipping."
    fi
}

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

echo "[+] Teardown mode: universal (key + OIDC bootstrap artifacts)"

delete_if_exists \
  "Artifact Registry Repository ($GAR_REPO)" \
  "gcloud artifacts repositories describe $GAR_REPO --location=$REGION" \
  "gcloud artifacts repositories delete $GAR_REPO --location=$REGION --quiet"

if gcloud iam workload-identity-pools providers describe "$PROVIDER_ID" \
    --location="global" \
    --workload-identity-pool="$POOL_ID" >/dev/null 2>&1; then
    echo "[!] Deleting Workload Identity Provider ($PROVIDER_ID)..."
    gcloud iam workload-identity-pools providers delete "$PROVIDER_ID" \
        --location="global" \
        --workload-identity-pool="$POOL_ID" \
        --quiet >/dev/null
else
    echo "[-] Workload Identity Provider ($PROVIDER_ID) not found. Skipping."
fi

delete_if_exists \
  "Workload Identity Pool ($POOL_ID)" \
  "gcloud iam workload-identity-pools describe $POOL_ID --location=global" \
  "gcloud iam workload-identity-pools delete $POOL_ID --location=global --quiet"

delete_if_exists \
  "CI/CD Service Account ($SA_EMAIL)" \
  "gcloud iam service-accounts describe $SA_EMAIL" \
  "gcloud iam service-accounts delete $SA_EMAIL --quiet"

if gsutil ls -b "gs://$STATE_BUCKET" >/dev/null 2>&1; then
    echo "[!] Deleting Terraform State Bucket (including all state history)..."
    gsutil rm -r "gs://$STATE_BUCKET"
else
    echo "[-] Terraform State Bucket ($STATE_BUCKET) not found. Skipping."
fi

REPO_NWO=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)
if [ -n "${REPO_NWO}" ]; then
    echo "[+] Cleaning GitHub repository secrets (if present)..."
    delete_github_secret_if_present "GCP_SA_KEY" "$REPO_NWO"
    delete_github_secret_if_present "GCP_WORKLOAD_ID_PROVIDER" "$REPO_NWO"
    delete_github_secret_if_present "GCP_SERVICE_ACCOUNT" "$REPO_NWO"
    delete_github_secret_if_present "GCP_PROJECT_ID" "$REPO_NWO"
    delete_github_secret_if_present "TF_VAR_jira_webhook_secret" "$REPO_NWO"
    delete_github_secret_if_present "TF_STATE_BUCKET" "$REPO_NWO"
else
    echo "[-] Could not resolve repository via gh CLI. Skipping secret cleanup."
fi

echo "===================================================="
echo " ✅ Teardown Complete. Bootstrap resources destroyed."
echo "===================================================="