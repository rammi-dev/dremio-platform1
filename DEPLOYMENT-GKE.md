# GKE Platform Deployment Guide

## Quick Reference - Deployment Order

```bash
# 1. Deploy Core Infrastructure (Keycloak & Vault)
./scripts/deploy-gke.sh

# 2. Deploy MinIO (Object Storage)
helm repo add minio-operator https://operator.min.io
helm repo update

# Install MinIO Operator
helm install minio-operator minio-operator/operator \
  -n minio-operator \
  --create-namespace \
  -f helm/minio/operator-values.yaml

# Install MinIO Tenant
helm install minio minio-operator/tenant \
  -n minio \
  --create-namespace \
  -f helm/minio/tenant-values.yaml

# 3. Deploy Dremio (after filling credentials)
vim helm/dremio/.env  # Add Quay.io credentials
./scripts/start-dremio.sh

# 4. Deploy JupyterHub (optional)
./scripts/deploy-jupyterhub-gke.sh
```

## Detailed Steps

### 1. Core Infrastructure (Keycloak & Vault)

**Script**: `./scripts/deploy-gke.sh`

**What it deploys**:
- Keycloak Operator + Instance (namespace: `operators`)
- PostgreSQL for Keycloak (2Gi persistent storage)
- Vault (namespace: `vault`, 1Gi persistent storage)
- Keycloak `vault` realm with OIDC client
- Vault OIDC authentication configured

**Verification**:
```bash
kubectl get pods -n operators  # keycloak-0, postgres-0
kubectl get pods -n vault      # vault-0
```

**Credentials saved to**:
- `config/vault-keys.json` - Vault root token and unseal key
- `config/keycloak-vault-client-secret.txt` - OIDC client secret

---

### 2. MinIO Object Storage

**Method**: Direct Helm installation (NOT deploy-minio-gke.sh)

**Step 1: Add Helm Repository**
```bash
helm repo add minio-operator https://operator.min.io
helm repo update
```

**Step 2: Install MinIO Operator**
```bash
helm install minio-operator minio-operator/operator \
  -n minio-operator \
  --create-namespace \
  -f helm/minio/operator-values.yaml
```

**Step 3: Install MinIO Tenant**
```bash
helm install minio minio-operator/tenant \
  -n minio \
  --create-namespace \
  -f helm/minio/tenant-values.yaml
```

**Verification**:
```bash
# Check operator
kubectl get pods -n minio-operator

# Check tenant
kubectl get pods -n minio
kubectl get tenant -n minio

# Should see:
# - minio-operator pod (1/1 Running)
# - minio-pool-0-0 pod (2/2 Running)
```

**Configuration Files**:
- `helm/minio/operator-values.yaml` - Operator configuration
- `helm/minio/tenant-values.yaml` - Tenant configuration (pools, storage, buckets)

**Access MinIO Console**:
```bash
# Port-forward
kubectl port-forward -n minio svc/minio-console 9443:9443 --address=0.0.0.0

# Access at: https://localhost:9443
# (Accept self-signed certificate)
```

---

### 3. Dremio Deployment

**Prerequisites**: Quay.io credentials for Dremio images

**Step 1: Configure Credentials**
```bash
# Edit .env file
vim helm/dremio/.env

# Add your credentials:
DREMIO_REGISTRY=quay.io
DREMIO_REGISTRY_USER=your-quay-username
DREMIO_REGISTRY_PASSWORD=your-quay-password
DREMIO_REGISTRY_EMAIL=no-reply@dremio.local
```

**Step 2: Deploy**
```bash
./scripts/start-dremio.sh
```

**What it does**:
- Loads credentials from `.env`
- Creates `dremio` namespace
- Creates `dremio-pull-secret` (docker-registry secret)
- Deploys Dremio via Helm

**Verification**:
```bash
kubectl get namespace dremio
kubectl get secret dremio-pull-secret -n dremio
kubectl get pods -n dremio
```

---

### 4. JupyterHub (Optional)

**Prerequisites**: Keycloak and MinIO must be running

**Script**: `./scripts/deploy-jupyterhub-gke.sh`

**What it deploys**:
- JupyterHub with Keycloak OIDC authentication (using `minio` client)
- MinIO STS integration for temporary S3 credentials
- Cross-namespace RBAC (hub in `jupyterhub`, notebooks in `jupyterhub-users`)
- Dynamic profiles based on Keycloak groups

**Important Notes**:
- **Reuses MinIO client**: JupyterHub uses the existing `minio` Keycloak client (not a separate `jupyterhub` client)
- **Redirect URIs**: Script automatically adds JupyterHub callback URLs to the `minio` client
- **Hostname**: Access via `http://jupyterhub.local:8000` (add to `/etc/hosts`)

**Verification**:
```bash
kubectl get pods -n jupyterhub         # Hub pod
kubectl get pods -n jupyterhub-users   # User notebook pods (after login)
```

