#!/bin/bash

set -e

SERVICE_NAME=${1:-conversation-relay}
REGION=${2:-asia-northeast1}

PROJECT_ID=$(gcloud config get-value project)
if [ -z "$PROJECT_ID" ]; then
    echo "Error: No active GCP project. Please run 'gcloud config set project PROJECT_ID'"
    exit 1
fi

echo "Deploying to project: $PROJECT_ID"
echo "Service name: $SERVICE_NAME"
echo "Region: $REGION"
echo ""

if [ ! -f .env ]; then
    echo "Error: .env file not found"
    exit 1
fi

echo "Parsing .env file..."

ENV_VARS=""
SECRETS=""

while IFS='=' read -r key value; do
    key=$(echo "$key" | xargs)
    value=$(echo "$value" | xargs)
    
    if [[ -z "$key" || "$key" == \#* ]]; then
        continue
    fi
    
    if [[ "$key" == "PORT" ]]; then
        continue
    fi
    
    if [[ "$key" == "OPENAI_API_KEY" || "$key" == "TWILIO_AUTH_TOKEN" ]]; then
        if [[ -n "$value" && "$value" != "your-"* && "$value" != "#"* ]]; then
            echo "Will use secret: $key"
            
            if [ -z "$SECRETS" ]; then
                SECRETS="${key}=${key}:latest"
            else
                SECRETS="${SECRETS},${key}=${key}:latest"
            fi
        fi
    else
        if [[ -n "$value" ]]; then
            if [ -z "$ENV_VARS" ]; then
                ENV_VARS="${key}=${value}"
            else
                ENV_VARS="${ENV_VARS},${key}=${value}"
            fi
        fi
    fi
done < .env

echo ""
echo "# Generated Cloud Run deploy command:"
echo "# =================================="
echo ""

echo "gcloud run deploy $SERVICE_NAME \\"
echo "  --source . \\"
echo "  --region $REGION \\"
echo "  --platform managed \\"
echo "  --allow-unauthenticated \\"
echo "  --timeout 3600 \\"
echo "  --concurrency 1 \\"
echo "  --min-instances 1 \\"
echo "  --max-instances 10 \\"
echo "  --memory 512Mi \\"

if [ -n "$SECRETS" ]; then
    echo "  --cpu 1 \\"
    echo "  --set-secrets \"$SECRETS\" \\"
else
    echo -n "  --cpu 1"
fi

if [ -n "$ENV_VARS" ]; then
    if [ -z "$SECRETS" ]; then
        echo " \\"
    fi
    echo "  --set-env-vars \"$ENV_VARS\""
else
    echo ""
fi

echo ""
echo "# =================================="
echo ""
echo "# Note: If you haven't set up secrets yet, run:"
echo "# ./scripts/setup-secrets.sh"
echo ""
echo "# After deployment, your endpoints will be:"
echo "# - TwiML: https://[SERVICE_URL]/twiml/ai"
echo "# - WebSocket: wss://[SERVICE_URL]/relay"
echo "# - Health check: https://[SERVICE_URL]/healthz"