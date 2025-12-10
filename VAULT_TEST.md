# Vault and Keycloak Integration - Testing Guide

## ✅ Configuration Complete!

All components have been successfully configured:

### Keycloak Configuration
- ✅ Vault realm created
- ✅ OIDC client `vault` created
- ✅ Client secret: `5wSkDgU7HUlLQb18bNMqaMZz9kya0q4L`
- ✅ Group `vault-admins` created
- ✅ Admin user added to vault-admins group

### Vault Configuration
- ✅ Vault deployed and initialized
- ✅ Root token: `hvs.qHocdq4yjXI53ehNvjHvxSn0`
- ✅ OIDC auth method enabled
- ✅ Admin policy created (full access)
- ✅ OIDC role configured
- ✅ Group mapping created

## Testing OIDC Login

### Port-Forward is Running

Vault UI is accessible at: **http://localhost:8200**

### Login Steps

1. Open your Windows browser
2. Navigate to: `http://localhost:8200`
3. You'll see the Vault login page
4. Select **Method**: `OIDC`
5. Click **"Sign in with OIDC Provider"**
6. You'll be redirected to Keycloak
7. Log in with:
   - **Username**: `admin`
   - **Password**: `admin`
8. You'll be redirected back to Vault
9. You should now have full admin access to Vault!

### Verify Full Access

Once logged in, you should be able to:
- ✅ View and create secrets
- ✅ Manage policies
- ✅ Configure auth methods
- ✅ Access all Vault features

### Alternative: Root Token Login

If you want to use the root token instead:
1. Select **Method**: `Token`
2. Enter token: `hvs.qHocdq4yjXI53ehNvjHvxSn0`

## Port-Forward Commands

**Keycloak** (already running):
```bash
kubectl port-forward -n operators svc/keycloak-service 8080:8080 --address=0.0.0.0
```

**Vault** (currently running):
```bash
kubectl port-forward -n vault svc/vault-ui 8200:8200 --address=0.0.0.0
```

## Important Files

- `vault-keys.json` - Vault root token and unseal key
- `keycloak-vault-client-secret.txt` - Keycloak OIDC client secret

## Troubleshooting

### Can't access Vault UI
- Ensure port-forward is running
- Check: `kubectl get pods -n vault`

### OIDC login fails
- Verify Keycloak is accessible from Vault pod
- Check Vault logs: `kubectl logs -n vault vault-0`

### Need to unseal Vault after restart
```bash
UNSEAL_KEY=$(cat vault-keys.json | jq -r '.unseal_keys_b64[0]')
kubectl exec -n vault vault-0 -- vault operator unseal $UNSEAL_KEY
```
