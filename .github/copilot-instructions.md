# Copilot Instructions for Data Platform on GKE

## Repository Overview

This repository provides a data platform deployed on Google Kubernetes Engine (GKE) with centralized identity management, secrets management, object storage, distributed computing, and SQL analytics.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         GKE Cluster                              │
├─────────────────────────────────────────────────────────────────┤
│  Identity & Security    │  Storage    │  Data Processing        │
│  ├── Keycloak (OIDC)    │  └── MinIO  │  ├── JupyterHub         │
│  └── Vault (Secrets)    │             │  ├── Spark Operator     │
│                         │             │  └── Dremio             │
└─────────────────────────────────────────────────────────────────┘
```

### Components

| Component | Purpose | Namespace |
|-----------|---------|-----------|
| **Keycloak** | Identity Provider (OIDC/OAuth) | `operators` |
| **Vault** | Secrets Management | `vault` |
| **MinIO** | S3-Compatible Object Storage | `minio` |
| **JupyterHub** | Interactive Notebooks | `jupyterhub` |
| **Spark Operator** | Distributed Computing | `operators` |
| **Dremio** | SQL Analytics Engine | `dremio` |

## Project Structure

```
.
├── helm/                      # Helm charts and configurations
│   ├── keycloak/
│   │   ├── values.yaml
│   │   └── manifests/         # CRDs, operator, realm import
│   ├── vault/
│   │   └── values.yaml
│   ├── minio/
│   │   ├── operator-values.yaml
│   │   └── tenant-values.yaml
│   ├── jupyterhub/
│   │   └── values.yaml
│   ├── spark/
│   │   └── Chart.yaml
│   ├── dremio/
│   │   └── values.yaml
│   └── postgres/
│       └── postgres-for-keycloak.yaml
├── scripts/                   # Deployment and utility scripts
│   ├── deploy-gke.sh          # Deploy Keycloak + Vault
│   ├── deploy-minio-gke.sh    # Deploy MinIO with OIDC
│   ├── deploy-jupyterhub-gke.sh # Deploy JupyterHub with OAuth
│   ├── deploy-spark-operator.sh # Deploy Spark Operator
│   ├── deploy-dremio-ee.sh    # Deploy Dremio Enterprise
│   ├── start-port-forwards.sh # Start all port forwards
│   ├── show-access-info.sh    # Display credentials
│   ├── get-minio-sts-credentials.sh # Get MinIO STS tokens
│   ├── cleanup-dremio-namespace.sh # Clean stuck namespaces
│   └── lib/                   # Shared bash functions
│       ├── minio-common.sh
│       ├── jupyterhub-common.sh
│       └── dremio-common.sh
├── docs/                      # Documentation
│   ├── ARCHITECTURE.md        # Architecture with Mermaid diagrams
│   ├── ACCESS.md              # Credentials and access control
│   ├── DEPLOYMENT.md          # GKE deployment guide
│   ├── GITOPS_PROPOSAL.md     # GitOps transformation plan
│   └── ...
├── config/                    # Generated configs (gitignored)
│   ├── vault-keys.json
│   └── keycloak-vault-client-secret.txt
└── README.md
```

## Key Technologies

- **Google Kubernetes Engine (GKE)**: Container orchestration
- **Helm**: Package management for Kubernetes
- **Keycloak Operator**: Kubernetes operator for managing Keycloak
- **HashiCorp Vault**: Secrets management
- **MinIO Operator**: S3-compatible object storage
- **Spark Operator**: Distributed computing on Kubernetes
- **OIDC/OAuth**: Authentication protocol for all services

## Development Guidelines

### Code Style

1. **Shell Scripts**:
   - Use `set -e` for error handling
   - Include descriptive echo statements for progress
   - Source shared libraries from `scripts/lib/`
   - Use `kubectl wait` for pod readiness
   - Handle port-forward lifecycle properly

2. **YAML Files**:
   - Use 2-space indentation
   - Follow Kubernetes resource naming conventions
   - Include descriptive labels and annotations
   - Reference secrets via Kubernetes Secrets, not hardcoded values

3. **Documentation**:
   - Use Mermaid diagrams for architecture visualization
   - Keep README.md concise with links to detailed docs
   - Document all credentials in `docs/ACCESS.md`

### Namespaces

| Namespace | Components |
|-----------|------------|
| `operators` | Keycloak, Keycloak Operator, PostgreSQL, Spark Operator |
| `vault` | Vault |
| `minio-operator` | MinIO Operator |
| `minio` | MinIO Tenant |
| `jupyterhub` | JupyterHub Hub, Proxy |
| `jupyterhub-users` | User notebook pods |
| `dremio` | Dremio coordinators, executors |

### Deployment Order

1. `deploy-gke.sh` - Keycloak + Vault (creates OIDC foundation)
2. `deploy-minio-gke.sh` - MinIO (depends on Keycloak for OIDC)
3. `deploy-jupyterhub-gke.sh` - JupyterHub (depends on Keycloak + MinIO)
4. `deploy-spark-operator.sh` - Spark Operator
5. `deploy-dremio-ee.sh` - Dremio (optional, requires license)

### Authentication Flow

1. User authenticates with **Keycloak** (OIDC)
2. Keycloak issues ID Token with user groups
3. Services validate tokens and apply group-based policies
4. MinIO STS provides temporary S3 credentials

### Key Credentials

| Service | Location |
|---------|----------|
| Keycloak (master) | `kubectl get secret keycloak-initial-admin -n operators` |
| Keycloak (vault realm) | `admin` / `admin` |
| Vault root token | `config/vault-keys.json` |
| MinIO | Login with OpenID via Keycloak |

### Port Forwards

| Service | Local Port | Command |
|---------|------------|---------|
| Keycloak | 8080 | `kubectl port-forward -n operators svc/keycloak-service 8080:8080` |
| Vault | 8200 | `kubectl port-forward -n vault svc/vault 8200:8200` |
| MinIO Console | 9091 | `kubectl port-forward -n minio svc/minio-console 9091:9443` |
| JupyterHub | 8000 | `kubectl port-forward -n jupyterhub svc/proxy-public 8000:80` |
| Dremio | 9047 | `kubectl port-forward -n dremio svc/dremio-client 9047:9047` |

### Common Tasks

#### Deploy Full Platform
```bash
./scripts/deploy-gke.sh
./scripts/deploy-minio-gke.sh
./scripts/deploy-jupyterhub-gke.sh
./scripts/deploy-spark-operator.sh
```

#### Start Port Forwards
```bash
./scripts/start-port-forwards.sh
```

#### Show All Credentials
```bash
./scripts/show-access-info.sh
```

#### Check Pod Status
```bash
kubectl get pods -A | grep -E '^(operators|vault|minio|jupyterhub|dremio)'
```

### Security Considerations

- Never commit secrets or credentials to Git
- Keep `config/` directory in `.gitignore`
- Use Kubernetes Secrets for sensitive data
- Use OIDC/OAuth for authentication where possible
- Use MinIO STS for temporary S3 credentials

### Future Direction: GitOps

See `docs/GITOPS_PROPOSAL.md` for the planned transition to:
- Argo CD for declarative deployments
- External Secrets Operator with Vault backend
- Kustomize overlays for environments (dev/staging/prod)
- Removal of imperative deployment scripts

## Additional Resources

- Main documentation: `README.md`
- Architecture details: `docs/ARCHITECTURE.md`
- Access & credentials: `docs/ACCESS.md`
- Deployment guide: `docs/DEPLOYMENT.md`
- GitOps roadmap: `docs/GITOPS_PROPOSAL.md`
