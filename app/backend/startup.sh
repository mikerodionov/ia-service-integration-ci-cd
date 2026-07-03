#!/bin/bash
# Install dependencies
apt-get update
apt-get install -y python3-pip python3-venv git

# Setup application directory
mkdir -p /opt/ai-backend
cd /opt/ai-backend

# Write backend.py inline
cat << 'EOF' > backend.py
from fastapi import FastAPI, Depends, HTTPException, Header
from pydantic import BaseModel

app = FastAPI()

class JiraPayload(BaseModel):
    ticket_id: str
    action: str

def verify_token(authorization: str = Header(None)):
    if not authorization or "Bearer" not in authorization:
        raise HTTPException(status_code=401, detail="Unauthorized: Invalid GCP Token")

@app.post("/process-ticket", dependencies=[Depends(verify_token)])
async def process_ticket(payload: JiraPayload):
    return {
        "status": "200 OK", 
        "message": f"AI Action '{payload.action}' completed for ticket {payload.ticket_id}"
    }
EOF

# Write requirements inline
cat << 'EOF' > requirements.txt
fastapi==0.110.1
uvicorn[standard]==0.29.0
EOF

# Setup Virtual Environment
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt

# Create a systemd service to run FastAPI permanently on port 8000
cat << 'EOF' > /etc/systemd/system/backend.service
[Unit]
Description=FastAPI AI Backend
After=network.target

[Service]
User=root
WorkingDirectory=/opt/ai-backend
ExecStart=/opt/ai-backend/venv/bin/uvicorn backend:app --host 0.0.0.0 --port 8000
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# Start the service
systemctl daemon-reload
systemctl enable backend.service
systemctl start backend.service