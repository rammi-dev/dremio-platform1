#!/bin/bash
# Common functions for Dremio deployment

# Load environment variables from .env file
load_dremio_env() {
    local env_file="${PROJECT_ROOT}/helm/dremio/.env"
    
    if [ ! -f "$env_file" ]; then
        echo "ERROR: .env file not found at $env_file"
        echo "Please create it with your Quay.io credentials:"
        echo "  DREMIO_REGISTRY=quay.io"
        echo "  DREMIO_REGISTRY_USER=your-username"
        echo "  DREMIO_REGISTRY_PASSWORD=your-password"
        echo "  DREMIO_REGISTRY_EMAIL=no-reply@dremio.local"
        return 1
    fi
    
    # Source the .env file
    set -a
    source "$env_file"
    set +a
    
    # Set defaults if not provided
    export DREMIO_REGISTRY="${DREMIO_REGISTRY:-quay.io}"
    export DREMIO_REGISTRY_EMAIL="${DREMIO_REGISTRY_EMAIL:-no-reply@dremio.local}"
    
    # Validate required variables
    if [ -z "$DREMIO_REGISTRY_USER" ] || [ -z "$DREMIO_REGISTRY_PASSWORD" ]; then
        echo "ERROR: DREMIO_REGISTRY_USER and DREMIO_REGISTRY_PASSWORD must be set in .env"
        return 1
    fi
    
    echo "✓ Loaded Dremio registry credentials from .env"
    return 0
}

# Export environment variables for Helm
export_helm_values() {
    export HELM_REGISTRY="$DREMIO_REGISTRY"
    export HELM_USERNAME="$DREMIO_REGISTRY_USER"
    export HELM_PASSWORD="$DREMIO_REGISTRY_PASSWORD"
    export HELM_EMAIL="$DREMIO_REGISTRY_EMAIL"
}
