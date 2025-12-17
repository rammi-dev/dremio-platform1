# Access Control & Credentials

This document details all access credentials, authentication methods, and authorization policies for the platform.

---

## Quick Access Summary

| Service | URL | Login Method |
|---------|-----|--------------|
| Keycloak Admin | http://localhost:8080 | Username/Password |
| Vault | http://localhost:8200 | OIDC or Token |
| MinIO Console | https://localhost:9091 | "Login with OpenID" |
| JupyterHub | http://localhost:8000 | "Sign in with Keycloak" |
| Dremio | http://localhost:9047 | OIDC (when configured) |

---

## Keycloak

### Realms

Keycloak has two realms with different purposes:

| Realm | Purpose | Admin Console Access |
|-------|---------|---------------------|
| `master` | Keycloak administration | Yes (temp-admin) |
| `vault` | Application users (OIDC) | No |

### Master Realm (Admin)

**Purpose**: Manage Keycloak itself (realms, clients, users)

```
URL:      http://localhost:8080/admin/master/console
Username: temp-admin
Password: <dynamically generated>
```

**Get password:**
```bash
kubectl get secret keycloak-initial-admin -n operators -o jsonpath='{.data.password}' | base64 -d
```

### Vault Realm (Application Users)

**Purpose**: OIDC authentication for all platform services

```
URL:      http://localhost:8080/realms/vault/account
Username: admin
Password: admin
```

> ⚠️ This user is for OIDC login to services (Vault, MinIO, JupyterHub), NOT for Keycloak admin console.

### Clients (OIDC Applications)

| Client ID | Service | Auth Flow |
|-----------|---------|-----------|
| `vault` | Vault UI OIDC | Standard Flow + Direct Access |
| `minio` | MinIO Console + STS | Standard Flow + Direct Access |
| `jupyterhub` | JupyterHub OAuth | Standard Flow |
| `dremio` | Dremio (future) | Standard Flow |

### Groups

| Group | Members | Purpose |
|-------|---------|---------|
| `vault-admins` | admin | Full Vault access |
| `minio-access` | admin | MinIO bucket access |
| `jupyterhub` | admin | JupyterHub access |

### Creating New Users

1. Login to Keycloak Admin Console (master realm)
2. Switch to `vault` realm (dropdown top-left)
3. Go to **Users** → **Add user**
4. Fill username, email
5. Go to **Credentials** tab → Set password (Temporary: OFF)
6. Go to **Groups** tab → Join groups as needed

---

## Vault

### Authentication Methods

#### Method 1: OIDC (Recommended)

1. Go to http://localhost:8200
2. Select Method: **OIDC**
3. Role: `admin` (required!)
4. Click **"Sign in with OIDC Provider"**
5. Login with Keycloak: `admin` / `admin`

#### Method 2: Root Token

```
URL:   http://localhost:8200
Token: <from vault-keys.json>
```

**Get token:**
```bash
cat config/vault-keys.json | jq -r '.root_token'
```

### Secrets Engine

**Path**: `secret/` (KV-v2)

**Stored secrets:**
| Path | Contents |
|------|----------|
| `secret/minio` | MinIO root credentials |

**Access secrets:**
```bash
# Via CLI
kubectl exec -n vault vault-0 -- vault kv get secret/minio

# Via API
curl -H "X-Vault-Token: $VAULT_TOKEN" http://localhost:8200/v1/secret/data/minio
```

### Policies

| Policy | Description |
|--------|-------------|
| `default` | Basic read access |
| `admin` | Full admin access (assigned to OIDC admins) |

### Unseal Key

If Vault is sealed after restart:
```bash
UNSEAL_KEY=$(cat config/vault-keys.json | jq -r '.unseal_keys_b64[0]')
kubectl exec -n vault vault-0 -- vault operator unseal $UNSEAL_KEY
```

---

## MinIO

### Authentication Methods

#### Method 1: OIDC (Recommended)

1. Go to https://localhost:9091
2. Click **"Login with OpenID"**
3. Login with Keycloak: `admin` / `admin`

#### Method 2: Root Credentials

