# Keycloak & Vault Setup Guide

This guide will walk you through setting up Keycloak and HashiCorp Vault on Minikube with OIDC integration.

## ✅ Prerequisites (Completed)

All prerequisites are installed and ready:
- ✅ Minikube
- ✅ kubectl
- ✅ Helm
- ✅ jq
- ✅ Old Minikube cluster deleted

---

## 📋 Setup Steps

### Step 1: Start Minikube

Start Minikube with sufficient resources:

```bash
minikube start --cpus 4 --memory 8192
minikube addons enable ingress
```

**Expected**: Minikube cluster starts successfully with ingress addon enabled.

---

### Step 2: Deploy Keycloak

#### 2.1 Create Namespaces

```bash
kubectl create namespace operators
kubectl create namespace keycloak
```

#### 2.2 Apply Keycloak CRDs

```bash
kubectl apply -f k8s/keycloak-crd.yml
kubectl apply -f k8s/keycloak-realm-crd.yml
```

#### 2.3 Deploy Keycloak Operator

```bash
kubectl apply -f k8s/keycloak-operator.yml
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=keycloak-operator -n operators --timeout=120s
```

#### 2.4 Deploy PostgreSQL

```bash
kubectl apply -f k8s/postgres.yaml
kubectl wait --for=condition=ready pod -l app=postgres -n operators --timeout=120s
```

> [!NOTE]
> PostgreSQL is deployed as a StatefulSet with 2Gi persistent storage to ensure all Keycloak data (realms, users, clients) survives restarts.

#### 2.5 Deploy Keycloak Instance

```bash
kubectl apply -f k8s/keycloak.yaml
kubectl wait --for=condition=ready pod/keycloak-0 -n operators --timeout=180s
```

---

### Step 3: Get Keycloak Credentials

Retrieve the initial admin credentials:

```bash
# Username
kubectl get secret keycloak-initial-admin -n operators -o jsonpath='{.data.username}' | base64 -d
echo

# Password
kubectl get secret keycloak-initial-admin -n operators -o jsonpath='{.data.password}' | base64 -d
echo
```

**Save these credentials!** You'll need them to access Keycloak.

---

### Step 4: Deploy Vault

#### 4.1 Create Vault Namespace

```bash
kubectl create namespace vault
```

#### 4.2 Add HashiCorp Helm Repository

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update
```

#### 4.3 Install Vault

```bash
helm install vault hashicorp/vault -n vault -f vault-values.yaml
```

> [!NOTE]
> **Do NOT wait for the Vault pod to be ready.** Vault starts in a sealed/uninitialized state and won't pass readiness checks until it's initialized and unsealed (next steps).

#### 4.4 Initialize Vault

```bash
kubectl exec -n vault vault-0 -- vault operator init -key-shares=1 -key-threshold=1 -format=json > vault-keys.json
```

#### 4.5 Unseal Vault

```bash
UNSEAL_KEY=$(cat vault-keys.json | jq -r '.unseal_keys_b64[0]')
kubectl exec -n vault vault-0 -- vault operator unseal $UNSEAL_KEY
```

**Important**: The `vault-keys.json` file contains your root token and unseal key. Keep it secure!

---

### Step 5: Configure Keycloak for Vault

#### 5.1 Start Keycloak Port-Forward

First, start the port-forward to access Keycloak (run in background or separate terminal):

```bash
kubectl port-forward -n operators svc/keycloak-service 8080:8080 --address=0.0.0.0 &
```

#### 5.2 Get Keycloak Admin Credentials

```bash
# Username
kubectl get secret keycloak-initial-admin -n operators -o jsonpath='{.data.username}' | base64 -d
echo

# Password
kubectl get secret keycloak-initial-admin -n operators -o jsonpath='{.data.password}' | base64 -d
echo
```

Save these credentials - you'll need them for the next step.

#### 5.3 Configure Keycloak via API

Replace `ADMIN_USER` and `ADMIN_PASS` with the credentials from above:

```bash
ADMIN_USER="temp-admin"  # Replace with actual username
ADMIN_PASS="your-password-here"  # Replace with actual password
KEYCLOAK_URL="http://localhost:8080"

# Get admin access token
TOKEN_RESPONSE=$(curl -s -X POST "$KEYCLOAK_URL/realms/master/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "username=$ADMIN_USER" \
  -d "password=$ADMIN_PASS" \
  -d "grant_type=password" \
  -d "client_id=admin-cli")

ACCESS_TOKEN=$(echo $TOKEN_RESPONSE | jq -r ".access_token")

# Create vault realm
curl -s -X POST "$KEYCLOAK_URL/admin/realms" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"realm": "vault", "enabled": true, "displayName": "Vault"}'

# Create vault OIDC client
curl -s -X POST "$KEYCLOAK_URL/admin/realms/vault/clients" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"clientId": "vault", "name": "HashiCorp Vault", "enabled": true, "protocol": "openid-connect", "publicClient": false, "directAccessGrantsEnabled": true, "standardFlowEnabled": true, "redirectUris": ["http://localhost:8200/ui/vault/auth/oidc/oidc/callback", "http://127.0.0.1:8200/ui/vault/auth/oidc/oidc/callback", "http://localhost:8250/oidc/callback"], "webOrigins": ["+"]}'

# Get client UUID and secret
CLIENT_UUID=$(curl -s -X GET "$KEYCLOAK_URL/admin/realms/vault/clients?clientId=vault" \
  -H "Authorization: Bearer $ACCESS_TOKEN" | jq -r '.[0].id')

