# Platform Architecture

## Overview

This platform provides a complete data analytics environment on Kubernetes (GKE) with centralized identity management, secrets management, object storage, and data processing capabilities.

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                              GKE Cluster                                      │
│                                                                               │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐    ┌─────────────┐   │
│  │  Keycloak   │    │    Vault    │    │    MinIO    │    │   Dremio    │   │
│  │   (IdP)     │    │  (Secrets)  │    │  (Storage)  │    │   (Query)   │   │
│  └──────┬──────┘    └──────┬──────┘    └──────┬──────┘    └──────┬──────┘   │
│         │                  │                  │                  │          │
│         └──────────────────┴──────────────────┴──────────────────┘          │
│                              │                                               │
│                      ┌───────┴───────┐                                       │
│                      │  JupyterHub   │                                       │
│                      │ (Notebooks)   │                                       │
│                      └───────┬───────┘                                       │
│                              │                                               │
│                      ┌───────┴───────┐                                       │
│                      │Spark Operator │                                       │
│                      │   (Compute)   │                                       │
│                      └───────────────┘                                       │
└──────────────────────────────────────────────────────────────────────────────┘
```

## Components

### 1. Keycloak (Identity Provider)
- **Purpose**: Centralized authentication and authorization
- **Namespace**: `operators`
- **Storage**: PostgreSQL with 2Gi persistent volume
- **Features**:
  - OIDC/OAuth2 provider for all services
  - User and group management
  - Role-based access control (RBAC)
  - SSO across all platform services

### 2. HashiCorp Vault (Secrets Management)
- **Purpose**: Secure storage for credentials and secrets
- **Namespace**: `vault`
- **Storage**: 1Gi persistent volume
- **Features**:
  - KV-v2 secrets engine
  - OIDC authentication via Keycloak
  - Stores MinIO root credentials
  - Dynamic secrets generation

### 3. MinIO (Object Storage)
- **Purpose**: S3-compatible object storage for data lake
- **Namespace**: `minio` (tenant), `minio-operator` (operator)
- **Features**:
  - S3 API compatible
  - OIDC authentication via Keycloak
  - STS (Security Token Service) for temporary credentials
  - Policy-based access control

### 4. JupyterHub (Data Science Notebooks)
- **Purpose**: Interactive data science environment
- **Namespace**: `jupyterhub` (hub), `jupyterhub-users` (user pods)
- **Features**:
  - OAuth authentication via Keycloak
  - Automatic MinIO STS credential injection
  - Per-user notebook servers
  - Pre-configured data science environment

### 5. Spark Operator (Distributed Computing)
- **Purpose**: Run distributed Spark jobs on Kubernetes
- **Namespace**: `operators`
- **Features**:
  - SparkApplication CRD for job management
  - Spark Connect server support
  - Integration with MinIO for data access

### 6. Dremio (Data Lakehouse Query Engine)
- **Purpose**: SQL query engine for data lake
- **Namespace**: `dremio`
- **Features**:
  - SQL interface to MinIO data
  - Data virtualization
  - Query acceleration
  - OIDC authentication via Keycloak

---

## Authentication Flow

```
┌────────────────────────────────────────────────────────────────────────────┐
│                          Authentication Architecture                         │
├────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│     User                                                                    │
│       │                                                                     │
│       ▼                                                                     │
│  ┌─────────┐                                                                │
│  │ Browser │                                                                │
│  └────┬────┘                                                                │
│       │                                                                     │
│       │  1. Access Service                                                  │
│       ▼                                                                     │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                         Keycloak (IdP)                               │   │
│  │                                                                      │   │
│  │  Realm: vault                                                        │   │
│  │  ┌──────────────────────────────────────────────────────────────┐   │   │
│  │  │ Clients:                                                      │   │   │
│  │  │  • vault      → Vault OIDC login                             │   │   │
│  │  │  • minio      → MinIO Console + STS                          │   │   │
│  │  │  • jupyterhub → JupyterHub OAuth                             │   │   │
│  │  │  • dremio     → Dremio OIDC (future)                         │   │   │
│  │  └──────────────────────────────────────────────────────────────┘   │   │
│  │  ┌──────────────────────────────────────────────────────────────┐   │   │
│  │  │ Groups:                                                       │   │   │
│  │  │  • vault-admins  → Full Vault access                         │   │   │
│  │  │  • minio-access  → MinIO bucket access                       │   │   │
│  │  │  • jupyterhub    → JupyterHub access                         │   │   │
│  │  └──────────────────────────────────────────────────────────────┘   │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│       │                                                                     │
│       │  2. OIDC Token                                                      │
│       ▼                                                                     │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │              Service validates token & grants access                 │   │
│  │                                                                      │   │
│  │   Vault        MinIO        JupyterHub        Dremio                │   │
│  │    ✓            ✓               ✓              (future)             │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
└────────────────────────────────────────────────────────────────────────────┘
```

---

## Data Flow

### JupyterHub → MinIO (STS Integration)

```
┌─────────┐     ┌─────────────┐     ┌──────────┐     ┌───────┐
│  User   │────▶│ JupyterHub  │────▶│ Keycloak │────▶│ MinIO │
└─────────┘     └─────────────┘     └──────────┘     └───────┘
                      │                   │              │
                      │  1. OAuth Login   │              │
                      │─────────────────▶│              │
                      │                   │              │
                      │  2. ID Token      │              │
                      │◀─────────────────│              │
                      │                   │              │
                      │  3. STS Request (ID Token)       │
                      │─────────────────────────────────▶│
                      │                                  │
                      │  4. Temp Credentials             │
                      │◀─────────────────────────────────│
                      │                                  │
                      │  5. Inject into Notebook env     │
                      ▼                                  │
               ┌─────────────┐                          │
               │  Notebook   │  6. S3 Access            │
               │   Server    │─────────────────────────▶│
               └─────────────┘                          │
