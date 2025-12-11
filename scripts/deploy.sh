#!/bin/bash
# Complete deployment script for Keycloak and Vault on Minikube
# Uses profile-based deployment with full validation

set -e

# Get the directory where this script is located and change to project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

PROFILE="${MINIKUBE_PROFILE:-keycloak-vault}"

echo "========================================="
echo "Keycloak & Vault Deployment"
echo "Profile: $PROFILE"
echo "========================================="
echo ""

# Step 1: Start Minikube
echo "Step 1: Starting Minikube..."
minikube start -p $PROFILE --cpus 4 --memory 8192
minikube addons enable ingress -p $PROFILE
minikube profile $PROFILE
echo "✓ Minikube started"
echo ""

# Step 2: Create Namespaces
echo "Step 2: Creating namespaces..."
kubectl create namespace operators --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace keycloak --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace vault --dry-run=client -o yaml | kubectl apply -f -
echo "✓ Namespaces ready"
echo ""

# Step 3: Deploy Keycloak
echo "Step 3: Deploying Keycloak..."
kubectl apply -f helm/keycloak/manifests/keycloak-crd.yml
kubectl apply -f helm/keycloak/manifests/keycloak-realm-crd.yml
kubectl apply -f helm/keycloak/manifests/keycloak-operator.yml

echo "Waiting for Keycloak operator..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=keycloak-operator -n operators --timeout=120s
echo "✓ Keycloak operator ready"

# Step 4: Deploy PostgreSQL
echo ""
echo "Step 4: Deploying PostgreSQL with persistent storage..."
kubectl apply -f helm/postgres/postgres-for-keycloak.yaml

echo "Waiting for PostgreSQL..."
kubectl wait --for=condition=ready pod -l app=postgres -n operators --timeout=120s
echo "✓ PostgreSQL ready (2Gi persistent storage)"

# Step 5: Deploy Keycloak Instance
echo ""
echo "Step 5: Deploying Keycloak instance..."
kubectl apply -f helm/keycloak/manifests/keycloak-instance.yaml

echo "Waiting for Keycloak pod to be created..."
# Wait up to 60 seconds for the pod to appear
for i in {1..30}; do
  if kubectl get pod keycloak-0 -n operators > /dev/null 2>&1; then
    echo "✓ Keycloak pod created"
    break
  fi
  if [ $i -eq 30 ]; then
    echo "ERROR: Timed out waiting for Keycloak pod to be created"
    exit 1
  fi
  echo "Waiting for operator to create keycloak-0 pod... ($i/30)"
  sleep 2
done

echo "Waiting for Keycloak to be ready (this takes about 2-3 minutes)..."
kubectl wait --for=condition=ready pod/keycloak-0 -n operators --timeout=300s
echo "✓ Keycloak ready"

# Get Keycloak credentials
KEYCLOAK_USER=$(kubectl get secret keycloak-initial-admin -n operators -o jsonpath='{.data.username}' | base64 -d)
KEYCLOAK_PASS=$(kubectl get secret keycloak-initial-admin -n operators -o jsonpath='{.data.password}' | base64 -d)

echo ""
echo "Keycloak Master Realm Credentials:"
echo "  Username: $KEYCLOAK_USER"
echo "  Password: $KEYCLOAK_PASS"
echo ""

# Step 6: Deploy Vault
echo "Step 6: Deploying Vault..."
helm repo add hashicorp https://helm.releases.hashicorp.com > /dev/null 2>&1 || true
helm repo update > /dev/null 2>&1
if helm status vault -n vault > /dev/null 2>&1; then
  echo "ERROR: Vault release already exists! This script expects a clean environment."
  echo "       To delete: helm uninstall vault -n vault"
  exit 1
else
  helm install vault hashicorp/vault -n vault -f helm/vault/values.yaml
fi

echo "Waiting for Vault pod to start..."
sleep 10

# Validate Vault pod is running
until kubectl get pod vault-0 -n vault 2>/dev/null | grep -q "Running"; do
  echo "Waiting for Vault pod..."
  sleep 5
done
echo "✓ Vault pod running"

# Step 7: Initialize Vault
echo ""
echo "Step 7: Initializing Vault..."
sleep 5
# Check actual Vault status
VAULT_INIT_STATUS=$(kubectl exec -n vault vault-0 -- vault status -format=json 2>/dev/null | jq -r .initialized)

if [ "$VAULT_INIT_STATUS" == "false" ]; then
  echo "Vault is not initialized. Initializing now..."
  kubectl exec -n vault vault-0 -- vault operator init -key-shares=1 -key-threshold=1 -format=json > config/vault-keys.json
  echo "✓ Vault initialized"
