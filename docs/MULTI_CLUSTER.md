# Managing Multiple Minikube Clusters

Minikube supports multiple clusters using **profiles**. Each profile is an independent cluster with its own resources.

---

## Quick Reference

```bash
# List all profiles
minikube profile list

# Create/start a specific profile
minikube start -p <profile-name>

# Switch to a profile
minikube profile <profile-name>

# Check current profile
minikube profile

# Delete a profile
minikube delete -p <profile-name>
```

---

## Example: Multiple Environments

### Scenario: Dev, Staging, and Production

#### 1. Create Three Clusters

```bash
# Development cluster
minikube start -p dev --cpus 2 --memory 4096

# Staging cluster (same as production)
minikube start -p staging --cpus 4 --memory 8192

# Production cluster
minikube start -p production --cpus 4 --memory 8192
```

#### 2. Deploy to Each Cluster

For **dev** cluster:
```bash
# Switch to dev profile
minikube profile dev

# Enable ingress
minikube addons enable ingress

# Deploy your stack
kubectl create namespace operators
kubectl create namespace vault
# ... continue with deployment
```

For **staging** cluster:
```bash
# Switch to staging profile
minikube profile staging

# Enable ingress
minikube addons enable ingress

# Deploy your stack
kubectl create namespace operators
kubectl create namespace vault
# ... continue with deployment
```

#### 3. Switch Between Clusters

```bash
# Work on dev
minikube profile dev
kubectl get pods -A

# Work on staging
minikube profile staging
kubectl get pods -A

# Work on production
minikube profile production
kubectl get pods -A
```

---

## Managing Multiple Keycloak/Vault Deployments

### Option 1: Different Profiles (Recommended)

Each profile is completely isolated:

```bash
# Dev environment
minikube start -p keycloak-dev --cpus 2 --memory 4096
minikube profile keycloak-dev
# Deploy Keycloak + Vault

# Test environment
minikube start -p keycloak-test --cpus 4 --memory 8192
minikube profile keycloak-test
# Deploy Keycloak + Vault
```

**Pros:**
- Complete isolation
- Different resource allocations
- Can run simultaneously
- Independent configurations

**Cons:**
- More resource usage
- Need to manage multiple vault-keys.json files

### Option 2: Same Cluster, Different Namespaces

Deploy multiple instances in the same cluster:

```bash
# Keycloak Dev
kubectl create namespace keycloak-dev
kubectl create namespace vault-dev

# Keycloak Staging
kubectl create namespace keycloak-staging
kubectl create namespace vault-staging
```

**Pros:**
- Less resource usage
- Single cluster to manage

**Cons:**
- Shared resources
- Port conflicts (need different ports)
- Less isolation

---

## Best Practices for Multiple Profiles

### 1. Naming Convention

```bash
minikube start -p <project>-<environment>
```

Examples:
- `myapp-dev`
- `myapp-staging`
- `myapp-prod`
- `keycloak-dev`
- `keycloak-test`

### 2. Resource Allocation

```bash
# Development (minimal)
minikube start -p dev --cpus 2 --memory 4096

# Staging (production-like)
minikube start -p staging --cpus 4 --memory 8192

# Production (full resources)
minikube start -p prod --cpus 8 --memory 16384
```

### 3. Organize Configuration Files

```
project/
├── dev/
│   ├── vault-keys.json
│   ├── keycloak-vault-client-secret.txt
│   └── .env
├── staging/
│   ├── vault-keys.json
│   ├── keycloak-vault-client-secret.txt
│   └── .env
└── production/
    ├── vault-keys.json
    ├── keycloak-vault-client-secret.txt
    └── .env
```

### 4. Port Management

Use different ports for each environment:

**Dev:**
```bash
kubectl port-forward -n operators svc/keycloak-service 8080:8080 &
kubectl port-forward -n vault svc/vault-ui 8200:8200 &
```

**Staging:**
```bash
kubectl port-forward -n operators svc/keycloak-service 8081:8080 &
kubectl port-forward -n vault svc/vault-ui 8201:8200 &
```

**Production:**
```bash
kubectl port-forward -n operators svc/keycloak-service 8082:8080 &
kubectl port-forward -n vault svc/vault-ui 8202:8200 &
```

