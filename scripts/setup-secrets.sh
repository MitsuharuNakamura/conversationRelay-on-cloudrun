#!/bin/bash

set -e

PROJECT_ID=$(gcloud config get-value project)
if [ -z "$PROJECT_ID" ]; then
    echo "Error: No active GCP project. Please run 'gcloud config set project PROJECT_ID'"
    exit 1
fi

echo "Setting up secrets for project: $PROJECT_ID"
echo ""

# Enable Secret Manager API
echo "Enabling Secret Manager API..."
gcloud services enable secretmanager.googleapis.com

# Wait for API to be enabled
echo "Waiting for API to be ready..."
sleep 5

# Parse .env file and create secrets
if [ ! -f .env ]; then
    echo "Error: .env file not found"
    exit 1
fi

echo ""
echo "Creating secrets from .env file..."

while IFS='=' read -r key value; do
    key=$(echo "$key" | xargs)
    value=$(echo "$value" | xargs)
    
    if [[ -z "$key" || "$key" == \#* ]]; then
        continue
    fi
    
    if [[ "$key" == "OPENAI_API_KEY" || "$key" == "TWILIO_AUTH_TOKEN" ]]; then
        if [[ -n "$value" && "$value" != "your-"* && "$value" != "#"* ]]; then
            echo ""
            echo "Creating secret: $key"
            
            # Create or update secret
            echo -n "$value" | gcloud secrets create "$key" --data-file=- 2>/dev/null || {
                echo "Secret already exists, adding new version..."
                echo -n "$value" | gcloud secrets versions add "$key" --data-file=-
            }
            
            # Get project number
            PROJECT_NUMBER=$(gcloud projects describe $PROJECT_ID --format="value(projectNumber)")
            
            # Grant access to Cloud Run default service account
            echo "Granting access to Cloud Run service account..."
            gcloud secrets add-iam-policy-binding "$key" \
                --member="serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
                --role="roles/secretmanager.secretAccessor" \
                --quiet
            
            # Also grant access to App Engine service account (sometimes used by Cloud Run)
            gcloud secrets add-iam-policy-binding "$key" \
                --member="serviceAccount:${PROJECT_ID}@appspot.gserviceaccount.com" \
                --role="roles/secretmanager.secretAccessor" \
                --quiet 2>/dev/null || true
            
            echo "✅ Secret $key configured successfully"
        fi
    fi
done < .env

echo ""
echo "✅ All secrets have been configured!"
echo ""
echo "You can now deploy your service with:"
echo "./scripts/deploy.sh"