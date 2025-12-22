# Keycloak & Vault on Minikube

Deployment of Keycloak and HashiCorp Vault on Minikube with OIDC integration and full data persistence.

## Features

- ✅ **Full Data Persistence**: PostgreSQL (2Gi) and Vault (1Gi) with persistent storage
- ✅ **OIDC Integration**: Vault authenticates via Keycloak
- ✅ **Multi-Environment Support**: Minikube profiles for dev/staging/prod
- ✅ **Automated Deployment**: One-command setup
- ✅ **Persistent**: StatefulSets with persistent volumes

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

- **[QUICK_REFERENCE.md](docs/QUICK_REFERENCE.md)** - Quick access to all credentials and commands
- **[CREDENTIALS.md](docs/CREDENTIALS.md)** - All access credentials and URLs
- **[setup_guide.md](docs/setup_guide.md)** - Detailed step-by-step setup
- **[RESTART_GUIDE.md](docs/RESTART_GUIDE.md)** - Restart procedure
- **[MULTI_CLUSTER.md](docs/MULTI_CLUSTER.md)** - Managing multiple environments
- **[OIDC_LOGIN_GUIDE.md](docs/OIDC_LOGIN_GUIDE.md)** - OIDC login troubleshooting
- **[WINDOWS_SETUP.md](docs/WINDOWS_SETUP.md)** - Windows-specific configuration

## Scripts

- **[deploy.sh](scripts/deploy.sh)** - Complete automated deployment (all-in-one)
- **[restart.sh](scripts/restart.sh)** - Restart after `minikube stop`
- **[switch-env.sh](scripts/switch-env.sh)** - Switch between profiles

## Data Persistence

All data persists across Minikube restarts:

- **PostgreSQL**: 2Gi persistent volume (Keycloak realms, users, clients)
- **Vault**: 1Gi persistent volume (secrets, OIDC config, policies)

After `minikube stop` and `minikube start`, just run `./scripts/restart.sh` to unseal Vault and restart port-forwards. No reconfiguration needed!

## Clean Up

```bash
# Delete specific profile
minikube delete -p keycloak-vault

# Delete all
minikube delete --all
```