```

**Environment variables injected into notebooks:**
- `AWS_ACCESS_KEY_ID` - Temporary access key
- `AWS_SECRET_ACCESS_KEY` - Temporary secret key  
- `AWS_SESSION_TOKEN` - Session token
- `MINIO_ENDPOINT` - MinIO API endpoint

---

## Namespace Layout

| Namespace | Components | Purpose |
|-----------|------------|---------|
| `operators` | Keycloak, Keycloak Operator, PostgreSQL, Spark Operator | Core infrastructure operators |
| `vault` | Vault | Secrets management |
| `minio-operator` | MinIO Operator | MinIO lifecycle management |
| `minio` | MinIO Tenant | Object storage |
| `jupyterhub` | Hub, Proxy | JupyterHub control plane |
| `jupyterhub-users` | User notebook pods | User workloads |
| `dremio` | Dremio coordinators, executors | Query engine |

---

## Persistent Storage

| Component | Volume Size | Data Stored |
|-----------|-------------|-------------|
| PostgreSQL (Keycloak) | 2Gi | Realms, users, clients, sessions |
| Vault | 1Gi | Secrets, policies, auth config |
| MinIO | Configurable | Object data, bucket metadata |
| Dremio | Configurable | Metadata, reflections, job history |

---

## Network Architecture

### Internal Communication
All services communicate within the cluster using Kubernetes DNS:
- `keycloak-service.operators.svc.cluster.local:8080`
- `vault.vault.svc.cluster.local:8200`
- `minio.minio.svc.cluster.local:443`

### External Access (Port Forwards)
| Service | Local Port | Remote Port | URL |
|---------|------------|-------------|-----|
| Keycloak | 8080 | 8080 | http://localhost:8080 |
| Vault | 8200 | 8200 | http://localhost:8200 |
| MinIO Console | 9091 | 9443 | https://localhost:9091 |
| MinIO API | 9000 | 443 | https://localhost:9000 |
| JupyterHub | 8000 | 80 | http://localhost:8000 |
| Dremio | 9047 | 9047 | http://localhost:9047 |

---

## Deployment Scripts

| Script | Purpose |
|--------|---------|
| `deploy-gke.sh` | Deploy Keycloak + Vault with OIDC integration |
| `deploy-minio-gke.sh` | Deploy MinIO with OIDC + STS |
| `deploy-jupyterhub-gke.sh` | Deploy JupyterHub with OAuth + MinIO STS |
| `deploy-spark-operator.sh` | Deploy Spark Operator |
| `deploy-dremio-ee.sh` | Deploy Dremio Enterprise |
| `start-port-forwards.sh` | Start all port forwards |

---

## Security Model

### Authentication
- **Single Sign-On**: All services authenticate via Keycloak OIDC
- **Token-based**: OIDC tokens validate user identity
- **Session management**: Keycloak manages session lifecycle

### Authorization
- **Group-based**: Access controlled by Keycloak group membership
- **Policy-based**: MinIO and Vault use policies tied to groups
- **Least privilege**: Users get minimum required permissions

### Secrets
- **Centralized**: All secrets stored in Vault
- **Dynamic**: STS provides time-limited credentials
- **Encrypted**: Vault encrypts secrets at rest