**Access**:
```bash
# Port-forward
kubectl port-forward -n jupyterhub svc/proxy-public 8000:80 --address=0.0.0.0

# Add to /etc/hosts (and Windows hosts if using WSL)
echo "127.0.0.1 jupyterhub.local" | sudo tee -a /etc/hosts

# Access at: http://jupyterhub.local:8000
# Login with Keycloak: admin / admin
```


---

## Port Forwards

**Start all port-forwards**:
```bash
# Keycloak
kubectl port-forward -n operators svc/keycloak-service 8080:8080 --address=0.0.0.0 &

# Vault
kubectl port-forward -n vault svc/vault-ui 8200:8200 --address=0.0.0.0 &

# MinIO Console
kubectl port-forward -n minio svc/minio-console 9443:9443 --address=0.0.0.0 &

# MinIO API
kubectl port-forward -n minio svc/minio 9000:443 --address=0.0.0.0 &
```

**Stop all port-forwards**:
```bash
pkill -f 'kubectl port-forward'
```

---

## Access URLs

| Service | URL | Credentials |
|---------|-----|-------------|
| Keycloak | http://localhost:8080 | Master: `temp-admin` / (from secret)<br>Vault realm: `admin` / `admin` |
| Vault | http://localhost:8200 | Root token in `config/vault-keys.json`<br>OIDC: `admin` / `admin` |
| MinIO Console | https://localhost:9443 | OIDC via Keycloak or root creds |
| JupyterHub | http://jupyterhub.local:8000 | OIDC via Keycloak (`admin` / `admin`) |

**Note**: For JupyterHub, add `127.0.0.1 jupyterhub.local` to `/etc/hosts` (and Windows hosts file if using WSL)

---

## Troubleshooting

### JupyterHub OAuth Issues

**Problem**: "OAuth state missing from cookies" (400 Bad Request)

**Solution**: Already fixed in `helm/jupyterhub/values.yaml` with `manage_state = False`
- This disables OAuth state cookie verification to work around browser blocking
- Trade-off: Slightly less secure but necessary for browser compatibility

**Problem**: "Invalid client credentials" (500 Internal Server Error)

**Solution**: Client secret mismatch. Retrieve from Keycloak:
```bash
# Get client secret from Keycloak
CLIENT_SECRET=$(kubectl exec -n operators keycloak-0 -- /bin/bash -c \
  "kcadm.sh config credentials --server http://localhost:8080 --realm master --user admin --password \$(cat /opt/keycloak/data/admin-password) && \
  kcadm.sh get clients -r vault --fields id,clientId | jq -r '.[] | select(.clientId==\"minio\") | .id' | xargs -I {} kcadm.sh get clients/{}/client-secret -r vault --fields value | jq -r .value")

# Update JupyterHub
helm upgrade jupyterhub jupyterhub/jupyterhub -n jupyterhub \
  -f helm/jupyterhub/values.yaml \
  --set hub.config.GenericOAuthenticator.client_secret="$CLIENT_SECRET"
```

**Problem**: Cannot access `jupyterhub.local`

**Solution**: Add to hosts file:
```bash
echo "127.0.0.1 jupyterhub.local" | sudo tee -a /etc/hosts
```

**Problem**: Connection refused on port 8000

**Solution**: Restart port-forward:
```bash
kubectl port-forward -n jupyterhub svc/proxy-public 8000:80 --address=0.0.0.0
```

---

## Troubleshooting

### Check all pods
```bash
kubectl get pods -n operators
kubectl get pods -n vault
kubectl get pods -n minio-operator
kubectl get pods -n minio
kubectl get pods -n dremio
```

### Check Helm releases
```bash
helm list -A
```

### Unseal Vault (if sealed)
```bash
UNSEAL_KEY=$(cat config/vault-keys.json | jq -r '.unseal_keys_b64[0]')
kubectl exec -n vault vault-0 -- vault operator unseal $UNSEAL_KEY
```

### Get Keycloak admin password
```bash
kubectl get secret keycloak-initial-admin -n operators -o jsonpath='{.data.password}' | base64 -d
```

### MinIO not starting
```bash
# Check tenant status
kubectl get tenant -n minio -o yaml

# Check operator logs
kubectl logs -n minio-operator deployment/minio-operator

# Check tenant pod logs
kubectl logs -n minio minio-pool-0-0 -c minio
```

---

## Cleanup

**Remove all components**:
```bash
# Dremio
helm uninstall dremio -n dremio
kubectl delete namespace dremio

# MinIO
helm uninstall minio -n minio
helm uninstall minio-operator -n minio-operator
kubectl delete namespace minio minio-operator

# Vault
helm uninstall vault -n vault
kubectl delete namespace vault

# Keycloak
kubectl delete -f helm/keycloak/manifests/keycloak-instance.yaml
kubectl delete -f helm/postgres/postgres-for-keycloak.yaml
kubectl delete -f helm/keycloak/manifests/keycloak-operator.yml
kubectl delete namespace operators keycloak
```
