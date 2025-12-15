# JupyterHub OAuth Troubleshooting & Fixes

## Issues Encountered

### 1. OAuth State Cookie Missing (400 Bad Request)

**Error**: `OAuth state missing from cookies`

**Root Cause**: Browser (Brave/Chrome) blocking OAuth state cookies due to SameSite restrictions.

**Solutions Tried**:
1. ❌ `SameSite: 'None'` - Not recognized by JupyterHub config
2. ❌ `SameSite: 'Lax'` with `GenericOAuthenticator.cookie_options` - Still blocked by browser
3. ✅ **Disabled state management** - `c.GenericOAuthenticator.manage_state = False`

**Final Configuration** (`helm/jupyterhub/values.yaml`):
```yaml
extraConfig:
  oauth_config: |
    # Disable OAuth state cookie (browser blocking issue)
    # This is less secure but works around cookie restrictions
    c.GenericOAuthenticator.manage_state = False
```

**Trade-off**: Slightly less secure (no CSRF protection on OAuth flow), but necessary for browser compatibility.

### 2. Invalid Client Credentials (500 Internal Server Error)

**Error**: `HTTP 401: Unauthorized` - "Invalid client or Invalid client credentials"

**Root Cause**: Client secret was lost during Helm upgrades.

**Solution**: Retrieve correct secret from Keycloak and update JupyterHub:

```bash
# Get Keycloak admin credentials
KEYCLOAK_USER=$(kubectl get secret keycloak-initial-admin -n operators -o jsonpath='{.data.username}' | base64 -d)
KEYCLOAK_PASS=$(kubectl get secret keycloak-initial-admin -n operators -o jsonpath='{.data.password}' | base64 -d)

# Authenticate with Keycloak
TOKEN_RESPONSE=$(curl -s -X POST "http://localhost:8080/realms/master/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "username=$KEYCLOAK_USER" \
  -d "password=$KEYCLOAK_PASS" \
  -d "grant_type=password" \
  -d "client_id=admin-cli")

ACCESS_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.access_token')

# Get minio client UUID
CLIENT_UUID=$(curl -s -X GET "http://localhost:8080/admin/realms/vault/clients?clientId=minio" \
  -H "Authorization: Bearer $ACCESS_TOKEN" | jq -r '.[0].id')

# Get client secret
CLIENT_SECRET=$(curl -s -X GET "http://localhost:8080/admin/realms/vault/clients/$CLIENT_UUID/client-secret" \
  -H "Authorization: Bearer $ACCESS_TOKEN" | jq -r '.value')

# Update JupyterHub
helm upgrade jupyterhub jupyterhub/jupyterhub \
  -n jupyterhub \
  -f helm/jupyterhub/values.yaml \
  --set hub.config.GenericOAuthenticator.client_secret="$CLIENT_SECRET" \
  --wait --timeout=5m
```

## Working Configuration

### Requirements
1. **Hostname**: Must use `jupyterhub.local` (not `localhost`)
2. **Hosts file**: Add `127.0.0.1 jupyterhub.local` to `/etc/hosts`
3. **Port-forward**: `kubectl port-forward -n jupyterhub svc/proxy-public 8000:80 --address=0.0.0.0`
4. **Client secret**: Must match Keycloak `minio` client secret

### Access
- URL: http://jupyterhub.local:8000
- Login: Keycloak OIDC (`admin` / `admin`)

### Browser Compatibility
- ✅ Chrome/Chromium (with state disabled)
- ✅ Brave (with state disabled)
- ✅ Firefox (with state disabled)
- ⚠️ Safari (untested)

## Deployment Script Updates

The `deploy-jupyterhub-gke.sh` script already handles:
- ✅ Keycloak client configuration
- ✅ Redirect URI updates
- ✅ Client secret retrieval
- ✅ Helm deployment with correct secret

**Note**: The OAuth state fix (`manage_state = False`) is now in `values.yaml` and will persist across deployments.
