from fastapi import FastAPI, Depends, HTTPException, Header
from pydantic import BaseModel

app = FastAPI()

class JiraPayload(BaseModel):
    ticket_id: str
    action: str

# Mock token validation (Simulating GCP OIDC validation)
def verify_token(authorization: str = Header(None)):
    if not authorization or "Bearer" not in authorization:
        raise HTTPException(status_code=401, detail="Unauthorized: Invalid GCP Token")

@app.post("/process-ticket", dependencies=[Depends(verify_token)])
async def process_ticket(payload: JiraPayload):
    # Simulate CPU/GPU intensive work here
    return {
        "status": "200 OK", 
        "message": f"AI Action '{payload.action}' completed for ticket {payload.ticket_id}"
    }