---

## Useful Commands

### List All Profiles
```bash
minikube profile list
```

Output:
```
|----------|-----------|---------|--------------|------|---------|---------|-------|--------|
| Profile  | VM Driver | Runtime |      IP      | Port | Version | Status  | Nodes | Active |
|----------|-----------|---------|--------------|------|---------|---------|-------|--------|
| dev      | docker    | docker  | 192.168.49.2 | 8443 | v1.34.0 | Running |     1 |        |
| staging  | docker    | docker  | 192.168.49.3 | 8443 | v1.34.0 | Running |     1 | *      |
| prod     | docker    | docker  | 192.168.49.4 | 8443 | v1.34.0 | Stopped |     1 |        |
|----------|-----------|---------|--------------|------|---------|---------|-------|--------|
```

### Check Current Profile
```bash
minikube profile
```

### Get Cluster Info for Specific Profile
```bash
minikube -p dev status
minikube -p staging status
```

### Stop/Start Specific Profile
```bash
minikube stop -p dev
minikube start -p dev
```

### Delete Specific Profile
```bash
minikube delete -p dev
```

---

## kubectl Context Management

Each Minikube profile creates a kubectl context:

```bash
# List all contexts
kubectl config get-contexts

# Switch context
kubectl config use-context dev
kubectl config use-context staging

# Current context
kubectl config current-context
```

---

## Example: Multi-Environment Setup Script

Save as `setup-multi-env.sh`:

```bash
#!/bin/bash

ENVIRONMENTS=("dev" "staging" "prod")
DEV_CPUS=2
DEV_MEM=4096
STAGING_CPUS=4
STAGING_MEM=8192
PROD_CPUS=4
PROD_MEM=8192

for env in "${ENVIRONMENTS[@]}"; do
    echo "Setting up $env environment..."
    
    # Set resources based on environment
    if [ "$env" = "dev" ]; then
        CPUS=$DEV_CPUS
        MEM=$DEV_MEM
    elif [ "$env" = "staging" ]; then
        CPUS=$STAGING_CPUS
        MEM=$STAGING_MEM
    else
        CPUS=$PROD_CPUS
        MEM=$PROD_MEM
    fi
    
    # Start cluster
    minikube start -p keycloak-$env --cpus $CPUS --memory $MEM
    
    # Switch to profile
    minikube profile keycloak-$env
    
    # Enable ingress
    minikube addons enable ingress
    
    # Create directory for configs
    mkdir -p $env
    
    echo "✓ $env environment ready"
done

echo "All environments created!"
minikube profile list
```

---

## Switching Between Environments

### Quick Switch Script

Save as `switch-env.sh`:

```bash
#!/bin/bash

ENV=$1

if [ -z "$ENV" ]; then
    echo "Usage: ./switch-env.sh <dev|staging|prod>"
    echo "Current profile: $(minikube profile)"
    exit 1
fi

PROFILE="keycloak-$ENV"

# Switch profile
minikube profile $PROFILE

# Show status
echo "Switched to $PROFILE"
minikube status

# Show kubectl context
echo "kubectl context: $(kubectl config current-context)"
```

Usage:
```bash
./switch-env.sh dev
./switch-env.sh staging
./switch-env.sh prod
```

---

## Managing Vault Keys for Multiple Environments

```bash
# Save keys per environment
kubectl exec -n vault vault-0 -- vault operator init \
    -key-shares=1 -key-threshold=1 -format=json > dev/vault-keys.json

# When switching environments
ENV=dev
UNSEAL_KEY=$(cat $ENV/vault-keys.json | jq -r '.unseal_keys_b64[0]')
kubectl exec -n vault vault-0 -- vault operator unseal $UNSEAL_KEY
```

---

## Summary

**For multiple isolated environments:**
- Use different Minikube profiles (`-p` flag)
- Each profile is a separate cluster
- Switch with `minikube profile <name>`

**For multiple deployments in one cluster:**
- Use different namespaces
- Manage port conflicts
- Less resource intensive

**Recommended approach:** Use profiles for true isolation between dev/staging/prod.
