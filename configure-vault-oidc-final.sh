#!/bin/bash
set -e

VAULT_POD="vault-0"
VAULT_NAMESPACE="vault"
ROOT_TOKEN=$(cat vault-keys.json | jq -r '.root_token')
KEYCLOAK_CLIENT_SECRET='5wSkDgU7HUlLQb18bNMqaMZz9kya0q4L'
KEYCLOAK_URL="http://keycloak-service.operators.svc.cluster.local:8080"
OIDC_DISCOVERY_URL="${KEYCLOAK_URL}/realms/vault"

echo "=== Vault OIDC Configuration (Continued) ==="
kubectl exec -n $VAULT_NAMESPACE $VAULT_POD -- vault login $ROOT_TOKEN > /dev/null

echo "Updating OIDC config..."
kubectl exec -n $VAULT_NAMESPACE $VAULT_POD -- vault write auth/oidc/config \
    oidc_discovery_url="$OIDC_DISCOVERY_URL" \
    oidc_client_id="vault" \
    oidc_client_secret="$KEYCLOAK_CLIENT_SECRET" \
    default_role="admin"

echo "Creating admin policy..."
kubectl exec -n $VAULT_NAMESPACE $VAULT_POD -- vault policy write admin /dev/stdin <<'POLICY'
path "*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}
POLICY

echo "Creating OIDC role..."
kubectl exec -n $VAULT_NAMESPACE $VAULT_POD -- vault write auth/oidc/role/admin \
    bound_audiences="vault" \
    allowed_redirect_uris="http://localhost:8200/ui/vault/auth/oidc/oidc/callback" \
    allowed_redirect_uris="http://localhost:8250/oidc/callback" \
    user_claim="sub" \
    groups_claim="groups" \
    policies="admin" \
    ttl="1h"

echo "Creating group mapping..."
OIDC_ACCESSOR=$(kubectl exec -n $VAULT_NAMESPACE $VAULT_POD -- vault auth list -format=json | jq -r '.["oidc/"].accessor')

kubectl exec -n $VAULT_NAMESPACE $VAULT_POD -- vault write identity/group name="vault-admins" \
    type="external" \
    policies="admin" || true

GROUP_ID=$(kubectl exec -n $VAULT_NAMESPACE $VAULT_POD -- vault read -field=id identity/group/name/vault-admins)

kubectl exec -n $VAULT_NAMESPACE $VAULT_POD -- vault write identity/group-alias \
    name="vault-admins" \
    mount_accessor="$OIDC_ACCESSOR" \
    canonical_id="$GROUP_ID" || true

echo ""
echo "=== Configuration Complete! ==="
