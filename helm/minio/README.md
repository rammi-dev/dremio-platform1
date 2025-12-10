# MinIO Object Storage with Keycloak OIDC

This add-on deploys a production-ready MinIO Tenant managed by the official MinIO Operator, fully integrated with Keycloak for OIDC authentication.

## Features
- **Official Operator**: Uses `minio-operator` and `minio-tenant` Helm charts.
- **OIDC Authentication**: Console login via Keycloak (reusing the `vault` realm).
- **Persistent Storage**: MinIO pools backed by PVCs.
- **Automated RBAC**: 'admin' user is automatically mapped to `minio-access` policy.

## Deployment

**Prerequisites**: Core platform must be running (`./scripts/deploy.sh`).

```bash
# Deploy Operator and Tenant
./scripts/deploy-minio.sh
```

This script will:
1. Install MinIO Operator.
2. Configure Keycloak (Client `minio`, Group `minio-access`, Mappers, HTTPS Redirects).
3. Deploy MinIO Tenant with OIDC configuration injected.
4. Auto-create MinIO policies.

## Access

| Service | URL | Protocol | Login Method | Credentials |
| :--- | :--- | :--- | :--- | :--- |
| **MinIO Console** | [https://localhost:9091](https://localhost:9091) | **HTTPS** | **"Login with Keycloak"** | `admin` / `admin` |

> **Note**: You must use HTTPS. Accept the self-signed certificate warning.

## Management

### Restarting Access
If `kubectl port-forward` stops working (e.g., after laptop sleep), restore it with:

```bash
./scripts/restart-minio.sh
```

### Credentials
- **Root User**: `minio` (Stored in Vault at `secret/minio`)
- **Root Password**: (Stored in Vault at `secret/minio`)
- **Console User**: Authenticates via Keycloak (`admin`/`admin` in `vault` realm).

## Troubleshooting

### "Client sent an HTTP request to an HTTPS server"
- **Cause**: You accessed `http://localhost:9091` or the Redirect URI is configured for HTTP.
- **Fix**: Use `https://localhost:9091` and ensure `deploy-minio.sh` has been updated (it fixes the redirect URI to HTTPS).

### "Connection Refused"
- **Cause**: Port-forward is not running.
- **Fix**: Run `./scripts/restart-minio.sh`.

### "Login Failed" or "Invalid Redirect URI"
- **Cause**: Keycloak client configuration mismatch.
- **Fix**: Re-run `./scripts/deploy-minio.sh` to update the Keycloak Client definition.
