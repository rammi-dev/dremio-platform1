#!/bin/bash
# Deploy Dremio with image pull secrets from .env

set -e

# Get the directory where this script is located and change to project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

# Source common functions
source "$SCRIPT_DIR/lib/dremio-common.sh"

echo "========================================="
echo "Dremio Deployment"
echo "========================================="
echo ""

# Load credentials from .env
echo "Step 1: Loading registry credentials..."
if ! load_dremio_env; then
    exit 1
fi
echo ""

# Export for Helm
export_helm_values

# Deploy with Helm
echo "Step 2: Deploying Dremio with Helm..."
helm upgrade --install dremio ./helm/dremio \
    --create-namespace \
    --set imagePullSecret.registry="$HELM_REGISTRY" \
    --set imagePullSecret.username="$HELM_USERNAME" \
    --set imagePullSecret.password="$HELM_PASSWORD" \
    --set imagePullSecret.email="$HELM_EMAIL"

echo ""
echo "✓ Dremio deployment complete!"
echo ""
echo "To verify the secret was created:"
echo "  kubectl get secret dremio-pull-secret -n dremio"
echo ""
echo "To check the deployment:"
echo "  kubectl get pods -n dremio"
echo ""
