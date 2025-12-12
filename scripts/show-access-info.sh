#!/bin/bash

# Get directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "Retrieving credentials from Kubernetes..."

# 1. Keycloak Credentials
KC_USER=$(kubectl get secret keycloak-initial-admin -n operators -o jsonpath='{.data.username}' 2>/dev/null | base64 -d)
KC_PASS=$(kubectl get secret keycloak-initial-admin -n operators -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)

# 2. Vault Token
if [ -f "$PROJECT_ROOT/config/vault-keys.json" ]; then
    VAULT_TOKEN=$(jq -r '.root_token' "$PROJECT_ROOT/config/vault-keys.json")
else
    # Fallback to secret if it exists (some deployments might store it there)
    VAULT_TOKEN=$(kubectl get secret vault-init -n vault -o jsonpath='{.data.root-token}' 2>/dev/null | base64 -d)
    if [ -z "$VAULT_TOKEN" ]; then
        VAULT_TOKEN="<Not found in config/vault-keys.json>"
    fi
fi

# 3. MinIO Credentials
# Try fetching from the env configuration secret first
MINIO_CONFIG=$(kubectl get secret minio-env-configuration -n minio -o jsonpath='{.data.config\.env}' 2>/dev/null | base64 -d)
if [ -n "$MINIO_CONFIG" ]; then
    MINIO_USER=$(echo "$MINIO_CONFIG" | grep "MINIO_ROOT_USER" | cut -d'=' -f2 | tr -d '"')
    MINIO_PASS=$(echo "$MINIO_CONFIG" | grep "MINIO_ROOT_PASSWORD" | cut -d'=' -f2 | tr -d '"')
else
    MINIO_USER="<Not found>"
    MINIO_PASS="<Not found>"
fi

# Display Info
echo ""
echo "========================================="
echo "        PLATFORM ACCESS INFO"
echo "========================================="
echo ""
echo "🔐 Keycloak (Identity Provider)"
echo "   URL:      http://localhost:8080"
echo "   Admin:    $KC_USER"
echo "   Pass:     $KC_PASS"
echo "   Realms:   master (Admin), vault (Users)"
echo ""
echo "🔐 Vault (Secret Management)"
echo "   URL:      http://localhost:8200"
echo "   Token:    $VAULT_TOKEN"
echo "   Login:    Token method (admin), or OIDC (user: admin/admin)"
echo ""
echo "🪣 MinIO (Object Storage)"
echo "   Console:  https://localhost:9091"
echo "   User:     $MINIO_USER"
echo "   Pass:     $MINIO_PASS"
echo "   Login:    Click 'Login with OpenID' for OIDC"
echo ""
echo "📓 JupyterHub (Data Science)"
echo "   URL:      http://localhost:8000"
echo "   Login:    Sign in with Keycloak"
echo "   ---------------------------------"
echo "   Role:     Admin & Vault Admin"
echo "   User:     jupyter-admin"
echo "   Pass:     password123"
echo "   ---------------------------------"
echo "   Role:     Data Scientist (Large Profile)"
echo "   User:     jupyter-ds"
echo "   Pass:     password123"
echo ""
echo "========================================="
