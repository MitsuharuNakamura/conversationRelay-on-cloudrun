#!/bin/bash

set -e

# Usage function
usage() {
    echo "Usage: $0 <command> [service-name] [region]"
    echo ""
    echo "Commands:"
    echo "  on        Set min-instances to 1 (always running)"
    echo "  off       Set min-instances to 0 (scale to zero)"
    echo "  toggle    Toggle between 0 and 1 automatically"
    echo "  status    Show current service status"
    echo ""
    echo "Parameters:"
    echo "  service-name  Cloud Run service name (default: conversation-relay)"
    echo "  region        GCP region (default: asia-northeast1)"
    echo ""
    echo "Examples:"
    echo "  $0 on                                    # Turn on with defaults"
    echo "  $0 off my-service us-central1           # Turn off specific service"
    echo "  $0 toggle                               # Auto toggle with defaults"
    echo "  $0 status                               # Show current status"
    exit 1
}

# Check if command is provided
if [ $# -lt 1 ]; then
    echo "Error: Command is required"
    echo ""
    usage
fi

COMMAND=$1
SERVICE_NAME=${2:-conversation-relay}
REGION=${3:-asia-northeast1}

# Current project check
PROJECT_ID=$(gcloud config get-value project)
if [ -z "$PROJECT_ID" ]; then
    echo "Error: No active GCP project. Please run 'gcloud config set project PROJECT_ID'"
    exit 1
fi

# Function to get current min-instances
get_current_min_instances() {
    local current=$(gcloud run services describe $SERVICE_NAME \
        --region $REGION \
        --format="value(spec.template.metadata.annotations['autoscaling.knative.dev/minScale'])" \
        2>/dev/null || echo "0")
    
    if [ -z "$current" ]; then
        current="0"
    fi
    echo "$current"
}

# Function to update service
update_service() {
    local target_instances=$1
    local action_text=$2
    
    echo "$action_text"
    echo "Service: $SERVICE_NAME"
    echo "Region: $REGION"
    echo "Project: $PROJECT_ID"
    echo ""
    
    echo "Updating Cloud Run service..."
    gcloud run services update $SERVICE_NAME \
        --region $REGION \
        --min-instances $target_instances \
        --quiet
    
    echo ""
    echo "✅ Successfully updated min-instances to $target_instances"
}

# Function to show service status
show_status() {
    echo "Service Status: $SERVICE_NAME"
    echo "Region: $REGION"
    echo "Project: $PROJECT_ID"
    echo ""
    
    # Get current min-instances
    local current_min=$(get_current_min_instances)
    echo "Current min-instances: $current_min"
    
    # Show detailed status
    echo ""
    echo "Detailed service information:"
    gcloud run services describe $SERVICE_NAME \
        --region $REGION \
        --format="table(status.url:label=URL,status.conditions[0].type:label=STATUS,spec.template.metadata.annotations['autoscaling.knative.dev/minScale']:label=MIN_INSTANCES,spec.template.metadata.annotations['autoscaling.knative.dev/maxScale']:label=MAX_INSTANCES)" \
        2>/dev/null || {
        echo "Error: Service '$SERVICE_NAME' not found in region '$REGION'"
        exit 1
    }
    
    # Show implications
    if [ "$current_min" = "0" ]; then
        echo ""
        echo "💰 Current mode: Scale to zero"
        echo "   - Lower costs when idle"
        echo "   - Possible cold start delays (1-2 seconds)"
    else
        echo ""
        echo "🚀 Current mode: Always running"
        echo "   - No cold start delays"
        echo "   - Higher costs (always consuming resources)"
    fi
}

# Function to show post-update info
show_post_update_info() {
    local target_instances=$1
    
    if [ "$target_instances" = "1" ]; then
        echo ""
        echo "🚀 Service is now always running (min-instances: 1)"
        echo ""
        echo "Benefits:"
        echo "  - No cold start delays"
        echo "  - Instant response to phone calls"
        echo "  - WebSocket connections are always ready"
        echo ""
        echo "💰 Note: This will incur costs even when not in use"
    else
        echo ""
        echo "💰 Service will now scale to zero when not in use (min-instances: 0)"
        echo ""
        echo "Benefits:"
        echo "  - Lower costs when idle"
        echo "  - No charges when no requests"
        echo "  - Automatic scaling based on demand"
        echo ""
        echo "⚠️  Note: First request may experience cold start delay (~1-2 seconds)"
    fi
    
    # Get and show service URL
    local service_url=$(gcloud run services describe $SERVICE_NAME --region $REGION --format='value(status.url)' 2>/dev/null)
    if [ -n "$service_url" ]; then
        echo ""
        echo "Service endpoints:"
        echo "  - Health check: ${service_url}/healthz"
        echo "  - TwiML: ${service_url}/twiml/ai"
    fi
}

# Main command processing
case $COMMAND in
    "on")
        update_service "1" "🚀 Starting up service (min-instances: 0 → 1)"
        show_post_update_info "1"
        ;;
    
    "off")
        update_service "0" "🛑 Shutting down service (min-instances → 0)"
        show_post_update_info "0"
        ;;
    
    "toggle")
        echo "Getting current configuration..."
        current_min_instances=$(get_current_min_instances)
        echo "Current min-instances: $current_min_instances"
        
        if [ "$current_min_instances" = "0" ]; then
            target_min_instances="1"
            action_text="🚀 Starting up service (min-instances: 0 → 1)"
        else
            target_min_instances="0"
            action_text="🛑 Shutting down service (min-instances: $current_min_instances → 0)"
        fi
        
        echo ""
        update_service "$target_min_instances" "$action_text"
        show_post_update_info "$target_min_instances"
        ;;
    
    "status")
        show_status
        ;;
    
    *)
        echo "Error: Unknown command '$COMMAND'"
        echo ""
        usage
        ;;
esac