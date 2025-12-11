# Keycloak & Vault on Minikube

Production-ready deployment of Keycloak and HashiCorp Vault on Minikube with OIDC integration and full data persistence.

## Features

- ✅ **Full Data Persistence**: PostgreSQL (2Gi) and Vault (1Gi) with persistent storage
- ✅ **OIDC Integration**: Vault authenticates via Keycloak
- ✅ **Multi-Environment Support**: Minikube profiles for dev/staging/prod
- ✅ **Automated Deployment**: One-command setup
- ✅ **Production-Ready**: StatefulSets with persistent volumes

## Quick Start

```bash
# Deploy everything
./scripts/deploy.sh

# Access services
# Keycloak: http://localhost:8080
# Vault: http://localhost:8200
```

## Architecture

```
┌─────────────────────────────────────────┐
│         Minikube (keycloak-vault)       │
│                                         │
│  ┌──────────────┐    ┌──────────────┐  │
│  │  Keycloak    │◄───┤    Vault     │  │
│  │  + PostgreSQL│OIDC│              │  │
│  │  (2Gi PV)    │    │  (1Gi PV)    │  │
│  └──────────────┘    └──────────────┘  │
└─────────────────────────────────────────┘
```

## Prerequisites

- Minikube
- kubectl
- Helm
- jq
- curl

**Windows Users**: See [docs/WINDOWS_SETUP.md](docs/WINDOWS_SETUP.md) for required hosts file configuration.

## Usage

### Initial Deployment

```bash
# Default profile (keycloak-vault)
./scripts/deploy.sh

# Custom profile
MINIKUBE_PROFILE=my-env ./scripts/deploy.sh
```

### After Restart

```bash
# Restart everything (unseal Vault, start port-forwards)
./scripts/restart.sh
```

### Multiple Environments

```bash
# Create different profiles
minikube start -p dev --cpus 2 --memory 4096
minikube start -p staging --cpus 4 --memory 8192

# Switch between them
./scripts/switch-env.sh dev
./scripts/switch-env.sh staging
```

## Access

### Keycloak

> **Important**: Keycloak has **two separate realms** with different credentials:

**Master Realm** (Keycloak Admin Console):
- **URL**: http://localhost:8080
- **Username**: `temp-admin`
- **Password**: *Dynamically generated* - retrieve with:
  ```bash
  kubectl get secret keycloak-initial-admin -n operators -o jsonpath='{.data.password}' | base64 -d
  ```

**Vault Realm** (Application Users):
- **URL**: http://localhost:8080/realms/vault
- **Username**: `admin`
- **Password**: `admin`
- **Purpose**: Login to Vault and MinIO via OIDC
- **Note**: This user does NOT work for the master realm admin console

### Vault
- **URL**: http://localhost:8200
- **Root Token**: See `config/vault-keys.json`
- **OIDC Login**: Method=OIDC, Role=`admin`, then login with `admin`/`admin`

## Documentation

- **[GKE_DEPLOYMENT_GUIDE.md](docs/GKE_DEPLOYMENT_GUIDE.md)** - Complete GKE deployment and testing guide
- **[QUICK_REFERENCE.md](docs/QUICK_REFERENCE.md)** - Quick access to all credentials and commands
- **[CREDENTIALS.md](docs/CREDENTIALS.md)** - All access credentials and URLs
- **[setup_guide.md](docs/setup_guide.md)** - Detailed step-by-step setup
- **[RESTART_GUIDE.md](docs/RESTART_GUIDE.md)** - Restart procedure
- **[MULTI_CLUSTER.md](docs/MULTI_CLUSTER.md)** - Managing multiple environments
- **[OIDC_LOGIN_GUIDE.md](docs/OIDC_LOGIN_GUIDE.md)** - OIDC login troubleshooting
- **[WINDOWS_SETUP.md](docs/WINDOWS_SETUP.md)** - Windows-specific configuration
- **[walkthrough.md](docs/walkthrough.md)** - Complete deployment walkthrough


## Scripts

- **[deploy.sh](scripts/deploy.sh)** - Complete automated deployment (all-in-one)
- **[restart.sh](scripts/restart.sh)** - Restart after `minikube stop`
- **[switch-env.sh](scripts/switch-env.sh)** - Switch between profiles

## Data Persistence

All data persists across Minikube restarts:

- **PostgreSQL**: 2Gi persistent volume (Keycloak realms, users, clients)
- **Vault**: 1Gi persistent volume (secrets, OIDC config, policies)

After `minikube stop` and `minikube start`, just run `./scripts/restart.sh` to unseal Vault and restart port-forwards. No reconfiguration needed!

## Project Structure

```
.
├── helm/                   # Helm charts and Kubernetes manifests
│   ├── vault/
│   │   └── values.yaml     # Vault Helm values
│   ├── keycloak/
│   │   ├── values.yaml     # Keycloak Helm values
│   │   └── manifests/      # Keycloak K8s manifests
│   │       ├── keycloak-crd.yml
│   │       ├── keycloak-realm-crd.yml
│   │       ├── keycloak-operator.yml
│   │       └── keycloak-instance.yaml
│   └── postgres/
│       ├── values.yaml                 # PostgreSQL configuration
│       └── postgres-for-keycloak.yaml  # PostgreSQL for Keycloak
├── scripts/                # Deployment and management scripts
│   ├── deploy.sh           # Main deployment script
│   ├── restart.sh          # Restart script
│   └── switch-env.sh       # Profile switcher
├── docs/                   # Documentation
│   ├── CREDENTIALS.md      # Access credentials
│   ├── setup_guide.md      # Detailed setup guide
│   ├── RESTART_GUIDE.md    # Restart instructions
│   └── *.md                # Other guides
├── config/                 # Generated configuration (gitignored)
│   ├── vault-keys.json     # Vault credentials
│   └── keycloak-vault-client-secret.txt
└── README.md               # This file
```

## Troubleshooting

### Vault OIDC Login Fails
- Ensure role is set to `admin`
- Windows: Check hosts file (see [WINDOWS_SETUP.md](docs/WINDOWS_SETUP.md))
- Verify port-forwards are running

### After Restart
- Vault will be sealed - run `./scripts/restart.sh`
- Port-forwards need to be restarted
- All data persists automatically

### Feature: MinIO Object Storage (Add-on)
This project includes an optional MinIO integration with OIDC authentication (via Keycloak).

See **[helm/minio/README.md](helm/minio/README.md)** for deployment, access, and troubleshooting instructions.

**Quick Command:**
```bash
./scripts/deploy-minio.sh
```
### Multiple Clusters
- Use different profiles: `minikube start -p <name>`
- Switch with: `./scripts/switch-env.sh <name>`
- See [MULTI_CLUSTER.md](docs/MULTI_CLUSTER.md) for details

## Clean Up

```bash
# Delete specific profile
minikube delete -p keycloak-vault

# Delete all
minikube delete --all
```

## Important Files

Generated during deployment (stored in `config/`):
- `config/vault-keys.json` - Vault root token and unseal key
- `config/keycloak-vault-client-secret.txt` - OIDC client secret

(Note: These files are generated by `scripts/deploy.sh` and are ignored by `.gitignore` for security.)

## License

This is a reference implementation for development and testing purposes.
