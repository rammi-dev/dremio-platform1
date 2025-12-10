# Fresh Deployment Task Checklist

## Cluster Setup
- [x] Delete existing Minikube cluster
- [ ] Start Minikube with keycloak-vault profile
- [ ] Enable ingress addon
- [ ] Verify cluster is running

## Keycloak Deployment
- [ ] Create namespaces
- [ ] Apply Keycloak CRDs
- [ ] Deploy Keycloak operator
- [ ] Deploy PostgreSQL with persistent storage
- [ ] Deploy Keycloak instance
- [ ] Get admin credentials

## Vault Deployment
- [ ] Create vault namespace
- [ ] Add HashiCorp Helm repository
- [ ] Install Vault
- [ ] Initialize Vault
- [ ] Unseal Vault
- [ ] Save credentials

## Configuration
- [ ] Start port-forwards
- [ ] Configure Keycloak vault realm
- [ ] Create OIDC client
- [ ] Create vault-admins group
- [ ] Create admin user
- [ ] Configure Vault OIDC
- [ ] Create group mappings

## Verification
- [ ] Test Keycloak access
- [ ] Test Vault OIDC login
- [ ] Verify data persistence
