#!/bin/bash
set -euo pipefail

PROJECT_ID="$(gcloud config get-value project 2>/dev/null)"
REGION="europe-west1"
STATE_BUCKET="${PROJECT_ID}-tf-state-bucket"
GAR_REPO="ai-proxy-repo"
SA_NAME="github-actions-deployer"
SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
POOL_ID="github-actions-pool-oidc"
PROVIDER_ID="github-provider-oidc"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "❌ ERROR: '$1' is required but not installed/in PATH."
    exit 1
  fi
}

ensure_git_repo() {
  if [[ ! -d .git ]]; then
    echo "❌ ERROR: This directory is not a Git repository."
    echo "Run 'git init' and configure your remote before bootstrapping."
    exit 1
  fi
}

ensure_project() {
  if [[ -z "$PROJECT_ID" || "$PROJECT_ID" == "(unset)" ]]; then
    echo "❌ ERROR: No active GCP project configured."
    echo "Run: gcloud config set project <PROJECT_ID>"
    exit 1
  fi
}

create_or_verify_bucket() {
  echo "[+] Ensuring Terraform state bucket exists: $STATE_BUCKET"
  if ! gsutil ls -b "gs://$STATE_BUCKET" >/dev/null 2>&1; then
    gsutil mb -l "$REGION" "gs://$STATE_BUCKET"
    gsutil versioning set on "gs://$STATE_BUCKET"
  else
    echo "    Bucket already exists."
  fi
}

create_or_verify_repo() {
  echo "[+] Ensuring Artifact Registry repository exists: $GAR_REPO"
  if ! gcloud artifacts repositories describe "$GAR_REPO" --location="$REGION" >/dev/null 2>&1; then
    gcloud artifacts repositories create "$GAR_REPO" \
      --repository-format=docker \
      --location="$REGION" \
      --description="Docker repository for Cloud Run Proxy"
  else
    echo "    Repository already exists."
  fi
}

create_or_verify_service_account() {
  echo "[+] Ensuring CI/CD Service Account exists: $SA_EMAIL"
  if ! gcloud iam service-accounts describe "$SA_EMAIL" >/dev/null 2>&1; then
    gcloud iam service-accounts create "$SA_NAME" --display-name="GitHub Actions Deployer"
    echo "    Waiting 10 seconds for IAM propagation..."
    sleep 10
  else
    echo "    Service Account already exists."
  fi
}

grant_sa_roles() {
  echo "[+] Granting project role to Service Account (roles/owner)..."
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:$SA_EMAIL" \
    --role="roles/owner" >/dev/null
}

create_or_verify_pool() {
  echo "[+] Ensuring Workload Identity Pool exists: $POOL_ID"
  if ! gcloud iam workload-identity-pools describe "$POOL_ID" \
    --location="global" >/dev/null 2>&1; then
    gcloud iam workload-identity-pools create "$POOL_ID" \
      --location="global" \
      --display-name="GitHub Actions OIDC Pool"
  else
    echo "    Pool already exists."
  fi
}

create_or_verify_provider() {
  local repo_nwo="$1"

  echo "[+] Ensuring Workload Identity Provider exists: $PROVIDER_ID"
  if ! gcloud iam workload-identity-pools providers describe "$PROVIDER_ID" \
    --location="global" \
    --workload-identity-pool="$POOL_ID" >/dev/null 2>&1; then
    gcloud iam workload-identity-pools providers create-oidc "$PROVIDER_ID" \
      --location="global" \
      --workload-identity-pool="$POOL_ID" \
      --display-name="GitHub OIDC Provider" \
      --issuer-uri="https://token.actions.githubusercontent.com" \
      --attribute-mapping="google.subject=assertion.sub,attribute.actor=assertion.actor,attribute.repository=assertion.repository" \
      --attribute-condition="assertion.repository=='$repo_nwo'"
  else
    echo "    Provider already exists."
  fi
}

bind_repo_to_service_account() {
  local repo_nwo="$1"
  local pool_full_name

  pool_full_name="$(gcloud iam workload-identity-pools describe "$POOL_ID" --location=global --format='value(name)')"
  if [[ -z "$pool_full_name" ]]; then
    echo "❌ ERROR: Could not resolve full pool name for $POOL_ID"
    exit 1
  fi

  local principal="principalSet://iam.googleapis.com/${pool_full_name}/attribute.repository/${repo_nwo}"

  echo "[+] Granting Workload Identity User binding for repo: $repo_nwo"
  gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" \
    --role="roles/iam.workloadIdentityUser" \
    --member="$principal" >/dev/null
}