else
  echo "Vault is already initialized."
  if [ ! -f config/vault-keys.json ]; then
    echo "WARNING: Vault is initialized but config/vault-keys.json is missing!"
    echo "         You will need the original keys to unseal."
  fi
fi

# Step 8: Unseal Vault
echo ""
echo "Step 8: Unsealing Vault..."
VAULT_STATUS=$(kubectl exec -n vault vault-0 -- vault status -format=json 2>/dev/null | jq -r .sealed)
if [ "$VAULT_STATUS" == "true" ]; then
  UNSEAL_KEY=$(cat config/vault-keys.json | jq -r '.unseal_keys_b64[0]')
  kubectl exec -n vault vault-0 -- vault operator unseal $UNSEAL_KEY > /dev/null
  echo "✓ Vault unsealed"
else
  echo "Vault already unsealed."
fi

ROOT_TOKEN=$(cat config/vault-keys.json | jq -r '.root_token')
echo "Vault Root Token: $ROOT_TOKEN"
echo ""

# Step 9: Start Port-Forwards
echo "Step 9: Starting port-forwards..."
kubectl port-forward -n operators svc/keycloak-service 8080:8080 --address=0.0.0.0 > /dev/null 2>&1 &
KEYCLOAK_PF_PID=$!
sleep 3
echo "✓ Keycloak port-forward started (PID: $KEYCLOAK_PF_PID)"

kubectl port-forward -n vault svc/vault-ui 8200:8200 --address=0.0.0.0 > /dev/null 2>&1 &
VAULT_PF_PID=$!
sleep 2
echo "✓ Vault port-forward started (PID: $VAULT_PF_PID)"
echo ""

# Step 10: Configure Keycloak for Vault
echo "Step 10: Configuring Keycloak vault realm..."
sleep 2

TOKEN_RESPONSE=$(curl -s -X POST "http://localhost:8080/realms/master/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "username=$KEYCLOAK_USER" \
  -d "password=$KEYCLOAK_PASS" \
  -d "grant_type=password" \
  -d "client_id=admin-cli")

ACCESS_TOKEN=$(echo $TOKEN_RESPONSE | jq -r ".access_token")

if [ "$ACCESS_TOKEN" == "null" ] || [ -z "$ACCESS_TOKEN" ]; then
  echo "ERROR: Failed to authenticate with Keycloak"
  exit 1
fi

# Create vault realm
curl -s -X POST "http://localhost:8080/admin/realms" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"realm": "vault", "enabled": true, "displayName": "Vault"}' > /dev/null

# Create OIDC client
curl -s -X POST "http://localhost:8080/admin/realms/vault/clients" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"clientId": "vault", "name": "HashiCorp Vault", "enabled": true, "protocol": "openid-connect", "publicClient": false, "directAccessGrantsEnabled": true, "standardFlowEnabled": true, "redirectUris": ["http://localhost:8200/ui/vault/auth/oidc/oidc/callback", "http://127.0.0.1:8200/ui/vault/auth/oidc/oidc/callback", "http://localhost:8250/oidc/callback"], "webOrigins": ["+"]}' > /dev/null

CLIENT_UUID=$(curl -s -X GET "http://localhost:8080/admin/realms/vault/clients?clientId=vault" \
  -H "Authorization: Bearer $ACCESS_TOKEN" | jq -r '.[0].id')

CLIENT_SECRET=$(curl -s -X GET "http://localhost:8080/admin/realms/vault/clients/$CLIENT_UUID/client-secret" \
  -H "Authorization: Bearer $ACCESS_TOKEN" | jq -r '.value')

echo "$CLIENT_SECRET" > config/keycloak-vault-client-secret.txt

# Create vault-admins group
curl -s -X POST "http://localhost:8080/admin/realms/vault/groups" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name": "vault-admins"}' > /dev/null

GROUP_ID=$(curl -s -X GET "http://localhost:8080/admin/realms/vault/groups?search=vault-admins" \
  -H "Authorization: Bearer $ACCESS_TOKEN" | jq -r '.[0].id')

# Create admin user
curl -s -X POST "http://localhost:8080/admin/realms/vault/users" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"username": "admin", "email": "admin@vault.local", "enabled": true, "emailVerified": true}' > /dev/null

USER_ID=$(curl -s -X GET "http://localhost:8080/admin/realms/vault/users?username=admin" \
  -H "Authorization: Bearer $ACCESS_TOKEN" | jq -r '.[0].id')

# Set password
curl -s -X PUT "http://localhost:8080/admin/realms/vault/users/$USER_ID/reset-password" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"type": "password", "value": "admin", "temporary": false}' > /dev/null