```bash
# Get from Kubernetes secret
MINIO_USER=$(kubectl get secret minio-env-configuration -n minio -o jsonpath='{.data.config\.env}' | base64 -d | grep MINIO_ROOT_USER | cut -d'=' -f2 | tr -d '"')
MINIO_PASS=$(kubectl get secret minio-env-configuration -n minio -o jsonpath='{.data.config\.env}' | base64 -d | grep MINIO_ROOT_PASSWORD | cut -d'=' -f2 | tr -d '"')
echo "User: $MINIO_USER"
echo "Pass: $MINIO_PASS"
```

### STS (Temporary Credentials)

For programmatic access, use STS to get temporary credentials:

```bash
./scripts/get-minio-sts-credentials.sh
```

Or manually:
```bash
# 1. Get OIDC token from Keycloak
CLIENT_SECRET=$(kubectl get secret minio-env-configuration -n minio -o jsonpath='{.data.config\.env}' | base64 -d | grep MINIO_IDENTITY_OPENID_CLIENT_SECRET | cut -d'=' -f2 | tr -d '"')

TOKEN_RESPONSE=$(curl -s -X POST "http://localhost:8080/realms/vault/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "username=admin&password=admin&grant_type=password&client_id=minio&client_secret=$CLIENT_SECRET&scope=openid")

ID_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.id_token')

# 2. Exchange for STS credentials
curl -k -X POST "https://localhost:9000" \
  -d "Action=AssumeRoleWithWebIdentity&WebIdentityToken=$ID_TOKEN&Version=2011-06-15&DurationSeconds=3600"
```

### Policies

| Policy | Description | Applied To |
|--------|-------------|------------|
| `consoleAdmin` | Full console access | OIDC users (minio-access group) |
| `minio-access` | Bucket read/write | STS credentials |

### Access Control

MinIO uses policy-based access control. Policies are assigned based on:
1. **Root credentials**: Full admin access
2. **OIDC login**: Policies based on Keycloak group membership
3. **STS credentials**: Policies attached to the `minio-access` policy

---

## JupyterHub

### Authentication

1. Go to http://localhost:8000
2. Click **"Sign in with Keycloak"**
3. Login with Keycloak: `admin` / `admin`

### User Environment

Each user gets a dedicated notebook server with:
- Pre-injected MinIO STS credentials
- Python data science libraries
- Access to MinIO buckets

**Environment variables in notebooks:**
```python
import os
print(os.environ.get('AWS_ACCESS_KEY_ID'))
print(os.environ.get('AWS_SECRET_ACCESS_KEY'))
print(os.environ.get('AWS_SESSION_TOKEN'))
print(os.environ.get('MINIO_ENDPOINT'))
```

### Admin Access

JupyterHub admins can:
- View all user servers
- Stop/start user servers
- Access admin panel at `/hub/admin`

---

## Dremio

### Authentication (Future)

When Dremio is deployed with OIDC:
1. Go to http://localhost:9047
2. Click **"Sign in with SSO"**
3. Login with Keycloak

### Default Credentials (Non-OIDC)

If deployed without OIDC:
```
Username: dremio
Password: dremio123
```

---

## Scripts Reference

### Get All Credentials
```bash
./scripts/show-access-info.sh
```

### Start Port Forwards
```bash
./scripts/start-port-forwards.sh
```

### List Keycloak Users
```bash
./scripts/list-users.sh
```

### List MinIO Policies
```bash
./scripts/list-policies.sh
```

### Get MinIO STS Credentials
```bash
./scripts/get-minio-sts-credentials.sh
```

---

## Files Reference

| File | Contents |
|------|----------|
| `config/vault-keys.json` | Vault root token and unseal key |
| `config/keycloak-vault-client-secret.txt` | Vault OIDC client secret |

---

## Troubleshooting

### "OAuth state missing from cookies"
- Add to `/etc/hosts`: `127.0.0.1 jupyterhub.local`
- Access JupyterHub via `http://jupyterhub.local:8000`

### "Missing auth_url" in Vault
- Enter `admin` in the Role field before clicking OIDC login

### "Invalid client credentials"
- Verify port-forwards are running: `./scripts/start-port-forwards.sh`
- Check client secret matches Keycloak

### Vault is sealed
```bash
UNSEAL_KEY=$(cat config/vault-keys.json | jq -r '.unseal_keys_b64[0]')
kubectl exec -n vault vault-0 -- vault operator unseal $UNSEAL_KEY
```

### MinIO HTTPS certificate error
- MinIO uses self-signed certificates
- Accept the certificate warning in browser
- Use `--insecure` or `verify=False` in API calls
