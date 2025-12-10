# Keycloak & Vault on Minikube

Complete setup for Keycloak (OIDC provider) and HashiCorp Vault with OIDC authentication on Minikube.

## Architecture

- **Keycloak Operator**: `operators` namespace
- **Keycloak Instance**: `operators` namespace (with PostgreSQL)
- **Vault**: `vault` namespace

## Prerequisites

- Minikube
- kubectl
- Helm
- jq
- curl

## Quick Start

### 1. Start Minikube

```bash
minikube start --cpus 4 --memory 8192
minikube addons enable ingress
```

### 2. Deploy Keycloak

```bash
# Create namespaces
kubectl create namespace operators
kubectl create namespace keycloak

# Apply Keycloak CRDs
kubectl apply -f k8s/keycloak-crd.yml
kubectl apply -f k8s/keycloak-realm-crd.yml

# Deploy Keycloak operator (in operators namespace)
kubectl apply -f k8s/keycloak-operator.yml

# Wait for operator
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=keycloak-operator -n operators --timeout=120s

# Deploy PostgreSQL and Keycloak
kubectl apply -f k8s/postgres.yaml
kubectl wait --for=condition=ready pod -l app=postgres -n operators --timeout=120s
kubectl apply -f k8s/keycloak.yaml
kubectl wait --for=condition=ready pod/keycloak-0 -n operators --timeout=180s
```

### 3. Access Keycloak UI

```bash
# Start port-forward (run in background or separate terminal)
kubectl port-forward -n operators svc/keycloak-service 8080:8080 --address=0.0.0.0 &
```

**Access**: http://localhost:8080

**Initial Credentials**:
```bash
# Username
kubectl get secret keycloak-initial-admin -n operators -o jsonpath='{.data.username}' | base64 -d

# Password
kubectl get secret keycloak-initial-admin -n operators -o jsonpath='{.data.password}' | base64 -d
```

**Important**: Create a permanent admin user immediately (see `KEYCLOAK_SETUP.md`)

### 4. Deploy Vault

```bash
# Create namespace
kubectl create namespace vault

# Deploy Vault via Helm
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update
helm install vault hashicorp/vault -n vault -f vault-values.yaml

# Wait for Vault pod
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=vault -n vault --timeout=120s

# Initialize and unseal Vault
kubectl exec -n vault vault-0 -- vault operator init -key-shares=1 -key-threshold=1 -format=json > vault-keys.json

# Unseal Vault
UNSEAL_KEY=$(cat vault-keys.json | jq -r '.unseal_keys_b64[0]')
kubectl exec -n vault vault-0 -- vault operator unseal $UNSEAL_KEY
```

**Save credentials**:
```bash
# Root token
cat vault-keys.json | jq -r '.root_token'

# Keep vault-keys.json secure!
```

### 5. Configure Keycloak for Vault

Run the automated configuration script:

```bash
./configure-keycloak-for-vault.sh
```

This creates:
- Vault realm in Keycloak
- OIDC client with client secret
- vault-admins group
- Admin user in vault realm

**Client secret** will be saved to `keycloak-vault-client-secret.txt`

### 6. Configure Vault OIDC

```bash
# Copy policy file to Vault pod
cat > /tmp/admin-policy.hcl <<'EOF'
path "*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}
EOF
kubectl cp /tmp/admin-policy.hcl vault/vault-0:/tmp/admin-policy.hcl

# Configure Vault
ROOT_TOKEN=$(cat vault-keys.json | jq -r '.root_token')
CLIENT_SECRET=$(cat keycloak-vault-client-secret.txt)

kubectl exec -n vault vault-0 -- vault login $ROOT_TOKEN
kubectl exec -n vault vault-0 -- vault write auth/oidc/config \
    oidc_discovery_url="http://keycloak-service.operators.svc.cluster.local:8080/realms/vault" \
    oidc_client_id="vault" \
    oidc_client_secret="$CLIENT_SECRET" \
    default_role="admin"

kubectl exec -n vault vault-0 -- vault policy write admin /tmp/admin-policy.hcl

kubectl exec -n vault vault-0 -- vault write auth/oidc/role/admin \
    bound_audiences="vault" \
    allowed_redirect_uris="http://localhost:8200/ui/vault/auth/oidc/oidc/callback" \
    allowed_redirect_uris="http://127.0.0.1:8200/ui/vault/auth/oidc/oidc/callback" \
    allowed_redirect_uris="http://localhost:8250/oidc/callback" \
    user_claim="sub" \
    groups_claim="groups" \
    policies="admin" \
    ttl="1h"

# Create group mapping
OIDC_ACCESSOR=$(kubectl exec -n vault vault-0 -- vault auth list -format=json | jq -r '.["oidc/"].accessor')
kubectl exec -n vault vault-0 -- vault write identity/group name="vault-admins" type="external" policies="admin"
GROUP_ID=$(kubectl exec -n vault vault-0 -- vault read -field=id identity/group/name/vault-admins)
kubectl exec -n vault vault-0 -- vault write identity/group-alias \
    name="vault-admins" \
    mount_accessor="$OIDC_ACCESSOR" \
    canonical_id="$GROUP_ID"
```

### 7. Access Vault UI (Windows)

#### A. Start Port-Forward

```bash
kubectl port-forward -n vault svc/vault-ui 8200:8200 --address=0.0.0.0 &
```

#### B. Configure Windows Hosts File

**Required for OIDC to work from Windows browser**

1. Open Notepad as Administrator
2. Open: `C:\Windows\System32\drivers\etc\hosts`
3. Add line: `127.0.0.1 keycloak-service.operators.svc.cluster.local`
4. Save and close

#### C. Login to Vault

1. Open browser: http://localhost:8200 or http://127.0.0.1:8200
2. Select Method: **OIDC**
3. Click "Sign in with OIDC Provider"
4. Login with Keycloak credentials (username: admin, password: admin)
5. You'll be redirected back to Vault with full admin access!

## Port-Forward Commands

**Keycloak**:
```bash
kubectl port-forward -n operators svc/keycloak-service 8080:8080 --address=0.0.0.0
```

**Vault**:
```bash
kubectl port-forward -n vault svc/vault-ui 8200:8200 --address=0.0.0.0
```

## Important Files

- `vault-keys.json` - Vault root token and unseal key (keep secure!)
- `keycloak-vault-client-secret.txt` - Keycloak OIDC client secret
- `KEYCLOAK_SETUP.md` - Detailed Keycloak configuration guide
- `VAULT_TEST.md` - Vault testing and verification guide
- `FIX_VAULT_DNS.md` - Windows hosts file configuration

## Troubleshooting

### Keycloak pod not starting
```bash
kubectl logs keycloak-0 -n operators
kubectl describe keycloak keycloak -n operators
```

### Vault sealed after restart
```bash
UNSEAL_KEY=$(cat vault-keys.json | jq -r '.unseal_keys_b64[0]')
kubectl exec -n vault vault-0 -- vault operator unseal $UNSEAL_KEY
```

### OIDC login fails
- Verify both port-forwards are running
- Check Windows hosts file has the entry
- Verify Keycloak client redirect URIs include both localhost and 127.0.0.1

## Clean Up

```bash
helm uninstall vault -n vault
kubectl delete namespace vault
kubectl delete keycloak keycloak -n operators
kubectl delete -f k8s/postgres.yaml
kubectl delete -f k8s/keycloak-operator.yml
kubectl delete namespace operators keycloak
```
