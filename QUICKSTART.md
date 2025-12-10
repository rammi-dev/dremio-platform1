# Quick Start Guide

## One-Command Deployment

```bash
./deploy-all.sh
```

This script will:
1. Start Minikube
2. Deploy Keycloak with PostgreSQL
3. Deploy Vault
4. Configure Keycloak OIDC for Vault
5. Set up all integrations

## Manual Step Required (Windows Only)

Add to `C:\Windows\System32\drivers\etc\hosts`:
```
127.0.0.1 keycloak-service.operators.svc.cluster.local
```

See `FIX_VAULT_DNS.md` for detailed instructions.

## Access

**Start port-forwards** (in separate terminals or background):
```bash
kubectl port-forward -n operators svc/keycloak-service 8080:8080 --address=0.0.0.0 &
kubectl port-forward -n vault svc/vault-ui 8200:8200 --address=0.0.0.0 &
```

**Keycloak**: http://localhost:8080
- Initial credentials in deployment output
- Create permanent admin user (see KEYCLOAK_SETUP.md)

**Vault**: http://localhost:8200
- Method: OIDC
- Login with Keycloak admin credentials

## Credentials

All credentials saved in:
- `vault-keys.json` - Vault root token and unseal key
- `keycloak-vault-client-secret.txt` - OIDC client secret

## Detailed Guides

- `README.md` - Complete installation guide
- `KEYCLOAK_SETUP.md` - Keycloak configuration
- `VAULT_TEST.md` - Vault testing guide
- `FIX_VAULT_DNS.md` - Windows hosts file setup
