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

# 0. Pre-flight Check: Ensure this is a Git repository
if [ ! -d ".git" ]; then
    echo "❌ ERROR: This directory is not a Git repository."
    echo "Please run 'git init' and 'git remote add origin <URL>' before bootstrapping."
    exit 1
fi

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

# 3. Create Artifact Registry Repository
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
if ! gcloud iam service-accounts describe $SA_EMAIL > /dev/null 2>&1; then
    gcloud iam service-accounts create $SA_NAME --display-name="GitHub Actions Deployer"
    
    # Advanced Details: GCP IAM Eventual Consistency Mitigation
    echo "    Waiting 10 seconds for IAM propagation across GCP servers..."
    sleep 10
else
    echo "    Service Account already exists. Skipping creation."
fi

echo "[+] Assigning roles/owner to Service Account..."
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
gh secret set TF_STATE_BUCKET -b"$STATE_BUCKET" # Injected for Partial Config

# 7. Create/Update GitHub Environment Approval Gate
echo "[+] Configuring GitHub Actions environment protection..."
REPO_NWO=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)
AUTH_USER=$(gh api user --jq .login 2>/dev/null)

if [ -z "$REPO_NWO" ]; then
        echo "    WARNING: Unable to detect repository from gh CLI. Skipping environment setup."
else
        REPO_OWNER="${REPO_NWO%%/*}"
        APPROVER_LOGIN="$AUTH_USER"

        # Fallback for forks or constrained auth contexts.
        if [ -z "$APPROVER_LOGIN" ]; then
                APPROVER_LOGIN="$REPO_OWNER"
        fi

        APPROVER_ID=$(gh api "/users/$APPROVER_LOGIN" --jq .id 2>/dev/null)
        if [ -z "$APPROVER_ID" ]; then
                echo "    WARNING: Unable to resolve GitHub user id for '$APPROVER_LOGIN'. Skipping environment setup."
        else
                ENV_PAYLOAD=$(cat <<EOF
{
    "wait_timer": 0,
    "prevent_self_review": false,
    "reviewers": [
        {
            "type": "User",
            "id": $APPROVER_ID
        }
    ],
    "deployment_branch_policy": {
        "protected_branches": false,
        "custom_branch_policies": false
    }
}
EOF
)

                if gh api --method PUT \
                        -H "Accept: application/vnd.github+json" \
                        "/repos/$REPO_NWO/environments/production" \
                        --input - >/dev/null <<< "$ENV_PAYLOAD"; then
                        echo "    Environment 'production' configured with required reviewer: $APPROVER_LOGIN"
                else
                        echo "    WARNING: Failed to configure environment protection automatically."
                        echo "    You may need repo admin permissions and 'repo' scope in gh auth."
                fi
        fi
fi

# Cleanup local key
rm -f sa-key.json

echo "===================================================="
echo " ✅ Bootstrap Complete! "
echo " All secrets (including TF_STATE_BUCKET) injected."
echo " You are ready to commit and push."
echo "====================================$STATE_BUCKET================"