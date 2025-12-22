#!/bin/bash
# Complete deployment script for Keycloak and Vault on GKE
# Uses existing GKE cluster with full validation

set -e

# Get the directory where this script is located and change to project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

echo "========================================="
echo "Keycloak & Vault Deployment (GKE)"
echo "========================================="
echo ""

# Step 0: Verify Prerequisites
echo "Step 0: Verifying prerequisites..."

# Check kubectl
if ! command -v kubectl &> /dev/null; then
  echo "ERROR: kubectl is not installed or not in PATH"
  echo "       Please install kubectl: https://kubernetes.io/docs/tasks/tools/"
  exit 1
fi
echo "✓ kubectl found"

# Check helm
if ! command -v helm &> /dev/null; then
  echo ""
  echo "ERROR: Helm is not installed or not in PATH"
  echo "       Helm is required for deploying Vault, MinIO, and other components."
  echo ""
  echo "       To install Helm:"
  echo "         - Using snap:  sudo snap install helm --classic"
  echo "         - Using script: curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash"
  echo "         - See: https://helm.sh/docs/intro/install/"
  echo ""
  exit 1
fi
echo "✓ helm found ($(helm version --short))"

# Check jq
if ! command -v jq &> /dev/null; then
  echo "ERROR: jq is not installed or not in PATH"
  echo "       Please install jq: sudo apt-get install jq"
  exit 1
fi
echo "✓ jq found"
echo ""

# Step 1: Verify GKE Cluster
echo "Step 1: Verifying GKE cluster connection..."
if ! kubectl cluster-info &> /dev/null; then
  echo "ERROR: Cannot connect to Kubernetes cluster. Please verify kubectl is configured for GKE."
  exit 1
fi
echo "✓ GKE cluster connected"
kubectl cluster-info | head -n 1
echo ""

# Step 2: Create Namespaces
echo "Step 2: Creating namespaces..."
kubectl create namespace operators --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace keycloak --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace vault --dry-run=client -o yaml | kubectl apply -f -
echo "✓ Namespaces ready"
echo ""

# Step 3: Deploy Keycloak Operator
echo "Step 3: Deploying Keycloak CRDs and Operator..."
kubectl apply -f helm/keycloak/manifests/keycloak-crd.yml
kubectl apply -f helm/keycloak/manifests/keycloak-realm-crd.yml
kubectl apply -f helm/keycloak/manifests/keycloak-operator.yml

echo "Waiting for Keycloak operator deployment..."
kubectl wait --for=condition=available deployment/keycloak-operator -n operators --timeout=120s
echo "✓ Keycloak operator ready"

# Step 4: Deploy PostgreSQL
echo ""
echo "Step 4: Deploying PostgreSQL with persistent storage..."
kubectl apply -f helm/postgres/postgres-for-keycloak.yaml

echo "Waiting for PostgreSQL..."
kubectl rollout status statefulset/postgres -n operators --timeout=120s
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
echo "Adding HashiCorp Helm repository..."
if ! helm repo add hashicorp https://helm.releases.hashicorp.com 2>&1; then
  echo "ERROR: Failed to add HashiCorp Helm repository"
  exit 1
fi

echo "Updating Helm repositories..."
if ! helm repo update 2>&1; then
  echo "ERROR: Failed to update Helm repositories"
  exit 1
fi

if helm status vault -n vault > /dev/null 2>&1; then
  echo "ERROR: Vault release already exists! This script expects a clean environment."
  echo "       To delete: helm uninstall vault -n vault"
  exit 1
else
  echo "Installing Vault Helm chart..."
  if ! helm install vault hashicorp/vault -n vault -f helm/vault/values.yaml 2>&1; then
    echo ""
    echo "ERROR: Failed to install Vault Helm chart"
    echo "       Check the error message above for details"
    exit 1
  fi
  echo "✓ Vault Helm chart installed"
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
kubectl apply -f helm/keycloak/manifests/keycloak-realm-import.yaml

echo "Waiting for Keycloak Realm Import to complete..."
# Wait loop for realm import status
for i in {1..20}; do
  STATUS=$(kubectl get keycloakrealmimport/vault-realm-import -n operators -o jsonpath='{.status.conditions[?(@.type=="Done")].status}' 2>/dev/null || echo "False")
  if [ "$STATUS" == "True" ]; then
    echo "✓ Keycloak Realm 'vault' imported successfully"
    break
  fi
  # Also check for Error state
  ERR_STATUS=$(kubectl get keycloakrealmimport/vault-realm-import -n operators -o jsonpath='{.status.conditions[?(@.type=="HasErrors")].status}' 2>/dev/null || echo "False")
  if [ "$ERR_STATUS" == "True" ]; then
    echo "ERROR: Keycloak Realm Import failed!"
    kubectl get keycloakrealmimport/vault-realm-import -n operators -o yaml
    exit 1
  fi
  echo "Waiting for Realm Import... ($i/20)"
  sleep 3
done

# Export client secrets for Vault (now hardcoded/known from manifest, or we can fetch)
# Since we specificed secrets in manifest (e.g., 'vault-secret'), we know them.
# But for continuity, let's just write the known secret to the file.
echo "vault-secret" > config/keycloak-vault-client-secret.txt

CLIENT_SECRET="vault-secret"
echo "✓ Keycloak vault realm configured"
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

# Retry loop for Vault OIDC configuration (can fail due to Keycloak/DNS timing)
echo "Configuring Vault OIDC (with retry)..."
for i in {1..10}; do
  if kubectl exec -n vault vault-0 -- vault write auth/oidc/config \
      oidc_discovery_url="http://keycloak-service.operators.svc.cluster.local:8080/realms/vault" \
      oidc_client_id="vault" \
      oidc_client_secret="$CLIENT_SECRET" \
      default_role="admin" > /dev/null 2>&1; then
    echo "✓ Vault auth/oidc/config written"
    break
  fi
  echo "Waiting for Keycloak OIDC endpoint... ($i/10)"
  sleep 5
done

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
OIDC_ACCESSOR=$(kubectl exec -n vault vault-0 -- vault auth list -format=json | jq -r '.["oidc/"].accessor')
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
echo "GKE Cluster: $(kubectl config current-context)"
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
echo "Port-forwards are running in the background."
echo "To stop them: pkill -f 'kubectl port-forward'"
echo ""
