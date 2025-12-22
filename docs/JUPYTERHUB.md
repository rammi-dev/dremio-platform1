# JupyterHub OAuth Authentication - Complete Documentation

## Overview

This document explains the complete OAuth authentication flow between JupyterHub and Keycloak, including all configuration steps, troubleshooting logic, and solutions implemented.

## OAuth Flow Architecture

```
┌─────────────┐
│   Browser   │
└──────┬──────┘
       │ 1. Access http://jupyterhub.local:8000
       ▼
┌─────────────────┐
│  JupyterHub Hub │ (jupyterhub namespace)
└──────┬──────────┘
       │ 2. Redirect to Keycloak with:
       │    - client_id
       │    - redirect_uri
       │    - state (stored in cookie)
       ▼
┌──────────────┐
│   Keycloak   │ (operators namespace)
└──────┬───────┘
       │ 3. User authenticates
       │ 4. Redirect back with:
       │    - authorization code
       │    - state
       ▼
┌─────────────────┐
│  JupyterHub Hub │
└──────┬──────────┘
       │ 5. Exchange code for tokens:
       │    - Send code + client_secret
       │    - Receive ID token, access token
       │ 6. Validate state cookie
       │ 7. Create user session
       ▼
┌─────────────────┐
│  User Dashboard │
└─────────────────┘
```

## Configuration Components

### 1. JupyterHub Configuration (`values.yaml`)

```yaml
hub:
  config:
    JupyterHub:
      authenticator_class: generic-oauth
      base_url: /
    
    Authenticator:
      # CRITICAL: Allow any authenticated user to access
      allow_all: true
    
    GenericOAuthenticator:
      client_id: jupyterhub
      # client_secret set via --set during deployment
      oauth_callback_url: http://jupyterhub.local:8000/hub/oauth_callback
      authorize_url: http://keycloak-service.operators.svc.cluster.local:8080/realms/vault/protocol/openid-connect/auth
      token_url: http://keycloak-service.operators.svc.cluster.local:8080/realms/vault/protocol/openid-connect/token
      userdata_url: http://keycloak-service.operators.svc.cluster.local:8080/realms/vault/protocol/openid-connect/userinfo
      username_claim: preferred_username
      login_service: "Keycloak"
      scope:
        - openid
        - profile
        - email
      enable_auth_state: true  # CRITICAL: Required for STS integration
```

**Key Configuration Logic:**

1. **`authenticator_class: generic-oauth`**
   - Enables OAuth2/OIDC authentication
   - Uses GenericOAuthenticator from oauthenticator package

2. **`allow_all: true`**
   - **Why needed:** Without this, JupyterHub rejects all users even after successful OAuth
   - **Error without it:** "No allow config found" warning, 500 errors
   - **Alternative:** Set `allowed_users` to specific list

3. **`enable_auth_state: true`**
   - **Why needed:** Stores OAuth tokens (ID token, access token) in JupyterHub database
   - **Required for:** MinIO STS integration (pre-spawn hook needs ID token)
   - **Without it:** Pre-spawn hook cannot access user's OIDC token

4. **`oauth_callback_url`**
   - **Must match exactly:** How browser accesses JupyterHub
   - **Why `jupyterhub.local`:** Avoids cookie issues with `localhost`
   - **Must be in:** Keycloak client's redirect URIs

### 2. Keycloak Client Configuration

```json
{
  "clientId": "jupyterhub",
  "protocol": "openid-connect",
  "publicClient": false,
  "directAccessGrantsEnabled": true,
  "standardFlowEnabled": true,
  "redirectUris": [
    "http://jupyterhub.local:8000/hub/oauth_callback",
    "http://localhost:8000/hub/oauth_callback",
    "http://*:8000/hub/oauth_callback"
  ],
  "webOrigins": ["+"]
}
```

**Key Configuration Logic:**

1. **`publicClient: false`**
   - Makes client "confidential" - requires client secret
   - **Why:** More secure than public clients
   - **Requires:** Client secret in JupyterHub config

2. **`directAccessGrantsEnabled: true`**
   - Enables password grant type
   - **Why:** Allows testing OAuth flow programmatically
   - **Used by:** MinIO STS for token exchange

3. **`standardFlowEnabled: true`**
   - Enables authorization code flow
   - **Why:** Standard OAuth2 flow for web applications
   - **Flow:** Browser redirect → code → token exchange

