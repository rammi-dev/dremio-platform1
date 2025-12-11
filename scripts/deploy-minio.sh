#!/bin/bash
set -e

# Get the directory where this script is located and change to project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

# Source the shared MinIO functions
source "$SCRIPT_DIR/lib/minio-common.sh"

echo "========================================="
echo "MinIO Deployment (Add-on)"
echo "========================================="
echo ""

# Check if Keycloak is running
check_keycloak_status "./scripts/deploy.sh"

# Authenticate with Keycloak and get access token
authenticate_keycloak

# Configure Keycloak client for MinIO
configure_keycloak_client "$ACCESS_TOKEN"

# Configure Keycloak RBAC for MinIO
configure_keycloak_rbac "$ACCESS_TOKEN"

# Add groups mapper to Keycloak client
add_groups_mapper "$ACCESS_TOKEN" "$CLIENT_UUID"

# Deploy MinIO Operator
deploy_minio_operator

# Deploy MinIO Tenant
deploy_minio_tenant "$CLIENT_SECRET"

# Configure OIDC for MinIO
configure_minio_oidc "$CLIENT_SECRET"

# Extract MinIO credentials
extract_minio_credentials

# Store credentials in Vault if available
if [ -n "$MINIO_ROOT_USER" ]; then
    store_credentials_in_vault "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD"
fi

# Wait for MinIO to be ready
wait_for_minio_ready

# Create MinIO policy
create_minio_policy "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD"

# Start port-forward for MinIO console
start_port_forward

# Print completion message
print_completion_message
