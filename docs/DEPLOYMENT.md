# GKE Deployment Guide

## Prerequisites

- GKE cluster running and accessible
- `kubectl` configured for the cluster
- `helm` installed
- `jq` installed

## Quick Start

### 1. Connect to GKE Cluster

```bash
gcloud container clusters get-credentials <cluster-name> --zone <zone> --project <project>
kubectl cluster-info
```

### 2. Deploy All Components

```bash
# Deploy Keycloak + Vault
./scripts/deploy-gke.sh

# Deploy MinIO
./scripts/deploy-minio-gke.sh

# Deploy JupyterHub
./scripts/deploy-jupyterhub-gke.sh

# Deploy Spark Operator
./scripts/deploy-spark-operator.sh

# Deploy Dremio (optional)
./scripts/deploy-dremio-ee.sh
```

### 3. Start Port Forwards

```bash
./scripts/start-port-forwards.sh
```

### 4. Access Services

| Service | URL | Login |
|---------|-----|-------|
| Keycloak | http://localhost:8080 | temp-admin / (see secret) |
| Vault | http://localhost:8200 | OIDC (admin/admin) |
| MinIO | https://localhost:9091 | "Login with OpenID" |
| JupyterHub | http://localhost:8000 | "Sign in with Keycloak" |
| Dremio | http://localhost:9047 | (when deployed) |

---

## Detailed Deployment Steps

### Phase 1: Core Infrastructure (deploy-gke.sh)

**Duration**: ~5-7 minutes

**Creates:**
1. **Namespaces**: `operators`, `keycloak`, `vault`
2. **Keycloak Operator**: CRDs and operator deployment
3. **PostgreSQL**: StatefulSet with 2Gi PVC for Keycloak data
4. **Keycloak Instance**: StatefulSet `keycloak-0`
5. **Vault**: Helm deployment with 1Gi PVC

**Configures:**
1. **Vault Initialization**: Creates root token and unseal key
2. **Vault Unsealing**: Automatically unseals Vault
3. **Keycloak Realm**: Creates `vault` realm
4. **OIDC Client**: Creates `vault` client in Keycloak
5. **Groups**: Creates `vault-admins` group
6. **Users**: Creates `admin` user with password `admin`
7. **Vault OIDC**: Configures Vault to authenticate via Keycloak

**Outputs:**
- `config/vault-keys.json` - Vault root token and unseal key
- `config/keycloak-vault-client-secret.txt` - OIDC client secret

### Phase 2: Object Storage (deploy-minio-gke.sh)

**Duration**: ~3-5 minutes

**Creates:**
1. **MinIO Operator**: In `minio-operator` namespace
2. **MinIO Tenant**: In `minio` namespace

**Configures:**
1. **OIDC Client**: Creates `minio` client in Keycloak
2. **Groups**: Creates `minio-access` group
3. **MinIO OIDC**: Injects OIDC configuration
4. **Vault Secret**: Stores MinIO credentials in Vault
5. **MinIO Policy**: Creates `minio-access` policy

### Phase 3: JupyterHub (deploy-jupyterhub-gke.sh)

**Duration**: ~2-3 minutes

**Creates:**
1. **Namespaces**: `jupyterhub`, `jupyterhub-users`
2. **JupyterHub**: Hub and proxy pods

**Configures:**
1. **OIDC Client**: Creates `jupyterhub` client in Keycloak
2. **Groups**: Creates `jupyterhub` group
3. **OAuth**: Configures GenericOAuthenticator
4. **STS Integration**: Pre-spawn hook for MinIO credentials

### Phase 4: Spark Operator (deploy-spark-operator.sh)

**Duration**: ~1 minute

**Creates:**
1. **Spark Operator**: Controller and webhook in `operators` namespace
2. **CRDs**: SparkApplication custom resource

### Phase 5: Dremio (deploy-dremio-ee.sh)

**Duration**: ~5-10 minutes

**Creates:**
1. **Namespace**: `dremio`
2. **Dremio**: Coordinator and executor pods

---

## Verification

### Check All Pods

```bash
kubectl get pods -A | grep -E '^(operators|vault|minio|jupyterhub)'
```

Expected:
```
operators         keycloak-0                              1/1     Running
operators         keycloak-operator-*                     1/1     Running
operators         postgres-0                              1/1     Running
operators         spark-platform-spark-operator-*         1/1     Running
vault             vault-0                                 1/1     Running
minio-operator    minio-operator-*                        1/1     Running
minio             minio-pool-0-0                          2/2     Running
jupyterhub        hub-*                                   1/1     Running
jupyterhub        proxy-*                                 1/1     Running
```

### Check Persistent Volumes

```bash
kubectl get pvc -A
```

### Check Port Forwards

```bash
ps aux | grep 'kubectl.*port-forward' | grep -v grep
```

### Test Keycloak

```bash
curl -s http://localhost:8080/realms/vault/.well-known/openid-configuration | jq .issuer
```

### Test Vault

```bash
curl -s http://localhost:8200/v1/sys/health | jq
```

---

## Configuration Reference

### Keycloak (vault realm)

| Item | Value |
|------|-------|
| Realm | `vault` |
| Admin User | `admin` / `admin` |
| Groups | `vault-admins`, `minio-access`, `jupyterhub` |
| Clients | `vault`, `minio`, `jupyterhub` |

### Vault

| Item | Value |
|------|-------|
| Auth Method | OIDC (Keycloak) |
| OIDC Role | `admin` |
| Secrets Path | `secret/` |
| MinIO Creds | `secret/minio` |

### MinIO

| Item | Value |
|------|-------|
| Console Port | 9443 (internal), 9091 (forward) |
| API Port | 443 (internal), 9000 (forward) |
| OIDC Provider | Keycloak (vault realm) |
| Policy | `minio-access` |

### JupyterHub

| Item | Value |
|------|-------|
| Hub Namespace | `jupyterhub` |
| User Namespace | `jupyterhub-users` |
| OAuth Provider | Keycloak (vault realm) |
| Callback URL | `http://jupyterhub.local:8000/hub/oauth_callback` |

---

## Troubleshooting

### Keycloak not starting
```bash
kubectl logs -n operators keycloak-0
kubectl describe pod -n operators keycloak-0
```

### Vault sealed
```bash
UNSEAL_KEY=$(cat config/vault-keys.json | jq -r '.unseal_keys_b64[0]')
kubectl exec -n vault vault-0 -- vault operator unseal $UNSEAL_KEY
```

### Port forward died
```bash
./scripts/start-port-forwards.sh
```

### OIDC errors
- Check Keycloak is accessible: `curl http://localhost:8080`
- Check realm exists: `curl http://localhost:8080/realms/vault`
- Check client secret matches

---

## Cleanup

### Delete specific namespace
```bash
kubectl delete namespace <namespace>
```

### Delete stuck namespace
```bash
./scripts/cleanup-dremio-namespace.sh <namespace>
```

### Full cleanup
```bash
kubectl delete namespace operators vault minio minio-operator jupyterhub jupyterhub-users dremio
```
