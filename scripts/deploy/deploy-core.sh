#!/bin/bash
# =============================================================================
# Unified Core Infrastructure Deployment
# =============================================================================
# Deploys Keycloak and Vault with OIDC integration.
# Supports both Minikube and cloud Kubernetes (GKE, EKS, AKS).
# 
# Usage:
#   ./deploy-core.sh              # Auto-detect platform
#   ./deploy-core.sh --minikube   # Force Minikube mode
#   ./deploy-core.sh --gke        # Force GKE mode
# =============================================================================

set -e

# Get script directory and source libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/../lib/keycloak.sh"
source "$SCRIPT_DIR/../lib/vault.sh"
source "$SCRIPT_DIR/../lib/port-forward.sh"

# =============================================================================
# ARGUMENT PARSING
# =============================================================================

FORCE_PLATFORM=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --minikube) FORCE_PLATFORM="minikube"; shift ;;
        --gke) FORCE_PLATFORM="gke"; shift ;;
        --eks) FORCE_PLATFORM="eks"; shift ;;
        --aks) FORCE_PLATFORM="aks"; shift ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Deploy Keycloak and Vault core infrastructure."
            echo ""
            echo "Options:"
            echo "  --minikube    Force Minikube deployment mode"
            echo "  --gke         Force GKE deployment mode"
            echo "  --eks         Force EKS deployment mode"
            echo "  --aks         Force AKS deployment mode"
            echo "  -h, --help    Show this help"
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Detect or use forced platform
if [ -n "$FORCE_PLATFORM" ]; then
    PLATFORM="$FORCE_PLATFORM"
else
    PLATFORM=$(detect_platform)
fi

# =============================================================================
# DEPLOYMENT STEPS
# =============================================================================

TOTAL_STEPS=12

log_header "Keycloak & Vault Deployment"
echo "Platform: $PLATFORM"
echo "Project Root: $PROJECT_ROOT"

# Enable error handling
enable_error_handling

# Step 1: Platform initialization
if [ "$PLATFORM" == "minikube" ]; then
    log_step 1 $TOTAL_STEPS "Starting Minikube..."
    start_minikube
else
    log_step 1 $TOTAL_STEPS "Verifying cluster connection..."
    verify_cluster_connection
fi

# Step 2: Validate prerequisites
log_step 2 $TOTAL_STEPS "Validating prerequisites..."
validate_prerequisites

# Step 3: Create namespaces
log_step 3 $TOTAL_STEPS "Creating namespaces..."
create_namespaces

# Step 4: Deploy Keycloak Operator
log_step 4 $TOTAL_STEPS "Deploying Keycloak Operator..."
deploy_keycloak_operator

# Step 5: Deploy PostgreSQL
log_step 5 $TOTAL_STEPS "Deploying PostgreSQL..."
deploy_postgres

# Step 6: Deploy Keycloak instance
log_step 6 $TOTAL_STEPS "Deploying Keycloak instance..."
deploy_keycloak_instance

# Step 7: Deploy Vault
log_step 7 $TOTAL_STEPS "Deploying Vault..."
deploy_vault

# Step 8: Initialize Vault
log_step 8 $TOTAL_STEPS "Initializing Vault..."
initialize_vault

# Step 9: Unseal Vault
log_step 9 $TOTAL_STEPS "Unsealing Vault..."
unseal_vault

# Step 10: Start port-forwards
log_step 10 $TOTAL_STEPS "Starting port-forwards..."
start_core_port_forwards
sleep 3

# Step 11: Configure Keycloak realm
log_step 11 $TOTAL_STEPS "Configuring Keycloak vault realm..."
configure_vault_realm

# Step 12: Configure Vault OIDC
log_step 12 $TOTAL_STEPS "Configuring Vault OIDC..."
configure_vault_oidc

# =============================================================================
# VERIFY STORAGE
# =============================================================================

log_section "Verifying Persistent Storage"
kubectl get pvc -n "$NS_OPERATORS" 2>/dev/null | grep postgres || true
kubectl get pvc -n "$NS_VAULT" 2>/dev/null | grep vault || true
log_success "Persistent volumes configured"

# =============================================================================
# DEPLOYMENT SUMMARY
# =============================================================================

log_header "Deployment Complete!"

if [ "$PLATFORM" == "minikube" ]; then
    echo "Minikube Profile: $MINIKUBE_PROFILE"
else
    echo "Cluster: $(kubectl config current-context)"
fi

echo ""
print_keycloak_credentials
print_vault_credentials

echo ""
echo "Credentials saved to:"
echo "  - $VAULT_KEYS_FILE (root token and unseal key)"
echo "  - $KEYCLOAK_CLIENT_SECRET_FILE (OIDC client secret)"
echo ""
echo "Persistent Storage:"
echo "  - PostgreSQL: 2Gi (Keycloak data persists)"
echo "  - Vault: 1Gi (Vault secrets persist)"
echo ""

if [ "$PLATFORM" == "minikube" ]; then
    echo "To restart after 'minikube stop':"
    echo "  ./scripts/restart.sh"
    echo ""
    echo "To switch to this profile:"
    echo "  minikube profile $MINIKUBE_PROFILE"
else
    echo "Port-forwards are running in the background."
    echo "To stop them: pkill -f 'kubectl port-forward'"
fi

echo ""
