#!/bin/bash
# Deploy JupyterHub on GKE with Keycloak authentication and MinIO STS integration

set -e

# Source common functions
source scripts/lib/jupyterhub-common.sh

echo "========================================="
echo "JupyterHub Deployment (Add-on) - GKE"
echo "========================================="
echo ""

# Check if Keycloak is running
if ! kubectl get pod keycloak-0 -n operators 2>/dev/null | grep -q "Running"; then
  echo "ERROR: Keycloak is not running. Please run ./scripts/deploy-gke.sh first."
  exit 1
fi
echo "✓ Keycloak is running"

# Check if MinIO is running
if ! kubectl get pod -n minio -l v1.min.io/tenant=minio 2>/dev/null | grep -q "Running"; then
  echo "ERROR: MinIO is not running. Please run ./scripts/deploy-minio-gke.sh first."
  exit 1
fi
echo "✓ MinIO is running"

# Authenticate with Keycloak
authenticate_keycloak

# Configure Keycloak client for JupyterHub
configure_jupyterhub_keycloak_client "$ACCESS_TOKEN"

# Deploy JupyterHub
deploy_jupyterhub "$JUPYTERHUB_CLIENT_SECRET"

# Wait for JupyterHub to be ready
wait_for_jupyterhub_ready

# Start port-forward
start_jupyterhub_port_forward

# Print completion message
print_jupyterhub_completion
