# Data Platform on Kubernetes

A production-ready data platform integrating **Keycloak**, **Vault**, **MinIO**, **JupyterHub**, and **Dremio** with unified OIDC authentication.

---

## 📋 Table of Contents

- [Architecture Overview](#architecture-overview)
- [Component Details](#component-details)
  - [Keycloak (Identity Provider)](#keycloak-identity-provider)
  - [Vault (Secrets Management)](#vault-secrets-management)
  - [MinIO (Object Storage)](#minio-object-storage)
  - [JupyterHub (Data Science)](#jupyterhub-data-science)
  - [Dremio (Data Lakehouse)](#dremio-data-lakehouse)
- [Authentication Flow](#authentication-flow)
- [Quick Start](#quick-start)
- [Project Structure](#project-structure)
- [Access Information](#access-information)

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              KUBERNETES CLUSTER                              │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                        OPERATORS NAMESPACE                           │   │
│  │  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────────┐  │   │
│  │  │   Keycloak      │  │   PostgreSQL    │  │  Keycloak Operator  │  │   │
│  │  │   (keycloak-0)  │──│   (postgres-0)  │  │                     │  │   │
│  │  │   Port: 8080    │  │   PVC: 2Gi      │  │                     │  │   │
│  │  └────────┬────────┘  └─────────────────┘  └─────────────────────┘  │   │
│  └───────────┼──────────────────────────────────────────────────────────┘   │
│              │                                                              │
│              │ OIDC Authentication                                          │
│              ▼                                                              │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │                         VAULT NAMESPACE                                │  │
│  │  ┌─────────────────────────────────────────────────────────────────┐  │  │
│  │  │                     HashiCorp Vault                              │  │  │
│  │  │                       (vault-0)                                  │  │  │
│  │  │                                                                  │  │  │
│  │  │  • OIDC Auth enabled (Keycloak integration)                     │  │  │
│  │  │  • KV-v2 secrets engine at /secret                              │  │  │
│  │  │  • Policy: admin (full access)                                  │  │  │
│  │  │  • Group mapping: vault-admins → admin policy                   │  │  │
│  │  │  • PVC: 1Gi persistent storage                                  │  │  │
│  │  │  • Port: 8200                                                   │  │  │
│  │  └─────────────────────────────────────────────────────────────────┘  │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
│              │                                                              │
│              │ Secrets Storage                                              │
│              ▼                                                              │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │                         MINIO NAMESPACE                                │  │
│  │  ┌─────────────────────────────────────────────────────────────────┐  │  │
│  │  │                      MinIO Tenant                                │  │  │
│  │  │                                                                  │  │  │
│  │  │  • OIDC Auth enabled (Keycloak integration)                     │  │  │
│  │  │  • S3-compatible API on port 443 (internal)                     │  │  │
│  │  │  • Console on port 9443 (internal)                              │  │  │
│  │  │  • Policies: data-science, admin, vault-admins                  │  │  │
│  │  │  • Credentials stored in Vault at secret/minio                  │  │  │
│  │  └─────────────────────────────────────────────────────────────────┘  │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
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

| Resource | Description |
|----------|-------------|
| **OAuth Client** | Uses `minio` client (shared with MinIO) |
| **Hub Config** | OAuthenticator with Keycloak |
| **Profiles** | Small, Large, GPU based on group membership |
| **STS Integration** | Automatic MinIO credentials injection |

#### User Session Flow

```
User Login Flow:
1. User → JupyterHub (/hub/login)
2. JupyterHub → Keycloak (OAuth redirect)
3. User authenticates with admin/admin
4. Keycloak → JupyterHub (JWT token)
5. JupyterHub extracts groups from token
6. JupyterHub → MinIO STS (AssumeRoleWithWebIdentity)
7. MinIO returns temporary S3 credentials
8. Notebook pod starts with:
   - AWS_ACCESS_KEY_ID
   - AWS_SECRET_ACCESS_KEY
   - S3_ENDPOINT=https://minio.minio.svc.cluster.local:443
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

| Keycloak Group | Vault Policy | MinIO Policy |
|----------------|--------------|--------------|
| `vault-admins` | `admin` (full) | `admin` (full) |
| `data-science` | - | `data-science` (S3 only) |
| `minio-access` | - | `data-science` (S3 only) |

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
