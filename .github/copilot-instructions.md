# Copilot Instructions for Keycloak & Vault on Minikube

## Repository Overview

This repository provides a production-ready deployment of Keycloak and HashiCorp Vault on Minikube with OIDC integration and full data persistence. It's designed for development, testing, and reference implementation purposes.

## Architecture

- **Keycloak**: Identity and access management with PostgreSQL backend (2Gi persistent storage)
- **Vault**: Secrets management with file storage backend (1Gi persistent storage)
- **PostgreSQL**: Database for Keycloak with persistent volumes
- **OIDC Integration**: Vault authenticates via Keycloak
- **MinIO**: Optional object storage with OIDC authentication (add-on feature)
- **Deployment Platform**: Minikube with Kubernetes

## Project Structure

```
.
├── helm/                      # Helm charts and Kubernetes manifests
│   ├── keycloak/
│   │   ├── values.yaml        # Keycloak Helm configuration
│   │   └── manifests/         # Keycloak CRDs and operator
│   ├── vault/
│   │   └── values.yaml        # Vault Helm configuration
│   ├── postgres/
│   │   ├── values.yaml        # PostgreSQL configuration
│   │   └── postgres-for-keycloak.yaml
│   └── minio/                 # Optional MinIO deployment
├── scripts/                   # Deployment and management scripts
│   ├── deploy.sh              # Main deployment script
│   ├── restart.sh             # Restart after minikube stop
│   ├── switch-env.sh          # Switch between profiles
│   ├── deploy-minio.sh        # Deploy MinIO (optional)
│   └── restart-minio.sh       # Restart MinIO
├── docs/                      # Documentation
├── config/                    # Generated configs (gitignored)
└── charts/                    # Helm chart dependencies
```

## Key Technologies

- **Kubernetes/Minikube**: Container orchestration
- **Helm**: Package management for Kubernetes
- **Shell Scripts**: Bash scripts for automation
- **YAML**: Configuration files for Kubernetes resources
- **Keycloak Operator**: Kubernetes operator for managing Keycloak
- **HashiCorp Vault**: Secrets management

## Development Guidelines

### Code Style

1. **Shell Scripts**:
   - Use `set -e` for error handling
   - Include descriptive echo statements for progress
   - Use meaningful variable names
   - Profile name defaults to `keycloak-vault` with `MINIKUBE_PROFILE` override
   - Include validation steps with `kubectl wait` commands

2. **YAML Files**:
   - Use 2-space indentation
   - Follow Kubernetes resource naming conventions
   - Include descriptive labels and annotations
   - Use namespaces: `operators`, `keycloak`, `vault`, `minio`

3. **Documentation**:
   - Keep README.md up to date with any changes
   - Update relevant docs in `docs/` directory
   - Include clear examples and troubleshooting steps
   - Document credentials and access information

### Common Tasks

#### Deployment
- Main deployment: `./scripts/deploy.sh`
- MinIO deployment: `./scripts/deploy-minio.sh`
- Use profile-based deployment for multiple environments

#### Testing
- Test deployments in Minikube profiles
- Verify with `kubectl get pods -A` and `kubectl wait` commands
- Test port-forwards and service accessibility
- Validate OIDC authentication flows

#### Restart Procedures
- After minikube restart: `./scripts/restart.sh`
- Vault unsealing is handled automatically
- Port-forwards need to be restarted

### Important Conventions

1. **Namespaces**:
   - `operators`: Keycloak operator, PostgreSQL
   - `keycloak`: Keycloak instances
   - `vault`: Vault instances
   - `minio`: MinIO instances (optional)

2. **Persistent Storage**:
   - PostgreSQL: 2Gi PVC for Keycloak data
   - Vault: 1Gi PVC for secrets
   - Data persists across Minikube restarts

3. **Secrets Management**:
   - Generated configs go in `config/` directory (gitignored)
   - Use Kubernetes secrets for sensitive data
   - Vault root token stored in `config/vault-keys.json`

4. **Port Forwarding**:
   - Keycloak: 8080
   - Vault: 8200
   - MinIO Console: 9001
   - MinIO API: 9000

5. **Credentials**:
   - Keycloak has TWO realms: master (admin) and vault (app users)
   - Master realm password is dynamically generated
   - Vault realm uses `admin`/`admin` for OIDC
   - Document all credentials in CREDENTIALS.md

### Making Changes

When modifying this repository:

1. **Scripts**: Test thoroughly in a clean Minikube profile
2. **Kubernetes Manifests**: Validate with `kubectl apply --dry-run=client`
3. **Helm Values**: Ensure compatibility with chart versions
4. **Documentation**: Update all affected documentation files
5. **Multi-Environment**: Consider impact on multiple profiles

### Security Considerations

- Never commit secrets or credentials
- Keep `config/` directory in `.gitignore`
- Use Kubernetes secrets for sensitive data
- Document secure credential retrieval methods
- Use OIDC for authentication where possible

### Troubleshooting

Common issues and locations to check:
- Vault unsealing: Check `scripts/restart.sh`
- OIDC login: Check `docs/OIDC_LOGIN_GUIDE.md`
- Windows issues: Check `docs/WINDOWS_SETUP.md`
- Multi-cluster: Check `docs/MULTI_CLUSTER.md`

### Testing and Validation

- Validate Kubernetes manifests before applying
- Test scripts in isolation before integration
- Verify persistent storage after restarts
- Test OIDC flows end-to-end
- Check all port-forwards are working

## Additional Resources

- Main documentation: `README.md`
- Quick reference: `docs/QUICK_REFERENCE.md`
- Detailed setup: `docs/setup_guide.md`
- All credentials: `docs/CREDENTIALS.md`
