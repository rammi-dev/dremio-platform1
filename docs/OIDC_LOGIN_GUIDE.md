# Vault OIDC Login Guide

## How to Login to Vault via OIDC

### Step 1: Access Vault UI
Open http://localhost:8200 in your browser

### Step 2: Select OIDC Method
In the "Method" dropdown, select **OIDC**

### Step 3: Enter Role Name
**IMPORTANT**: In the "Role" field, enter: `admin`

> [!WARNING]
> **Do NOT leave the Role field empty!** You must enter `admin` as the role name.

### Step 4: Sign In
Click "Sign in with OIDC Provider"

### Step 5: Authenticate with Keycloak
You'll be redirected to Keycloak. Login with:
- Username: `admin`
- Password: `admin`

### Step 6: Success!
You'll be redirected back to Vault with full admin access.

---

## Common Errors

### Error: "Missing auth_url"
**Cause**: Role field was left empty

**Solution**: Enter `admin` in the Role field before clicking "Sign in with OIDC Provider"

### Error: "error checking oidc discovery URL"
**Cause**: Keycloak service is not reachable or vault realm doesn't exist

**Solution**: 
1. Verify Keycloak is running: `kubectl get pods -n operators`
2. Verify vault realm exists: `curl http://localhost:8080/realms/vault/.well-known/openid-configuration`
3. If realm doesn't exist, run the Keycloak configuration script

### Error: "Unauthorized" or "Invalid credentials"
**Cause**: Wrong username/password in Keycloak

**Solution**: Use `admin` / `admin` for the vault realm

---

## Alternative: Login with Root Token

If OIDC login isn't working, you can always use the root token:

1. Select Method: **Token**
2. Enter token: `hvs.wu8t4HgeMcdhwvzrIc4M7si3` (from vault-keys.json)
3. Click "Sign In"

---

## Verify OIDC Configuration

Check if OIDC is properly configured:

```bash
ROOT_TOKEN=$(cat vault-keys.json | jq -r '.root_token')
kubectl exec -n vault vault-0 -- vault login $ROOT_TOKEN
kubectl exec -n vault vault-0 -- vault read auth/oidc/config
kubectl exec -n vault vault-0 -- vault read auth/oidc/role/admin
```

Expected role name: `admin`
Expected redirect URIs:
- http://localhost:8200/ui/vault/auth/oidc/oidc/callback
- http://127.0.0.1:8200/ui/vault/auth/oidc/oidc/callback
- http://localhost:8250/oidc/callback