4. **`redirectUris`**
   - **Must include:** Exact callback URL from JupyterHub
   - **Wildcard `*`:** Allows any hostname (dev only!)
   - **Error if missing:** "Invalid parameter: redirect_uri"

5. **`webOrigins: ["+"]`**
   - Allows CORS from redirect URIs
   - **Why:** Browser needs to make cross-origin requests

### 3. Cookie Configuration

```yaml
hub:
  extraConfig:
    cookie_options: |
      c.JupyterHub.cookie_options = {
          'SameSite': 'None',
          'Secure': False,
      }
```

**Cookie Logic:**

1. **`SameSite: 'None'`**
   - **Why:** Allows cookies in cross-site requests (OAuth redirects)
   - **Default:** Browsers block cookies in cross-origin scenarios
   - **Without it:** OAuth state cookie lost during redirect

2. **`Secure: False`**
   - **Why:** Allows cookies over HTTP (localhost development)
   - **Production:** Should be `True` with HTTPS
   - **Without it:** Browsers reject cookies on HTTP when SameSite=None

### 4. Hostname Configuration

**Windows hosts file (`C:\Windows\System32\drivers\etc\hosts`):**
```
127.0.0.1  jupyterhub.local
127.0.0.1  keycloak-service.operators.svc.cluster.local
```

**Why Needed:**
- **Problem:** OAuth state cookies don't work with `localhost` in port-forward setup
- **Root cause:** Cookie domain mismatch between initial request and callback
- **Solution:** Use consistent hostname throughout OAuth flow
- **Alternative:** Use Ingress with real domain (production approach)

## Troubleshooting Logic

### Issue 1: "OAuth state missing from cookies"

**Symptoms:**
- 400 Bad Request after Keycloak redirect
- Error: "OAuth state missing from cookies"

**Root Cause:**
- OAuth state cookie not preserved across redirect
- Cookie domain/path mismatch

**Diagnosis Steps:**
1. Check browser developer tools → Application → Cookies
2. Look for `oauthenticator-state` cookie
3. Check if cookie domain matches current URL

**Solutions Tried:**
1. ❌ **Disable SameSite** - Didn't work with localhost
2. ❌ **Patch OAuth handler** - AttributeError (wrong handler structure)
3. ✅ **Use proper hostnames** - Fixed by using `jupyterhub.local`

**Final Solution:**
- Use `jupyterhub.local` instead of `localhost`
- Add to Windows hosts file
- Update all OAuth URLs to use consistent hostname

### Issue 2: "Invalid parameter: redirect_uri"

**Symptoms:**
- Keycloak error page
- "We are sorry... Invalid parameter: redirect_uri"

**Root Cause:**
- Redirect URI not in Keycloak client's allowed list

**Diagnosis:**
```bash
# Check current redirect URIs
curl -s "http://localhost:8080/admin/realms/vault/clients/$CLIENT_UUID" \
  -H "Authorization: Bearer $ACCESS_TOKEN" | jq '.redirectUris'
```

**Solution:**
```bash
# Update redirect URIs
curl -X PUT "http://localhost:8080/admin/realms/vault/clients/$CLIENT_UUID" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "redirectUris": [
      "http://jupyterhub.local:8000/hub/oauth_callback",
      "http://localhost:8000/hub/oauth_callback"
    ]
  }'
```

### Issue 3: "HTTP 401: Unauthorized" (500 Error)

**Symptoms:**
- 500 Internal Server Error after Keycloak redirect
- Hub logs show: `tornado.httpclient.HTTPClientError: HTTP 401: Unauthorized`

**Root Cause:**
- Client secret missing or incorrect in JupyterHub
- Token exchange fails without valid secret

**Diagnosis:**
```bash
# Check if secret is set
kubectl get secret -n jupyterhub hub -o yaml | grep client_secret

# Get correct secret from Keycloak
curl -s "http://localhost:8080/admin/realms/vault/clients/$CLIENT_UUID/client-secret" \
  -H "Authorization: Bearer $ACCESS_TOKEN" | jq -r '.value'
```

**Solution:**
```bash
# Update JupyterHub with correct secret
helm upgrade jupyterhub jupyterhub/jupyterhub \
  -n jupyterhub \
  -f helm/jupyterhub/values.yaml \
  --set hub.config.GenericOAuthenticator.client_secret="$CLIENT_SECRET"
```

### Issue 4: "No allow config found" (500 Error)

**Symptoms:**
- Warning in hub logs: "No allow config found, it's possible that nobody can login"
- Users can't access hub after authentication

