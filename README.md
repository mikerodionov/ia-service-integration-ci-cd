# GCP AI Service Integration - CI/CD & Infrastructure as Code

This repository contains the automated deployment pipeline and Infrastructure as Code (IaC) for integrating a Jira webhook with an internal AI backend hosted on Google Cloud Platform (GCP). 

The architecture strictly adheres to a 99.95% availability SLO by utilizing a Regional Managed Instance Group (MIG) for the FastAPI backend, while maintaining cost-efficiency for bursty traffic using a Serverless Cloud Run authentication proxy.

## Architecture Overview
1. **Cloud Run (Auth Proxy):** Intercepts Jira webhooks, validates a custom secret via Google Secret Manager, and generates a GCP OIDC token.
2. **Internal HTTP Load Balancer:** Distributes private VPC traffic across multiple availability zones.
3. **Compute Engine MIG:** Hosts the Python/FastAPI AI application on GPU-enabled instances (provisioned via startup scripts).

---

## Deployment Instructions

### Prerequisites
Before starting, ensure you have the following installed and authenticated on your local machine:
* [Google Cloud SDK (`gcloud`)](https://cloud.google.com/sdk/docs/install) - Authenticated with `gcloud auth login`.
* [GitHub CLI (`gh`)](https://cli.github.com/) - Authenticated with `gh auth login`.
* A valid GCP Project with billing enabled.

### Step 1: Bootstrap the Environment
To avoid "chicken-or-egg" deployment issues, a bootstrap script is provided to create the baseline resources required for the CI/CD pipeline (State Buckets, Artifact Registry, CI/CD Service Account, and GitHub Secrets).

1. Clone this repository and navigate to the root directory.
2. Make the script executable:
   ```bash
   chmod +x bootstrap.sh
   ```
3. Run the bootstrap script:
   ```bash
   ./bootstrap.sh
   ```
   *Note: The script will prompt you to enter the Jira Webhook Secret you want to use. It will automatically inject this securely into your GitHub Repository Secrets.*

### Step 2: Update Terraform State Configuration
The bootstrap script outputs the name of your newly created GCS State Bucket. 

1. Open `terraform/providers.tf`.
2. Update the `bucket` value inside the `backend "gcs"` block with the name provided by the script.
   ```hcl
   backend "gcs" {
     bucket = "YOUR-NEW-BUCKET-NAME"
     prefix = "terraform/state/ia-service"
   }
   ```

### Step 3: Trigger the Pipeline
1. Commit your changes to `providers.tf`.
2. Push the code to the `main` branch of your repository.
3. Navigate to the **Actions** tab in your GitHub repository to watch the deployment. The pipeline will automatically build the proxy container, push it to Artifact Registry, and apply the Terraform configuration.

---

## Testing & Verification

Once the GitHub Actions pipeline completes successfully, navigate to the GCP Console -> **Cloud Run** to find the public URL of your newly deployed `jira-auth-proxy` service.

You can test the end-to-end flow from your local terminal using the following `cURL` command (replace `<YOUR_CLOUD_RUN_URL>` with your actual URL, and the secret if you customized it during bootstrap):

**Test Success (Valid Secret):**
```bash
curl -X POST <YOUR_CLOUD_RUN_URL>/webhook \
  -H "Content-Type: application/json" \
  -H "X-Jira-Webhook-Secret: my-secret-123" \
  -d '{"ticket_id": "PROJ-994", "action": "summarize_rca"}'
```
*Expected Output:* `{"status":"200 OK","message":"AI Action 'summarize_rca' completed for ticket PROJ-994"}`

**Test Failure (Invalid Secret):**
```bash
curl -X POST <YOUR_CLOUD_RUN_URL>/webhook \
  -H "Content-Type: application/json" \
  -H "X-Jira-Webhook-Secret: WRONG-PASSWORD" \
  -d '{"ticket_id": "PROJ-994", "action": "summarize_rca"}'
```
*Expected Output:* `{"detail":"Unauthorized: Invalid Webhook Secret"}`

## Cleanup

To avoid unexpected GCP charges, you must cleanly tear down the infrastructure when you are finished.

1. **Destroy the Infrastructure (Via GitHub Actions):**
   * Navigate to the **Actions** tab in your GitHub repository.
   * On the left sidebar, click on the **Destroy AI Architecture** workflow.
   * Click the **Run workflow** dropdown on the right side and execute it. 
   * *Wait for this pipeline to complete successfully. It will execute `terraform destroy` to remove the Load Balancer, VMs, and Cloud Run proxy.*

2. **Destroy the Bootstrap Resources (Local):**
   Once the GitHub Actions destroy pipeline finishes, run the local teardown script to delete the foundational resources (Terraform State Bucket, Artifact Registry, and CI/CD Service Account).
   ```bash
   chmod +x teardown.sh
   ./teardown.sh