configure_github_environment() {
  local repo_nwo="$1"

  local auth_user approver_login approver_id env_payload rules_count
  auth_user="$(gh api user --jq .login 2>/dev/null || true)"
  approver_login="$auth_user"

  if [[ -z "$approver_login" ]]; then
    approver_login="${repo_nwo%%/*}"
  fi

  approver_id="$(gh api "/users/$approver_login" --jq .id 2>/dev/null || true)"
  if [[ -z "$approver_id" ]]; then
    echo "❌ ERROR: Unable to resolve GitHub user id for '$approver_login'."
    exit 1
  fi

  env_payload=$(cat <<EOF
{
  "wait_timer": 0,
  "prevent_self_review": false,
  "reviewers": [
    {
      "type": "User",
      "id": $approver_id
    }
  ]
}
EOF
)

  echo "[+] Configuring GitHub environment protection: production"
  if gh api --method PUT \
    -H "Accept: application/vnd.github+json" \
    "/repos/$repo_nwo/environments/production" \
    --input - >/dev/null <<< "$env_payload"; then

    rules_count="$(gh api \
      -H "Accept: application/vnd.github+json" \
      "/repos/$repo_nwo/environments/production" \
      --jq '.protection_rules | length' 2>/dev/null || true)"

    if [[ -z "$rules_count" || "$rules_count" -lt 1 ]]; then
      echo "❌ ERROR: Environment 'production' has no protection rules after configuration."
      exit 1
    fi

    echo "    Environment protection is configured and verified."
  else
    echo "❌ ERROR: Failed to configure GitHub environment protection."
    exit 1
  fi
}

inject_github_secrets() {
  local provider_full_name="$1"

  echo "[+] Pushing repository secrets for OIDC workflow..."
  read -r -p "Enter your Jira Webhook Secret (default: my-secret-123): " JIRA_SECRET
  JIRA_SECRET="${JIRA_SECRET:-my-secret-123}"

  gh secret set GCP_PROJECT_ID -b"$PROJECT_ID"
  gh secret set GCP_WORKLOAD_ID_PROVIDER -b"$provider_full_name"
  gh secret set GCP_SERVICE_ACCOUNT -b"$SA_EMAIL"
  gh secret set TF_VAR_JIRA_WEBHOOK_SECRET -b"$JIRA_SECRET"
  gh secret set TF_STATE_BUCKET -b"$STATE_BUCKET"

  echo "    OIDC secrets configured."
  echo "    Optional cleanup: remove legacy GCP_SA_KEY secret if no longer used."
}

main() {
  require_cmd gcloud
  require_cmd gh
  require_cmd jq
  require_cmd gsutil

  ensure_git_repo
  ensure_project

  echo "===================================================="
  echo " Bootstrapping GCP Environment for CI/CD Deployment (OIDC mode)"
  echo " Project: $PROJECT_ID"
  echo "===================================================="

  echo "[+] Enabling required GCP APIs..."
  gcloud services enable \
    compute.googleapis.com \
    run.googleapis.com \
    vpcaccess.googleapis.com \
    secretmanager.googleapis.com \
    iam.googleapis.com \
    iamcredentials.googleapis.com \
    sts.googleapis.com \
    cloudresourcemanager.googleapis.com \
    artifactregistry.googleapis.com \
    cloudbuild.googleapis.com

  create_or_verify_bucket
  create_or_verify_repo
  create_or_verify_service_account
  grant_sa_roles

  local repo_nwo
  repo_nwo="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
  if [[ -z "$repo_nwo" ]]; then
    echo "❌ ERROR: Unable to detect GitHub repository via gh CLI."
    exit 1
  fi

  create_or_verify_pool
  create_or_verify_provider "$repo_nwo"
  bind_repo_to_service_account "$repo_nwo"

  local provider_full_name
  provider_full_name="$(gcloud iam workload-identity-pools providers describe "$PROVIDER_ID" \
    --location=global \
    --workload-identity-pool="$POOL_ID" \
    --format='value(name)')"

  if [[ -z "$provider_full_name" ]]; then
    echo "❌ ERROR: Could not resolve workload identity provider full name."
    exit 1
  fi

  inject_github_secrets "$provider_full_name"
  configure_github_environment "$repo_nwo"

  echo "===================================================="
  echo " ✅ Bootstrap Complete (OIDC mode)!"
  echo " All secrets (including TF_STATE_BUCKET) injected."
  echo " OIDC secrets configured: GCP_WORKLOAD_ID_PROVIDER and GCP_SERVICE_ACCOUNT."
  echo " You are ready to run Deploy AI Architecture pipeline."
  echo "===================================================="
}

main "$@"