# Add user to group
curl -s -X PUT "http://localhost:8080/admin/realms/vault/users/$USER_ID/groups/$GROUP_ID" \
  -H "Authorization: Bearer $ACCESS_TOKEN" > /dev/null

# Add group mapper
curl -s -X POST "http://localhost:8080/admin/realms/vault/clients/$CLIENT_UUID/protocol-mappers/models" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name": "groups", "protocol": "openid-connect", "protocolMapper": "oidc-group-membership-mapper", "config": {"full.path": "false", "id.token.claim": "true", "access.token.claim": "true", "claim.name": "groups", "userinfo.token.claim": "true"}}' > /dev/null

echo "✓ Keycloak vault realm configured"
echo "  - Realm: vault"
echo "  - OIDC Client: vault"
echo "  - Client Secret: $CLIENT_SECRET"
echo "  - Group: vault-admins"
echo "  - User: admin / admin"
echo ""

# Step 11: Configure Vault OIDC
echo "Step 11: Configuring Vault OIDC authentication..."

# Create admin policy
cat > /tmp/admin-policy.hcl <<'EOF'
path "*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}
EOF
kubectl cp /tmp/admin-policy.hcl vault/vault-0:/tmp/admin-policy.hcl

kubectl exec -n vault vault-0 -- vault login $ROOT_TOKEN > /dev/null

kubectl exec -n vault vault-0 -- vault auth enable oidc > /dev/null 2>&1 || true

kubectl exec -n vault vault-0 -- vault write auth/oidc/config \
    oidc_discovery_url="http://keycloak-service.operators.svc.cluster.local:8080/realms/vault" \
    oidc_client_id="vault" \
    oidc_client_secret="$CLIENT_SECRET" \
    default_role="admin" > /dev/null

kubectl exec -n vault vault-0 -- vault policy write admin /tmp/admin-policy.hcl > /dev/null

kubectl exec -n vault vault-0 -- vault write auth/oidc/role/admin \
    bound_audiences="vault" \
    allowed_redirect_uris="http://localhost:8200/ui/vault/auth/oidc/oidc/callback" \
    allowed_redirect_uris="http://127.0.0.1:8200/ui/vault/auth/oidc/oidc/callback" \
    allowed_redirect_uris="http://localhost:8250/oidc/callback" \
    user_claim="sub" \
    groups_claim="groups" \
    policies="admin" \
    ttl="1h" > /dev/null

# Create group mapping
OIDC_ACCESSOR=$(kubectl exec -n vault vault-0 -- vault auth list -format=json | jq -r '."oidc/".accessor')
kubectl exec -n vault vault-0 -- vault write identity/group name="vault-admins" type="external" policies="admin" > /dev/null
GROUP_ID=$(kubectl exec -n vault vault-0 -- vault read -field=id identity/group/name/vault-admins)
kubectl exec -n vault vault-0 -- vault write identity/group-alias \
    name="vault-admins" \
    mount_accessor="$OIDC_ACCESSOR" \
    canonical_id="$GROUP_ID" > /dev/null

echo "✓ Vault OIDC configured"
echo ""

# Step 12: Verify Persistent Storage
echo "Step 12: Verifying persistent storage..."
kubectl get pvc -n operators | grep postgres
kubectl get pvc -n vault | grep vault
echo "✓ Persistent volumes configured"
echo ""

# Summary
echo "========================================="
echo "Deployment Complete!"
echo "========================================="
echo ""
echo "Minikube Profile: $PROFILE"
echo ""
echo "Keycloak UI: http://localhost:8080"
echo "  Master Realm:"
echo "    Username: $KEYCLOAK_USER"
echo "    Password: $KEYCLOAK_PASS"
echo "  Vault Realm:"
echo "    Username: admin"
echo "    Password: admin"
echo ""
echo "Vault UI: http://localhost:8200"
echo "  Root Token: $ROOT_TOKEN"
echo "  OIDC Login: Method=OIDC, Role=admin, then login with admin/admin"
echo ""
echo "Credentials saved to:"
echo "  - config/vault-keys.json (root token and unseal key)"
echo "  - config/keycloak-vault-client-secret.txt (OIDC client secret)"
echo ""
echo "Persistent Storage:"
echo "  - PostgreSQL: 2Gi (Keycloak data persists)"
echo "  - Vault: 1Gi (Vault secrets persist)"
echo ""
echo "To restart after 'minikube stop':"
echo "  ./restart.sh"
echo ""
echo "To switch to this profile:"
echo "  minikube profile $PROFILE"
echo ""
