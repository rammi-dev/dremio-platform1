#!/bin/bash
# =============================================================================
# Unified MinIO Deployment
# =============================================================================
# Deploys MinIO Operator and Tenant with Keycloak OIDC integration.
# Requires core infrastructure (Keycloak + Vault) to be deployed first.
#
# Usage:
#   ./deploy-minio.sh
# =============================================================================

set -e

# Get script directory and source libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/../lib/keycloak.sh"
source "$SCRIPT_DIR/../lib/port-forward.sh"
source "$SCRIPT_DIR/../lib/minio-common.sh"

# =============================================================================
# PRE-FLIGHT CHECKS
# =============================================================================

log_header "MinIO Deployment (Add-on)"

# Check if Keycloak is running
log_info "Checking prerequisites..."
if ! is_pod_running "keycloak-0" "$NS_OPERATORS"; then
    log_error "Keycloak is not running. Please deploy core infrastructure first:"
    log_error "  ./scripts/deploy/deploy-core.sh"
    exit 1
fi
log_success "Keycloak is running"

# Ensure Keycloak port-forward
ensure_keycloak_port_forward

# =============================================================================
# DEPLOYMENT STEPS
# =============================================================================

# Authenticate with Keycloak and get access token
log_section "Authenticating with Keycloak"
authenticate_keycloak

# Configure Keycloak client for MinIO
log_section "Configuring Keycloak for MinIO"
configure_keycloak_client "$ACCESS_TOKEN"

# Configure Keycloak RBAC for MinIO
configure_keycloak_rbac "$ACCESS_TOKEN"

# Add groups mapper to Keycloak client
add_groups_mapper "$ACCESS_TOKEN" "$CLIENT_UUID"

# Deploy MinIO Operator
log_section "Deploying MinIO Operator"
deploy_minio_operator

# Deploy MinIO Tenant
log_section "Deploying MinIO Tenant"
deploy_minio_tenant "$CLIENT_SECRET"

# Configure OIDC for MinIO
log_section "Configuring MinIO OIDC"
configure_minio_oidc "$CLIENT_SECRET"

# Extract MinIO credentials
extract_minio_credentials

# Store credentials in Vault if available
if [ -n "$MINIO_ROOT_USER" ]; then
    log_section "Storing Credentials in Vault"
    store_credentials_in_vault "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD"
fi

# Wait for MinIO to be ready
log_section "Waiting for MinIO"
wait_for_minio_ready

# Configure MinIO policies
log_section "Configuring MinIO Policies"
configure_minio_policies

# Start port-forward for MinIO console
log_section "Starting Port-Forwards"
start_port_forward

# =============================================================================
# DEPLOYMENT SUMMARY
# =============================================================================

print_completion_message
