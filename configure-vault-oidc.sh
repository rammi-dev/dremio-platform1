#!/bin/bash
set -e

# Vault OIDC Configuration Script
# This script configures Vault to use Keycloak OIDC for authentication

echo "=== Vault OIDC Configuration ==="
echo ""

# Check if client secret is provided
if [ -z "$KEYCLOAK_CLIENT_SECRET" ]; then
    echo "ERROR: KEYCLOAK_CLIENT_SECRET environment variable is not set"
    echo "Please set it with: export KEYCLOAK_CLIENT_SECRET='<your-client-secret>'"
    exit 1
fi

# Vault configuration
VAULT_POD="vault-0"
VAULT_NAMESPACE="vault"
ROOT_TOKEN=$(cat vault-keys.json | jq -r '.root_token')

# Keycloak configuration
KEYCLOAK_URL="http://keycloak-service.operators.svc.cluster.local:8080"
OIDC_DISCOVERY_URL="${KEYCLOAK_URL}/realms/vault"

echo "Step 1: Enabling OIDC auth method..."
kubectl exec -n $VAULT_NAMESPACE $VAULT_POD -- vault login $ROOT_TOKEN > /dev/null
kubectl exec -n $VAULT_NAMESPACE $VAULT_POD -- vault auth enable oidc

echo "Step 2: Configuring OIDC auth method..."
kubectl exec -n $VAULT_NAMESPACE $VAULT_POD -- vault write auth/oidc/config \
    oidc_discovery_url="$OIDC_DISCOVERY_URL" \
    oidc_client_id="vault" \
    oidc_client_secret="$KEYCLOAK_CLIENT_SECRET" \
    default_role="admin"

echo "Step 3: Creating admin policy..."
kubectl exec -n $VAULT_NAMESPACE $VAULT_POD -- sh -c "vault policy write admin - <<'EOF'
# Full admin access
path \"*\" {
  capabilities = [\"create\", \"read\", \"update\", \"delete\", \"list\", \"sudo\"]
}
EOF"

echo "Step 4: Creating OIDC role for admins..."
kubectl exec -n $VAULT_NAMESPACE $VAULT_POD -- vault write auth/oidc/role/admin \
    bound_audiences="vault" \
    allowed_redirect_uris="http://localhost:8200/ui/vault/auth/oidc/oidc/callback" \
    allowed_redirect_uris="http://localhost:8250/oidc/callback" \
    user_claim="sub" \
    groups_claim="groups" \
    policies="admin" \
    ttl="1h"

echo "Step 5: Creating group mapping for vault-admins..."
# Get the OIDC accessor
OIDC_ACCESSOR=$(kubectl exec -n $VAULT_NAMESPACE $VAULT_POD -- vault auth list -format=json | jq -r '.["oidc/"].accessor')

# Create external group for vault-admins
kubectl exec -n $VAULT_NAMESPACE $VAULT_POD -- vault write identity/group name="vault-admins" \
    type="external" \
    policies="admin"

# Get the group ID
GROUP_ID=$(kubectl exec -n $VAULT_NAMESPACE $VAULT_POD -- vault read -field=id identity/group/name/vault-admins)

# Create group alias
kubectl exec -n $VAULT_NAMESPACE $VAULT_POD -- vault write identity/group-alias \
    name="vault-admins" \
    mount_accessor="$OIDC_ACCESSOR" \
    canonical_id="$GROUP_ID"

echo ""
echo "=== Configuration Complete! ==="
echo ""
echo "Vault OIDC authentication is now configured."
echo ""
echo "To test:"
echo "1. Port-forward Vault UI: kubectl port-forward -n vault svc/vault-ui 8200:8200 --address=0.0.0.0"
echo "2. Open browser: http://localhost:8200"
echo "3. Select 'OIDC' method"
echo "4. Click 'Sign in with OIDC Provider'"
echo "5. Log in with your Keycloak admin credentials"
echo ""
