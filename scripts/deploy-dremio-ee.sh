#!/bin/bash
# Deploy Dremio Enterprise with MongoDB Operator on GKE
# Architecture: MongoDB Operator → MongoDB Instance → Dremio EE (with Polaris + Engine Operator)

set -e

# Get the directory where this script is located and change to project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

echo "========================================="
echo "Dremio Enterprise Deployment (GKE)"
echo "MongoDB Operator + Polaris + Engines"
echo "========================================="
echo ""

# Load environment variables
ENV_FILE="${PROJECT_ROOT}/helm/dremio/.env"
if [ ! -f "$ENV_FILE" ]; then
    echo "ERROR: .env file not found at $ENV_FILE"
    echo "Please create it with your Dremio license key and Quay.io credentials"
    exit 1
fi

set -a
source "$ENV_FILE"
set +a

# Validate required variables
if [ -z "$DREMIO_REGISTRY_USER" ] || [ -z "$DREMIO_REGISTRY_PASSWORD" ]; then
    echo "ERROR: DREMIO_REGISTRY_USER and DREMIO_REGISTRY_PASSWORD must be set in .env"
    exit 1
fi

echo "✓ Loaded environment variables"
echo ""

# Create namespace and image pull secret (Helm will adopt the namespace)
echo ""
echo "Creating namespace and image pull secret..."

# Only create namespace if it doesn't exist
if ! kubectl get namespace dremio >/dev/null 2>&1; then
  kubectl create namespace dremio
  echo "✓ Namespace created"
else
  echo "✓ Namespace already exists"
fi

kubectl create secret docker-registry dremio-quay-secret \
  --docker-server="${DREMIO_REGISTRY:-quay.io}" \
  --docker-username="$DREMIO_REGISTRY_USER" \
  --docker-password="$DREMIO_REGISTRY_PASSWORD" \
  --docker-email="${DREMIO_REGISTRY_EMAIL:-no-reply@dremio.local}" \
  -n dremio \
  --dry-run=client -o yaml | kubectl apply -f -

echo "✓ Namespace and secret ready"
echo ""

# Note: License secret will be created by Helm chart
# We'll pass the license key as a Helm value instead
if [ -n "$DREMIO_LICENSE_KEY" ] && [ "$DREMIO_LICENSE_KEY" != "your-license-key-here" ]; then
    echo "✓ License key found in .env"
else
    echo "⚠️  WARNING: No license key provided. Dremio will run in trial mode."
    echo "   Set DREMIO_LICENSE_KEY in .env file to use Enterprise features."
fi
echo ""

# Create Dremio bucket in MinIO
echo "Creating Dremio bucket in MinIO..."
if ! ./scripts/create-dremio-bucket.sh; then
    echo "ERROR: Failed to create Dremio bucket"
    exit 1
fi
echo ""

# Retrieve MinIO credentials
echo "Retrieving MinIO credentials..."
MINIO_ACCESS_KEY=$(kubectl get secret minio-env-configuration -n minio -o jsonpath='{.data.config\.env}' | base64 -d | grep "MINIO_ROOT_USER=" | cut -d= -f2 | tr -d '"')
MINIO_SECRET_KEY=$(kubectl get secret minio-env-configuration -n minio -o jsonpath='{.data.config\.env}' | base64 -d | grep "MINIO_ROOT_PASSWORD=" | cut -d= -f2 | tr -d '"')

if [ -z "$MINIO_ACCESS_KEY" ] || [ -z "$MINIO_SECRET_KEY" ]; then
    echo "ERROR: Failed to retrieve MinIO credentials!"
    exit 1
fi

echo "✓ Retrieved MinIO credentials"
echo ""

# Deploy Dremio via Helm
echo "Deploying Dremio Enterprise..."

# Build Helm command with dynamic options
HELM_CMD="helm upgrade --install dremio ./helm/dremio \
  -n dremio \
  --create-namespace \
  -f ./helm/dremio/values.yaml \
  -f ./helm/dremio/values-overwrite.yaml \
  --set distStorage.aws.credentials.accessKey=\"$MINIO_ACCESS_KEY\" \
  --set distStorage.aws.credentials.secret=\"$MINIO_SECRET_KEY\""

# Add license key if provided
if [ -n "$DREMIO_LICENSE_KEY" ] && [ "$DREMIO_LICENSE_KEY" != "your-license-key-here" ]; then
  HELM_CMD="$HELM_CMD --set dremio.license=\"$DREMIO_LICENSE_KEY\""
fi

HELM_CMD="$HELM_CMD --wait --timeout=15m"

# Execute Helm command
eval $HELM_CMD

echo "✓ Dremio Enterprise deployed"
echo ""

# Start port forwarding for Dremio UI
echo "Starting port-forward for Dremio UI..."
kubectl port-forward -n dremio svc/dremio-client 9047:9047 --address=0.0.0.0 > /dev/null 2>&1 &
PF_PID=$!
sleep 2

# Verify port-forward is running
if kill -0 $PF_PID 2>/dev/null; then
    echo "✓ Port-forward started (PID: $PF_PID)"
else
    echo "⚠️  Port-forward failed to start"
fi
echo ""

# Display access information
echo "========================================="
echo "Dremio Enterprise Deployment Complete!"
echo "========================================="
echo ""
echo "Components Deployed:"
echo "  - MongoDB Operator (Percona)"
echo "  - MongoDB Instance (single-node for POC)"
echo "  - Dremio Coordinator"
echo "  - Dremio Engine Operator"
echo "  - Polaris Catalog (internal)"
echo "  - OpenSearch"
echo ""
echo "Access Dremio Sonar UI:"
echo "  URL: http://localhost:9047"
echo ""
echo "  ⚠️  IMPORTANT - First-time setup:"
echo "  1. Create admin username and password"
echo "  2. Go to Settings → Engines"
echo "  3. Click 'Add Engine' to create your first engine"
echo "  4. Choose size SMALL (minimal resources) for POC"
echo ""
echo "  📝 Engines CANNOT be created via Helm - they require"
echo "     special annotations that are only set by the UI."
echo ""
echo "Manage port-forward:"
echo "  Stop: kill $PF_PID"
echo "  Restart: kubectl port-forward -n dremio svc/dremio-client 9047:9047 --address=0.0.0.0"
echo ""
echo "Check deployment status:"
echo "  kubectl get pods -n dremio"
echo "  kubectl get psmdb -n dremio"
echo ""
echo "========================================="
