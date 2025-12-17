#!/bin/bash
# =============================================================================
# Central Configuration for Platform Deployment Scripts
# =============================================================================
# This file contains all shared configuration values used across deployment
# scripts. Source this file at the beginning of any deployment script.
# =============================================================================

# -----------------------------------------------------------------------------
# Platform Detection
# -----------------------------------------------------------------------------
detect_platform() {
    local context
    context=$(kubectl config current-context 2>/dev/null || echo "unknown")
    
    if echo "$context" | grep -qi "minikube"; then
        echo "minikube"
    elif echo "$context" | grep -qi "gke"; then
        echo "gke"
    elif echo "$context" | grep -qi "aks"; then
        echo "aks"
    elif echo "$context" | grep -qi "eks"; then
        echo "eks"
    else
        echo "kubernetes"
    fi
}

# -----------------------------------------------------------------------------
# Namespaces
# -----------------------------------------------------------------------------
export NS_OPERATORS="operators"          # Keycloak operator, PostgreSQL
export NS_KEYCLOAK="keycloak"            # Keycloak instances (if separated)
export NS_VAULT="vault"                  # HashiCorp Vault
export NS_MINIO="minio"                  # MinIO tenant
export NS_MINIO_OPERATOR="minio-operator" # MinIO operator
export NS_DREMIO="dremio"                # Dremio Enterprise
export NS_JUPYTERHUB="jupyterhub"        # JupyterHub
export NS_SPARK="spark-operator"         # Spark Operator

# -----------------------------------------------------------------------------
# Service Ports (Local port-forward mappings)
# -----------------------------------------------------------------------------
export PORT_KEYCLOAK=8080                # Keycloak Admin Console
export PORT_VAULT=8200                   # Vault UI
export PORT_MINIO_CONSOLE=9091           # MinIO Console (HTTPS -> 9443)
export PORT_MINIO_API=9000               # MinIO S3 API (HTTPS -> 443)
export PORT_JUPYTERHUB=8000              # JupyterHub
export PORT_DREMIO=9047                  # Dremio Sonar UI

# -----------------------------------------------------------------------------
# Timeouts (seconds)
# -----------------------------------------------------------------------------
export TIMEOUT_SHORT=120                 # Quick operations
export TIMEOUT_MEDIUM=300                # Standard deployments
export TIMEOUT_LONG=600                  # Heavy deployments (Dremio)
export TIMEOUT_VERY_LONG=900             # Complex multi-component deployments

# -----------------------------------------------------------------------------
# Minikube Settings
# -----------------------------------------------------------------------------
export MINIKUBE_PROFILE="${MINIKUBE_PROFILE:-keycloak-vault}"
export MINIKUBE_CPUS=4
export MINIKUBE_MEMORY=8192
export MINIKUBE_DRIVER="${MINIKUBE_DRIVER:-docker}"

# -----------------------------------------------------------------------------
# Paths (auto-resolved)
# -----------------------------------------------------------------------------
# PROJECT_ROOT is set relative to this config file's location
if [ -z "$PROJECT_ROOT" ]; then
    export PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

export CONFIG_DIR="$PROJECT_ROOT/config"
export HELM_DIR="$PROJECT_ROOT/helm"
export SCRIPTS_DIR="$PROJECT_ROOT/scripts"
export SCRIPTS_LIB_DIR="$SCRIPTS_DIR/lib"

# -----------------------------------------------------------------------------
# Credential Files
# -----------------------------------------------------------------------------
export VAULT_KEYS_FILE="$CONFIG_DIR/vault-keys.json"
export KEYCLOAK_CLIENT_SECRET_FILE="$CONFIG_DIR/keycloak-vault-client-secret.txt"

# -----------------------------------------------------------------------------
# Keycloak Configuration
# -----------------------------------------------------------------------------
export KEYCLOAK_REALM="vault"            # Application realm name
export KEYCLOAK_ADMIN_USER="admin"       # Default admin user in vault realm
export KEYCLOAK_ADMIN_PASS="admin"       # Default admin password in vault realm

# OIDC Client IDs
export OIDC_CLIENT_VAULT="vault"
export OIDC_CLIENT_MINIO="minio"
export OIDC_CLIENT_JUPYTERHUB="jupyterhub"

# -----------------------------------------------------------------------------
# Vault Configuration
# -----------------------------------------------------------------------------
export VAULT_KEY_SHARES=1                # Number of key shares for unsealing
export VAULT_KEY_THRESHOLD=1             # Threshold for unsealing

# -----------------------------------------------------------------------------
# MinIO Configuration
# -----------------------------------------------------------------------------
export MINIO_TENANT_NAME="minio"
export MINIO_DEFAULT_BUCKET="default-bucket"

# -----------------------------------------------------------------------------
# Helm Repository URLs
# -----------------------------------------------------------------------------
export HELM_REPO_HASHICORP="https://helm.releases.hashicorp.com"
export HELM_REPO_MINIO="https://operator.min.io"
export HELM_REPO_JUPYTERHUB="https://jupyterhub.github.io/helm-chart"

# -----------------------------------------------------------------------------
# Feature Flags
# -----------------------------------------------------------------------------
export ENABLE_TLS="${ENABLE_TLS:-false}"           # Enable TLS for services
export ENABLE_INGRESS="${ENABLE_INGRESS:-false}"   # Create Ingress resources
export VERBOSE="${VERBOSE:-false}"                 # Verbose logging