CLIENT_SECRET=$(curl -s -X GET "$KEYCLOAK_URL/admin/realms/vault/clients/$CLIENT_UUID/client-secret" \
  -H "Authorization: Bearer $ACCESS_TOKEN" | jq -r '.value')

echo "$CLIENT_SECRET" > keycloak-vault-client-secret.txt
echo "Client secret saved: $CLIENT_SECRET"

# Create vault-admins group
curl -s -X POST "$KEYCLOAK_URL/admin/realms/vault/groups" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name": "vault-admins"}'

GROUP_ID=$(curl -s -X GET "$KEYCLOAK_URL/admin/realms/vault/groups?search=vault-admins" \
  -H "Authorization: Bearer $ACCESS_TOKEN" | jq -r '.[0].id')

# Create admin user in vault realm
curl -s -X POST "$KEYCLOAK_URL/admin/realms/vault/users" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"username": "admin", "email": "admin@vault.local", "enabled": true, "emailVerified": true}'

USER_ID=$(curl -s -X GET "$KEYCLOAK_URL/admin/realms/vault/users?username=admin" \
  -H "Authorization: Bearer $ACCESS_TOKEN" | jq -r '.[0].id')

# Set password for admin user (password: admin)
curl -s -X PUT "$KEYCLOAK_URL/admin/realms/vault/users/$USER_ID/reset-password" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"type": "password", "value": "admin", "temporary": false}'

# Add user to vault-admins group
curl -s -X PUT "$KEYCLOAK_URL/admin/realms/vault/users/$USER_ID/groups/$GROUP_ID" \
  -H "Authorization: Bearer $ACCESS_TOKEN"

# Configure group claim mapper
curl -s -X POST "$KEYCLOAK_URL/admin/realms/vault/clients/$CLIENT_UUID/protocol-mappers/models" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name": "groups", "protocol": "openid-connect", "protocolMapper": "oidc-group-membership-mapper", "config": {"full.path": "false", "id.token.claim": "true", "access.token.claim": "true", "claim.name": "groups", "userinfo.token.claim": "true"}}'

echo "✓ Keycloak configuration complete!"
```

**What was created:**
- Vault realm in Keycloak
- OIDC client "vault" with client secret (saved to `keycloak-vault-client-secret.txt`)
- vault-admins group
- Admin user (username: `admin`, password: `admin`) in vault realm

---

### Step 6: Configure Vault OIDC Authentication

#### 6.1 Copy Admin Policy to Vault Pod

```bash
cat > /tmp/admin-policy.hcl <<'EOF'
path "*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}
EOF
kubectl cp /tmp/admin-policy.hcl vault/vault-0:/tmp/admin-policy.hcl
```

#### 6.2 Configure OIDC in Vault

```bash
ROOT_TOKEN=$(cat vault-keys.json | jq -r '.root_token')
CLIENT_SECRET=$(cat keycloak-vault-client-secret.txt)

kubectl exec -n vault vault-0 -- vault login $ROOT_TOKEN

kubectl exec -n vault vault-0 -- vault auth enable oidc

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
```

#### 6.3 Create Group Mapping

```bash
OIDC_ACCESSOR=$(kubectl exec -n vault vault-0 -- vault auth list -format=json | jq -r '."oidc/".accessor')
kubectl exec -n vault vault-0 -- vault write identity/group name="vault-admins" type="external" policies="admin"
GROUP_ID=$(kubectl exec -n vault vault-0 -- vault read -field=id identity/group/name/vault-admins)
kubectl exec -n vault vault-0 -- vault write identity/group-alias \
    name="vault-admins" \
    mount_accessor="$OIDC_ACCESSOR" \
    canonical_id="$GROUP_ID"
```

---

### Step 7: Access the UIs

#### 7.1 Start Port-Forwards

Open two terminal windows and run:

**Terminal 1 - Keycloak:**
```bash
kubectl port-forward -n operators svc/keycloak-service 8080:8080 --address=0.0.0.0
```

**Terminal 2 - Vault:**
```bash
kubectl port-forward -n vault svc/vault-ui 8200:8200 --address=0.0.0.0
```

#### 7.2 Access Keycloak

- **URL**: http://localhost:8080
- **Username**: (from Step 3)
- **Password**: (from Step 3)

#### 7.3 Access Vault

- **URL**: http://localhost:8200
- **Method**: Select "OIDC"
- **Login**: Click "Sign in with OIDC Provider"
- You'll be redirected to Keycloak to authenticate

---

## 🎯 Quick Reference

### Important Files
- `vault-keys.json` - Vault root token and unseal key (KEEP SECURE!)
- `keycloak-vault-client-secret.txt` - OIDC client secret

### Useful Commands

**Check pod status:**
```bash
kubectl get pods -n operators
kubectl get pods -n vault
```

**View logs:**
```bash
kubectl logs keycloak-0 -n operators
kubectl logs vault-0 -n vault
```

**Unseal Vault (after restart):**
```bash
UNSEAL_KEY=$(cat vault-keys.json | jq -r '.unseal_keys_b64[0]')
kubectl exec -n vault vault-0 -- vault operator unseal $UNSEAL_KEY
```

---

## 🚀 Alternative: One-Command Deployment

Instead of manual steps, you can use the automated script:

```bash
./deploy-all.sh
```

This runs all the steps above automatically.
