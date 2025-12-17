# Data Platform on Kubernetes

A production-ready data platform integrating **Keycloak**, **Vault**, **MinIO**, **JupyterHub**, and **Dremio** with unified OIDC authentication.

---

## 📋 Table of Contents

- [Architecture Overview](#architecture-overview)
- [Integration Flow Diagram](#integration-flow-diagram)
- [Component Details](#component-details)
  - [Keycloak (Identity Provider)](#keycloak-identity-provider)
  - [Vault (Secrets Management)](#vault-secrets-management)
  - [MinIO (Object Storage)](#minio-object-storage)
  - [JupyterHub (Data Science)](#jupyterhub-data-science)
  - [Spark Operator](#spark-operator)
  - [Dremio (Data Lakehouse)](#dremio-data-lakehouse)
- [Authentication Flow](#authentication-flow)
- [Quick Start](#quick-start)
- [Project Structure](#project-structure)
- [Access Information](#access-information)

---

## Architecture Overview

```
┌──────────────────────────────────────────────────────────────────────────────────────┐
│                                 KUBERNETES CLUSTER                                    │
├──────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                      │
│  ┌────────────────────────────────────────────────────────────────────────────────┐  │
│  │                           OPERATORS NAMESPACE                                   │  │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  ┌────────────────────┐  │  │
│  │  │  Keycloak    │  │  PostgreSQL  │  │  Keycloak    │  │  Spark Operator    │  │  │
│  │  │  (keycloak-0)│──│  (postgres-0)│  │  Operator    │  │                    │  │  │
│  │  │  Port: 8080  │  │  PVC: 2Gi    │  │              │  │  Watches:          │  │  │
│  │  │              │  │              │  │              │  │  jupyterhub-users  │  │  │
│  │  └──────┬───────┘  └──────────────┘  └──────────────┘  └────────────────────┘  │  │
│  └─────────┼──────────────────────────────────────────────────────────────────────┘  │
│            │                                                                         │
│            │ OIDC (JWT with groups claim)                                            │
│            ▼                                                                         │
│  ┌─────────┴──────────────────────────────────────────────────────────────────────┐  │
│  │                                                                                 │  │
│  │    ┌─────────────────────────────────────────────────────────────────────┐     │  │
│  │    │                        VAULT NAMESPACE                               │     │  │
│  │    │  ┌───────────────────────────────────────────────────────────────┐  │     │  │
│  │    │  │                   HashiCorp Vault (vault-0)                    │  │     │  │
│  │    │  │  • OIDC Auth → Keycloak                                       │  │     │  │
│  │    │  │  • KV-v2 at /secret (stores MinIO creds)                      │  │     │  │
│  │    │  │  • Policy: admin (full access)                                │  │     │  │
│  │    │  │  • Group: vault-admins → admin policy                         │  │     │  │
│  │    │  └───────────────────────────────────────────────────────────────┘  │     │  │
│  │    └─────────────────────────────────────────────────────────────────────┘     │  │
│  │                                                                                 │  │
│  │    ┌─────────────────────────────────────────────────────────────────────┐     │  │
│  │    │                        MINIO NAMESPACE                               │     │  │
│  │    │  ┌───────────────────────────────────────────────────────────────┐  │     │  │
│  │    │  │                    MinIO Tenant                                │  │     │  │
│  │    │  │  • OIDC Auth → Keycloak                                       │  │     │  │
│  │    │  │  • STS API: AssumeRoleWithWebIdentity                         │  │     │  │
│  │    │  │  • Policies: admin, data-science, vault-admins                │  │     │  │
│  │    │  │  • S3 API: port 443 | Console: port 9443                      │  │     │  │
│  │    │  └──────────────────────────────┬────────────────────────────────┘  │     │  │
│  │    └─────────────────────────────────┼────────────────────────────────────┘     │  │
│  │                                      │ STS Credentials                          │  │
│  │                                      ▼                                          │  │
│  │    ┌─────────────────────────────────────────────────────────────────────┐     │  │
│  │    │                     JUPYTERHUB NAMESPACE                             │     │  │
│  │    │  ┌───────────────────────────────────────────────────────────────┐  │     │  │
│  │    │  │                    JupyterHub (hub)                            │  │     │  │
│  │    │  │  • OAuth → Keycloak (uses 'minio' client)                     │  │     │  │
│  │    │  │  • Pre-spawn hook: gets STS creds from MinIO                  │  │     │  │
│  │    │  │  • Profiles: Small (all), Large (admin group only)            │  │     │  │
│  │    │  └───────────────────────────────────────────────────────────────┘  │     │  │
│  │    └─────────────────────────────────────────────────────────────────────┘     │  │
│  │                                      │                                          │  │
│  │                                      │ Spawns notebooks                         │  │
│  │                                      ▼                                          │  │
│  │    ┌─────────────────────────────────────────────────────────────────────┐     │  │
│  │    │                   JUPYTERHUB-USERS NAMESPACE                         │     │  │
│  │    │  ┌───────────────────────────────────────────────────────────────┐  │     │  │
│  │    │  │              User Notebook Pods                                │  │     │  │
│  │    │  │  • AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY injected          │  │     │  │
│  │    │  │  • S3_ENDPOINT → MinIO                                        │  │     │  │
│  │    │  │  • Can submit Spark jobs via SparkApplication CRD             │  │     │  │
│  │    │  └───────────────────────────────────────────────────────────────┘  │     │  │
│  │    │  ┌───────────────────────────────────────────────────────────────┐  │     │  │
│  │    │  │              Spark Driver/Executor Pods                        │  │     │  │
│  │    │  │  • ServiceAccount: spark-driver                               │  │     │  │
│  │    │  │  • Managed by Spark Operator                                  │  │     │  │
│  │    │  └───────────────────────────────────────────────────────────────┘  │     │  │
│  │    └─────────────────────────────────────────────────────────────────────┘     │  │
│  │                                                                                 │  │
│  └─────────────────────────────────────────────────────────────────────────────────┘  │
│                                                                                      │
└──────────────────────────────────────────────────────────────────────────────────────┘
```

### Integration Flow Diagram

```
┌──────────────────────────────────────────────────────────────────────────────────────┐
│                            AUTHENTICATION & DATA ACCESS FLOW                          │
└──────────────────────────────────────────────────────────────────────────────────────┘

    ┌──────────┐                                                                        
    │   User   │                                                                        
    │ Browser  │                                                                        
    └────┬─────┘                                                                        
         │                                                                              
         │ 1. Access JupyterHub                                                         
         ▼                                                                              
    ┌──────────┐         2. OAuth Redirect        ┌───────────────┐                     
    │ Jupyter  │ ─────────────────────────────▶  │   Keycloak    │                     
    │   Hub    │                                  │               │                     
    │          │ ◀─────────────────────────────  │  Realm: vault │                     
    └────┬─────┘    3. JWT Token (id_token)      │  Client: minio│                     
         │              + groups claim            └───────┬───────┘                     
         │                                                │                             
         │ 4. Extract id_token                            │                             
         │    from auth_state                             │                             
         ▼                                                │                             
    ┌──────────┐                                          │                             
    │ Pre-Spawn│        5. AssumeRoleWithWebIdentity      │                             
    │   Hook   │ ─────────────────────────────────────▶  ▼                             
    │          │         (POST with JWT token)     ┌───────────────┐                   
    │          │                                   │     MinIO     │                   
    │          │ ◀─────────────────────────────── │      STS      │                   
    └────┬─────┘    6. Temp Credentials            │               │                   
         │         (AccessKey, SecretKey,          │ Validates JWT │                   
         │          SessionToken)                  │ Maps groups   │                   
         │                                         │ to policies   │                   
         │ 7. Inject env vars                      └───────────────┘                   
         ▼                                                                              
    ┌──────────┐                                                                        
    │ Notebook │        8. S3 API Calls            ┌───────────────┐                   
    │   Pod    │ ─────────────────────────────▶   │     MinIO     │                   
    │          │    (with temp credentials)        │    Storage    │                   
    │ ENV:     │                                   │               │                   
    │ AWS_*    │ ◀─────────────────────────────   │  Buckets,     │                   
    │ S3_*     │        9. Data                    │  Objects      │                   
    └──────────┘                                   └───────────────┘                   
```

---

## Component Details

### Keycloak (Identity Provider)

Keycloak serves as the central identity and access management (IAM) system for the entire platform.

#### What Gets Created

| Resource | Name | Description |
|----------|------|-------------|
| **Realms** | `master` | Admin realm (auto-created) |
| | `vault` | Application realm for all services |
| **OIDC Clients** | `vault` | HashiCorp Vault integration |
| | `minio` | MinIO Console & API integration |
| | `jupyterhub` | JupyterHub authentication |
| **Groups** | `vault-admins` | Full Vault admin access |
| | `data-science` | Data science users (MinIO, JupyterHub) |
| | `minio-access` | MinIO storage access |
| **Users** | `admin` | Default admin user (password: `admin`) |
| **Protocol Mappers** | `groups` | Maps group membership to JWT claims |

#### Realm Configuration

```yaml
Realm: vault
├── Clients
│   ├── vault
│   │   ├── Client Protocol: openid-connect
│   │   ├── Access Type: confidential
│   │   ├── Direct Access Grants: enabled
│   │   ├── Standard Flow: enabled
│   │   └── Redirect URIs:
│   │       ├── http://localhost:8200/ui/vault/auth/oidc/oidc/callback
│   │       ├── http://127.0.0.1:8200/ui/vault/auth/oidc/oidc/callback
│   │       └── http://localhost:8250/oidc/callback
│   │
│   └── minio
│       ├── Client Protocol: openid-connect
│       ├── Access Type: confidential
│       ├── Direct Access Grants: enabled
│       └── Redirect URIs:
│           ├── https://localhost:9091/*
│           └── http://localhost:9091/*
│
├── Groups
│   ├── vault-admins (→ Vault admin policy)
│   ├── data-science (→ MinIO data-science policy)
│   └── minio-access (→ MinIO access)
│
└── Users
    └── admin
        ├── Email: admin@vault.local
        ├── Groups: vault-admins, minio-access
        └── Password: admin
```

#### JWT Token Structure

When a user authenticates, Keycloak issues a JWT token with:

```json
{
  "sub": "user-uuid",
  "preferred_username": "admin",
  "email": "admin@vault.local",
  "groups": ["vault-admins", "minio-access"],
  "aud": "vault",
  "iss": "http://keycloak-service.operators.svc.cluster.local:8080/realms/vault"
}
```

---

### Vault (Secrets Management)

HashiCorp Vault provides centralized secrets management with OIDC authentication.

#### What Gets Created

| Resource | Name | Description |
|----------|------|-------------|
| **Auth Methods** | `oidc/` | OIDC authentication via Keycloak |
| **Policies** | `admin` | Full access to all paths |
| **Secrets Engines** | `secret/` | KV-v2 secrets engine |
| **Identity Groups** | `vault-admins` | External group mapped to Keycloak |

#### Vault Configuration

```
Vault Server (vault-0)
├── Auth Methods
│   └── oidc/
│       ├── Discovery URL: http://keycloak-service.operators.svc.cluster.local:8080/realms/vault
│       ├── Client ID: vault
│       ├── Client Secret: <from keycloak>
│       └── Roles
│           └── admin
│               ├── Bound Audiences: vault
│               ├── User Claim: sub
│               ├── Groups Claim: groups
│               ├── Policies: admin
│               └── Allowed Redirect URIs:
│                   ├── http://localhost:8200/ui/vault/auth/oidc/oidc/callback
│                   └── http://localhost:8250/oidc/callback
│
├── Policies
│   └── admin
│       └── path "*" { capabilities = ["create","read","update","delete","list","sudo"] }
│
├── Identity
│   └── Groups
│       └── vault-admins (external)
│           ├── Policies: admin
│           └── Alias: vault-admins (OIDC mount)
│
└── Secrets Engines
    └── secret/ (kv-v2)
        └── minio
            ├── access_key: <minio-root-user>
            ├── secret_key: <minio-root-password>
            └── endpoint: https://minio.minio.svc.cluster.local:443
```

#### Authentication Flow

1. User clicks "OIDC" login in Vault UI
2. Vault redirects to Keycloak login page
3. User enters credentials (admin/admin)
4. Keycloak validates and returns JWT with groups claim
5. Vault extracts `groups` from JWT
6. Vault maps `vault-admins` group to `admin` policy
7. User gets full admin access to Vault

---

### MinIO (Object Storage)

MinIO provides S3-compatible object storage with OIDC-based access control.

#### What Gets Created

| Resource | Name | Description |
|----------|------|-------------|
| **Tenant** | `minio` | MinIO storage cluster |
| **Policies** | `data-science` | S3 full access |
| | `admin` | S3 + Admin full access |
| | `vault-admins` | Same as admin |
| **OIDC Config** | Keycloak integration | Group-based policy mapping |

#### MinIO Configuration

```
MinIO Tenant (minio)
├── Storage
│   └── Pools: 1 (4 servers × 1 drive each for HA)
│
├── OIDC Configuration
│   ├── Config URL: http://keycloak-service.operators.svc.cluster.local:8080/realms/vault/.well-known/openid-configuration
│   ├── Client ID: minio
│   ├── Client Secret: <from keycloak>
│   ├── Claim Name: groups
│   ├── Scopes: openid,profile,email
│   └── Redirect URL: https://localhost:9091
│
├── Policies
│   ├── data-science
│   │   └── Statement:
│   │       └── Effect: Allow
│   │           Action: s3:*
│   │           Resource: arn:aws:s3:::*
│   │
│   ├── admin
│   │   └── Statement:
│   │       ├── Effect: Allow
│   │       │   Action: s3:*
│   │       │   Resource: arn:aws:s3:::*
│   │       └── Effect: Allow
│   │           Action: admin:*
│   │           Resource: arn:aws:s3:::*
│   │
│   └── vault-admins (same as admin)
│
└── Group → Policy Mapping
    ├── vault-admins → admin policy
    ├── data-science → data-science policy
    └── minio-access → data-science policy
```

#### How OIDC Policy Mapping Works

1. User clicks "Login with OpenID" in MinIO Console
2. MinIO redirects to Keycloak
3. User authenticates (admin/admin)
4. Keycloak returns JWT with `groups: ["vault-admins", "minio-access"]`
5. MinIO looks for policies matching group names:
   - `vault-admins` → applies `vault-admins` policy (full admin)
6. User gets temporary credentials with combined policy permissions

---

### JupyterHub (Data Science)

JupyterHub provides a multi-user Jupyter notebook environment with OIDC authentication and MinIO STS integration.

#### What Gets Created

| Resource | Name | Description |
|----------|------|-------------|
| **Namespace** | `jupyterhub` | Hub deployment |
| | `jupyterhub-users` | User notebook pods & Spark jobs |
| **OAuth Client** | `minio` | Shared client with MinIO |
| **ServiceAccount** | `jupyterhub` | Hub service account |
| | `spark-driver` | Spark job service account |
| **Profiles** | `small` | 1 CPU, 2G RAM (all users) |
| | `large` | 4 CPU, 8G RAM (admin group only) |

#### JupyterHub Configuration

```
JupyterHub
├── Authentication
│   ├── Authenticator Class: GenericOAuthenticator
│   ├── Client ID: minio (shared with MinIO)
│   ├── Authorize URL: http://keycloak-service.operators.svc.cluster.local:8080/realms/vault/protocol/openid-connect/auth
│   ├── Token URL: http://keycloak-service.operators.svc.cluster.local:8080/realms/vault/protocol/openid-connect/token
│   ├── Userinfo URL: http://keycloak-service.operators.svc.cluster.local:8080/realms/vault/protocol/openid-connect/userinfo
│   └── Username Claim: preferred_username
│
├── Spawner Configuration
│   ├── Namespace: jupyterhub-users (separate from hub)
│   └── pre_spawn_hook: MinIO STS credential injection
│
├── Dynamic Profiles (based on group membership)
│   ├── Small (everyone)
│   │   ├── CPU: 1 limit, 0.5 guarantee
│   │   └── Memory: 2G limit, 512M guarantee
│   │
│   └── Large (admin/vault-admins groups only)
│       ├── CPU: 4 limit
│       └── Memory: 8G limit
│
└── Storage
    ├── Type: dynamic
    ├── Capacity: 10Gi per user
    └── StorageClass: standard
```

#### MinIO STS Integration (Pre-Spawn Hook)

The pre-spawn hook automatically injects MinIO credentials into every notebook:

```python
# Simplified flow of pre_spawn_hook
async def pre_spawn_hook(spawner):
    # 1. Get user's id_token from OAuth auth_state
    auth_state = await spawner.user.get_auth_state()
    id_token = auth_state['id_token']
    
    # 2. Call MinIO STS API
    response = requests.post('https://minio.minio.svc.cluster.local:443', data={
        'Action': 'AssumeRoleWithWebIdentity',
        'WebIdentityToken': id_token,
        'DurationSeconds': '43200'  # 12 hours
    })
    
    # 3. Parse XML response for credentials
    credentials = parse_sts_response(response)
    
    # 4. Inject as environment variables
    spawner.environment.update({
        'AWS_ACCESS_KEY_ID': credentials.access_key,
        'AWS_SECRET_ACCESS_KEY': credentials.secret_key,
        'AWS_SESSION_TOKEN': credentials.session_token,
        'S3_ENDPOINT': 'https://minio.minio.svc.cluster.local:443'
    })
```

#### Environment Variables in Notebook Pods

| Variable | Value | Description |
|----------|-------|-------------|
| `AWS_ACCESS_KEY_ID` | `<temp-key>` | MinIO STS access key |
| `AWS_SECRET_ACCESS_KEY` | `<temp-secret>` | MinIO STS secret key |
| `AWS_SESSION_TOKEN` | `<session-token>` | STS session token |
| `S3_ENDPOINT` | `https://minio.minio.svc.cluster.local:443` | MinIO endpoint |
| `PROFILE_NAME` | `small` or `large` | Selected profile |

---

### Spark Operator

The Kubeflow Spark Operator enables running Apache Spark applications on Kubernetes, integrated with JupyterHub notebooks.

#### What Gets Created

| Resource | Namespace | Name | Description |
|----------|-----------|------|-------------|
| **Deployment** | `operators` | `spark-operator` | Spark Operator controller |
| **Webhook** | `operators` | Spark admission webhook | Validates SparkApplication CRDs |
| **ServiceAccount** | `jupyterhub-users` | `spark-driver` | SA for Spark driver pods |
| **RBAC** | `jupyterhub-users` | Role + RoleBinding | Permissions for Spark jobs |

#### Spark Operator Configuration

```
Spark Operator (operators namespace)
├── Webhook: enabled (validates SparkApplication CRs)
├── Job Namespaces: jupyterhub-users
└── Resources
    ├── Limits: 200m CPU, 256Mi memory
    └── Requests: 100m CPU, 128Mi memory

RBAC (jupyterhub-users namespace)
├── ServiceAccount: spark-driver
├── Role: spark-driver-role
│   └── Permissions:
│       ├── pods: create, get, list, watch, delete
│       ├── services: create, get, delete
│       └── configmaps: create, get, delete
└── RoleBinding: spark-driver-binding
    └── ServiceAccount → Role
```

#### SparkApplication CRD Example

Users can submit Spark jobs from notebooks using SparkApplication manifests:

```yaml
apiVersion: sparkoperator.k8s.io/v1beta2
kind: SparkApplication
metadata:
  name: spark-pi
  namespace: jupyterhub-users
spec:
  type: Python
  mode: cluster
  image: spark:3.5.0
  mainApplicationFile: local:///opt/spark/examples/src/main/python/pi.py
  sparkVersion: "3.5.0"
  driver:
    serviceAccount: spark-driver
    cores: 1
    memory: "512m"
  executor:
    cores: 1
    instances: 2
    memory: "512m"
```

#### Spark with MinIO Integration

Spark jobs can access MinIO storage using the STS credentials from notebooks:

```python
# In a JupyterHub notebook
import os
from pyspark.sql import SparkSession

spark = SparkSession.builder \
    .appName("MinIO Access") \
    .config("spark.hadoop.fs.s3a.endpoint", os.environ['S3_ENDPOINT']) \
    .config("spark.hadoop.fs.s3a.access.key", os.environ['AWS_ACCESS_KEY_ID']) \
    .config("spark.hadoop.fs.s3a.secret.key", os.environ['AWS_SECRET_ACCESS_KEY']) \
    .config("spark.hadoop.fs.s3a.session.token", os.environ['AWS_SESSION_TOKEN']) \
    .config("spark.hadoop.fs.s3a.path.style.access", "true") \
    .getOrCreate()

# Read from MinIO
df = spark.read.parquet("s3a://my-bucket/data/")
```

---

### Dremio (Data Lakehouse)

Dremio Enterprise provides a unified data lakehouse with SQL query capabilities.

#### What Gets Created

| Resource | Description |
|----------|-------------|
| **Coordinator** | Query coordination and UI |
| **Executors** | Query execution engines |
| **MongoDB** | Metadata storage |
| **MinIO Integration** | S3 source configuration |

---

## Authentication Flow

```
┌──────────┐     ┌───────────┐     ┌─────────┐     ┌───────────┐
│  User    │────▶│ Service   │────▶│Keycloak │────▶│  Service  │
│ Browser  │     │  (Vault/  │     │  OIDC   │     │  Backend  │
│          │◀────│  MinIO)   │◀────│         │◀────│           │
└──────────┘     └───────────┘     └─────────┘     └───────────┘
     │                                   │
     │ 1. Access service                 │
     │ 2. Redirect to Keycloak          │
     │ 3. Login (admin/admin)           │
     │ 4. Receive JWT with groups       │
     │ 5. Service validates JWT         │
     │ 6. Map groups to policies        │
     │ 7. Grant access                  │
```

### Group-to-Policy Mapping

| Keycloak Group | Vault Policy | MinIO Policy | JupyterHub Access |
|----------------|--------------|--------------|-------------------|
| `vault-admins` | `admin` (full) | `admin` (full) | Large profile |
| `admin` | - | `admin` (full) | Large profile |
| `data-science` | - | `data-science` (S3 only) | Small profile |
| `minio-access` | - | `data-science` (S3 only) | Small profile |

---

## Quick Start

### Deploy Everything

```bash
# Clone the repository
git clone <repo-url>
cd dremio-platform1

# Deploy core infrastructure (Keycloak + Vault)
./scripts/deploy-all.sh core

# Deploy MinIO (optional)
./scripts/deploy-all.sh --skip-core minio

# Or deploy everything at once
./scripts/deploy-all.sh all
```

### Access Services

After deployment, services are accessible via port-forwards:

| Service | URL | Credentials |
|---------|-----|-------------|
| Keycloak | http://localhost:8080 | Master: see `keycloak-initial-admin` secret |
| Keycloak (vault realm) | http://localhost:8080 | `admin` / `admin` |
| Vault | http://localhost:8200 | Token: see `config/vault-keys.json` |
| Vault (OIDC) | http://localhost:8200 | `admin` / `admin` (via Keycloak) |
| MinIO Console | https://localhost:9091 | Click "Login with OpenID" |
| JupyterHub | http://localhost:8000 | Click "Sign in with Keycloak" |
| Dremio | http://localhost:9047 | Create admin on first login |

---

## Project Structure

```
.
├── scripts/
│   ├── config.sh                 # Central configuration
│   ├── deploy-all.sh             # Main orchestrator
│   ├── lib/
│   │   ├── common.sh             # Shared utilities
│   │   ├── keycloak.sh           # Keycloak functions
│   │   ├── vault.sh              # Vault functions
│   │   ├── port-forward.sh       # Port-forward management
│   │   ├── minio-common.sh       # MinIO functions
│   │   └── jupyterhub-common.sh  # JupyterHub functions
│   └── deploy/
│       ├── deploy-core.sh        # Core deployment
│       └── deploy-minio.sh       # MinIO deployment
│
├── helm/
│   ├── keycloak/
│   │   ├── values.yaml
│   │   └── manifests/
│   │       ├── keycloak-crd.yml
│   │       ├── keycloak-operator.yml
│   │       └── keycloak-instance.yaml
│   ├── vault/
│   │   └── values.yaml
│   ├── minio/
│   │   ├── operator-values.yaml
│   │   └── tenant-values.yaml
│   └── postgres/
│       └── postgres-for-keycloak.yaml
│
├── config/                       # Generated configs (gitignored)
│   ├── vault-keys.json          # Vault root token & unseal keys
│   └── keycloak-vault-client-secret.txt
│
└── docs/                         # Additional documentation
```

---

## Access Information

### Keycloak

- **URL**: http://localhost:8080
- **Master Realm Admin**: Retrieved from `keycloak-initial-admin` secret
- **Vault Realm User**: `admin` / `admin`

### Vault

- **URL**: http://localhost:8200
- **Root Token**: Stored in `config/vault-keys.json`
- **OIDC Login**: Select "OIDC" method, Role: `admin`, then login via Keycloak

### MinIO

- **Console**: https://localhost:9091
- **API Endpoint**: https://localhost:9000
- **Login**: Click "Login with OpenID" → authenticate via Keycloak

### JupyterHub

- **URL**: http://localhost:8000 (or http://jupyterhub.local:8000)
- **Login**: Click "Sign in with Keycloak" → authenticate with `admin` / `admin`
- **Note**: Add `127.0.0.1 jupyterhub.local` to `/etc/hosts` if using domain

### Spark

- **Operator**: Deployed in `operators` namespace
- **Jobs**: Submit to `jupyterhub-users` namespace
- **Service Account**: `spark-driver` (pre-configured with RBAC)

### Show All Credentials

```bash
./scripts/show-access-info.sh
```

---

## Persistent Data

All stateful components use Persistent Volume Claims (PVCs):

| Component | PVC Size | Purpose |
|-----------|----------|---------|
| PostgreSQL | 2Gi | Keycloak database |
| Vault | 1Gi | Secrets storage |
| MinIO | Varies | Object storage |

Data persists across pod restarts and cluster restarts.

---

## License

Reference implementation for enterprise data platform deployment.