**Root Cause:**
- JupyterHub doesn't know which users to allow
- Default: deny all users

**Solution:**
```yaml
hub:
  config:
    Authenticator:
      allow_all: true  # Allow any authenticated user
```

**Alternatives:**
```yaml
# Option 1: Specific users
Authenticator:
  allowed_users:
    - admin
    - user1

# Option 2: Admin users
Authenticator:
  admin_users:
    - admin
  allow_all: true
```

## Complete Deployment Steps

### 1. Deploy JupyterHub
```bash
./scripts/deploy-jupyterhub-gke.sh
```

**What it does:**
1. Checks Keycloak and MinIO are running
2. Authenticates with Keycloak admin API
3. Creates/updates `jupyterhub` client in Keycloak
4. Retrieves client secret
5. Creates `jupyterhub` and `jupyterhub-users` namespaces
6. Configures RBAC for cross-namespace access
7. Deploys JupyterHub via Helm with client secret
8. Starts port-forward on localhost:8000

### 2. Update Windows Hosts File
```
127.0.0.1  jupyterhub.local
127.0.0.1  keycloak-service.operators.svc.cluster.local
```

### 3. Update Keycloak Redirect URIs
```bash
source scripts/lib/jupyterhub-common.sh
authenticate_keycloak
configure_jupyterhub_keycloak_client "$ACCESS_TOKEN"
```

### 4. Verify Configuration
```bash
# Check hub pod
kubectl get pods -n jupyterhub -l component=hub

# Check hub logs
kubectl logs -n jupyterhub -l component=hub --tail=50

# Test OAuth flow
# Open: http://jupyterhub.local:8000
```

## Testing OAuth Flow

### Manual Test Steps:
1. Open browser to `http://jupyterhub.local:8000`
2. Click "Sign in with Keycloak"
3. Should redirect to `http://keycloak-service.operators.svc.cluster.local:8080`
4. Login with `admin` / `admin`
5. Should redirect back to `http://jupyterhub.local:8000/hub/oauth_callback`
6. Should see JupyterHub dashboard

### Expected Logs (Success):
```
[I] OAuth redirect: http://jupyterhub.local:8000/hub/oauth_callback
[I] 302 GET /hub/oauth_login
[I] User logged in: admin
[I] 302 GET /hub/oauth_callback
```

### Expected Logs (Failure):
```
# Missing state cookie
[W] 400 GET /hub/oauth_callback: OAuth state missing from cookies

# Invalid redirect URI
[E] 500 GET /hub/oauth_callback

# Wrong client secret
[E] tornado.httpclient.HTTPClientError: HTTP 401: Unauthorized

# No allow config
[W] No allow config found, it's possible that nobody can login
```

## Security Considerations

### Development (Current Setup):
- ✅ OAuth authentication required
- ✅ Temporary STS credentials (12 hours)
- ⚠️ HTTP (not HTTPS)
- ⚠️ Self-signed certificates
- ⚠️ Wildcard redirect URIs
- ⚠️ `allow_all: true` (any authenticated user)

### Production Recommendations:
1. **Use Ingress with TLS**
   - Real domain name
   - Valid TLS certificates
   - HTTPS only

2. **Restrict Redirect URIs**
   - Remove wildcards
   - Use exact URLs only

3. **Limit User Access**
   - Use `allowed_users` or `admin_users`
   - Remove `allow_all: true`

4. **Enable Auth State Encryption**
   ```yaml
   hub:
     config:
       CryptKeeper:
         keys:
           - <encryption-key>
   ```

5. **Use External Database**
   - PostgreSQL instead of SQLite
   - For auth state persistence

## Integration with MinIO STS

The OAuth configuration enables MinIO STS integration:

1. **`enable_auth_state: true`** stores OIDC tokens
2. **Pre-spawn hook** retrieves ID token from auth state
3. **MinIO STS API** validates ID token with Keycloak
4. **Temporary credentials** injected into notebook environment

See `helm/jupyterhub/values.yaml` pre_spawn_hook for implementation.

## References

- JupyterHub OAuth Documentation: https://z2jh.jupyter.org/en/stable/administrator/authentication.html
- OAuthenticator: https://oauthenticator.readthedocs.io/
- Keycloak OIDC: https://www.keycloak.org/docs/latest/securing_apps/#_oidc
- OAuth 2.0 RFC: https://tools.ietf.org/html/rfc6749
