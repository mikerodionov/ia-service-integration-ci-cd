from fastapi import FastAPI, Header, HTTPException, Request
import httpx
import os

app = FastAPI()

# Read dynamic variables injected by Terraform/Cloud Run
EXPECTED_JIRA_SECRET = os.environ.get("EXPECTED_SECRET")
BACKEND_URL = os.environ.get("BACKEND_URL")

@app.post("/webhook")
async def handle_jira_webhook(request: Request, x_jira_webhook_secret: str = Header(None)):
    # 1. Validate Secret
    if not EXPECTED_JIRA_SECRET or x_jira_webhook_secret != EXPECTED_JIRA_SECRET:
        raise HTTPException(status_code=401, detail="Unauthorized: Invalid Webhook Secret")
    
    # 2. Extract payload
    payload = await request.json()

    # 3. Generate GCP Token (Mocked for this assignment)
    gcp_token = "mock-gcp-oidc-token"

    # 4. Forward to Backend via Internal Network
    headers = {"Authorization": f"Bearer {gcp_token}"}
    
    async with httpx.AsyncClient() as client:
        response = await client.post(BACKEND_URL, json=payload, headers=headers)
        
    return response.json()