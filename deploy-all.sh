#!/bin/bash
# Complete deployment script for Keycloak and Vault on Minikube
set -e

echo "=== Keycloak & Vault Deployment Script ==="
echo ""

# Check prerequisites
command -v minikube >/dev/null 2>&1 || { echo "Error: minikube not found"; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo "Error: kubectl not found"; exit 1; }
command -v helm >/dev/null 2>&1 || { echo "Error: helm not found"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "Error: jq not found"; exit 1; }

echo "✓ Prerequisites check passed"
echo ""

# Step 1: Minikube
echo "Step 1: Starting Minikube..."
minikube start --cpus 4 --memory 8192
minikube addons enable ingress
echo "✓ Minikube ready"
echo ""

# Step 2: Deploy Keycloak
echo "Step 2: Deploying Keycloak..."
kubectl create namespace operators || true
kubectl create namespace keycloak || true

kubectl apply -f k8s/keycloak-crd.yml
kubectl apply -f k8s/keycloak-realm-crd.yml
kubectl apply -f k8s/keycloak-operator.yml

echo "Waiting for Keycloak operator..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=keycloak-operator -n operators --timeout=120s

kubectl apply -f k8s/postgres.yaml
echo "Waiting for PostgreSQL..."
kubectl wait --for=condition=ready pod -l app=postgres -n operators --timeout=120s

kubectl apply -f k8s/keycloak.yaml
echo "Waiting for Keycloak..."
kubectl wait --for=condition=ready pod/keycloak-0 -n operators --timeout=180s

echo "✓ Keycloak deployed"
echo ""

# Get Keycloak credentials
echo "Keycloak Admin Credentials:"
echo "Username: $(kubectl get secret keycloak-initial-admin -n operators -o jsonpath='{.data.username}' | base64 -d)"
echo "Password: $(kubectl get secret keycloak-initial-admin -n operators -o jsonpath='{.data.password}' | base64 -d)"
echo ""

# Step 3: Deploy Vault
echo "Step 3: Deploying Vault..."
kubectl create namespace vault || true

helm repo add hashicorp https://helm.releases.hashicorp.com >/dev/null 2>&1 || true
helm repo update >/dev/null

helm install vault hashicorp/vault -n vault -f vault-values.yaml

echo "Waiting for Vault..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=vault -n vault --timeout=120s

echo "Initializing Vault..."
kubectl exec -n vault vault-0 -- vault operator init -key-shares=1 -key-threshold=1 -format=json > vault-keys.json

UNSEAL_KEY=$(cat vault-keys.json | jq -r '.unseal_keys_b64[0]')
kubectl exec -n vault vault-0 -- vault operator unseal $UNSEAL_KEY >/dev/null

echo "✓ Vault deployed and unsealed"
echo ""

echo "Vault Root Token: $(cat vault-keys.json | jq -r '.root_token')"
echo ""

# Step 4: Configure Keycloak for Vault
echo "Step 4: Configuring Keycloak for Vault..."
echo "Starting Keycloak port-forward..."
kubectl port-forward -n operators svc/keycloak-service 8080:8080 --address=0.0.0.0 >/dev/null 2>&1 &
PF_KC_PID=$!
sleep 5

# Run Keycloak configuration
./configure-keycloak-for-vault.sh

CLIENT_SECRET=$(cat keycloak-vault-client-secret.txt)
echo "✓ Keycloak configured"
echo ""

# Step 5: Configure Vault OIDC
echo "Step 5: Configuring Vault OIDC..."
ROOT_TOKEN=$(cat vault-keys.json | jq -r '.root_token')

# Copy policy
cat > /tmp/admin-policy.hcl <<'EOF'
path "*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}
EOF
kubectl cp /tmp/admin-policy.hcl vault/vault-0:/tmp/admin-policy.hcl

# Configure OIDC
kubectl exec -n vault vault-0 -- vault login $ROOT_TOKEN >/dev/null
kubectl exec -n vault vault-0 -- vault write auth/oidc/config \
    oidc_discovery_url="http://keycloak-service.operators.svc.cluster.local:8080/realms/vault" \
    oidc_client_id="vault" \
    oidc_client_secret="$CLIENT_SECRET" \
    default_role="admin" >/dev/null

kubectl exec -n vault vault-0 -- vault policy write admin /tmp/admin-policy.hcl >/dev/null

kubectl exec -n vault vault-0 -- vault write auth/oidc/role/admin \
    bound_audiences="vault" \
    allowed_redirect_uris="http://localhost:8200/ui/vault/auth/oidc/oidc/callback" \
    allowed_redirect_uris="http://127.0.0.1:8200/ui/vault/auth/oidc/oidc/callback" \
    allowed_redirect_uris="http://localhost:8250/oidc/callback" \
    user_claim="sub" \
    groups_claim="groups" \
    policies="admin" \
    ttl="1h" >/dev/null

# Group mapping
OIDC_ACCESSOR=$(kubectl exec -n vault vault-0 -- vault auth list -format=json | jq -r '.["oidc/"].accessor')
kubectl exec -n vault vault-0 -- vault write identity/group name="vault-admins" type="external" policies="admin" >/dev/null
GROUP_ID=$(kubectl exec -n vault vault-0 -- vault read -field=id identity/group/name/vault-admins)
kubectl exec -n vault vault-0 -- vault write identity/group-alias \
    name="vault-admins" \
    mount_accessor="$OIDC_ACCESSOR" \
    canonical_id="$GROUP_ID" >/dev/null

echo "✓ Vault OIDC configured"
echo ""

# Stop Keycloak port-forward
kill $PF_KC_PID 2>/dev/null || true

echo "=== Deployment Complete! ==="
echo ""
echo "Next steps:"
echo "1. Add to Windows hosts file: 127.0.0.1 keycloak-service.operators.svc.cluster.local"
echo "2. Start port-forwards:"
echo "   kubectl port-forward -n operators svc/keycloak-service 8080:8080 --address=0.0.0.0"
echo "   kubectl port-forward -n vault svc/vault-ui 8200:8200 --address=0.0.0.0"
echo "3. Access Keycloak: http://localhost:8080"
echo "4. Access Vault: http://localhost:8200 (Method: OIDC)"
echo ""
echo "Credentials saved in:"
echo "- vault-keys.json (Vault root token and unseal key)"
echo "- keycloak-vault-client-secret.txt (Keycloak client secret)"
echo ""
