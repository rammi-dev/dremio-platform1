# Setup Complete! 🎉

Your Keycloak and Vault environment is now fully configured and running.

---

## 📋 Access Information

### Keycloak UI
- **URL**: http://localhost:8080
- **Port-forward command**: `kubectl port-forward -n operators svc/keycloak-service 8080:8080 --address=0.0.0.0`

### Vault UI
- **URL**: http://localhost:8200
- **Port-forward command**: `kubectl port-forward -n vault svc/vault-ui 8200:8200 --address=0.0.0.0`

---

## 🔑 Credentials

### Keycloak Master Realm (for admin access)
- **Realm**: `master`
- **Username**: `temp-admin`
- **Password**: `02a52cab1b2f4e5991456ae46bf429f2`
- **Use for**: Keycloak administration

### Keycloak Vault Realm (for Vault OIDC login)
- **Realm**: `vault`
- **Username**: `admin`
- **Password**: `admin`
- **Use for**: Logging into Vault via OIDC

### Vault
- **Root Token**: `hvs.wu8t4HgeMcdhwvzrIc4M7si3`
- **Unseal Key**: `Z1ATqiy2Dnmze1DESudG2Ux5D0Yyw0HLJNgYIF1zabc=`
- **OIDC Client Secret**: `5nhJV4q0LU3yv9mQF7UgjaEJUjSUakWf`

> [!IMPORTANT]
> These credentials are stored in:
> - `vault-keys.json` - Vault root token and unseal key
> - `keycloak-vault-client-secret.txt` - OIDC client secret

---

## 🚀 How to Access

### 1. Ensure Port-Forwards are Running

```bash
# Keycloak (if not already running)
kubectl port-forward -n operators svc/keycloak-service 8080:8080 --address=0.0.0.0 &

# Vault (if not already running)
kubectl port-forward -n vault svc/vault-ui 8200:8200 --address=0.0.0.0 &
```

### 2. Access Keycloak

1. Open browser: http://localhost:8080
2. Click "Administration Console"
3. Login with:
   - Username: `temp-admin`
   - Password: `02a52cab1b2f4e5991456ae46bf429f2`

### 3. Access Vault via OIDC

> [!IMPORTANT]
> **Windows Users**: You must configure your hosts file first! See [`WINDOWS_SETUP.md`](file:///home/rami/.gemini/antigravity/brain/249d21e1-d176-451f-97d6-c51f20a9290a/WINDOWS_SETUP.md) for instructions.

1. Open browser: http://localhost:8200
2. Select Method: **OIDC**
3. Click "Sign in with OIDC Provider"
4. You'll be redirected to Keycloak
5. Login with:
   - Username: `admin`
   - Password: `admin`
6. You'll be redirected back to Vault with full admin access!

### 4. Access Vault via Root Token (alternative)

1. Open browser: http://localhost:8200
2. Select Method: **Token**
3. Enter token: `hvs.wu8t4HgeMcdhwvzrIc4M7si3`

---

## 🔧 Useful Commands

### Check Pod Status
```bash
kubectl get pods -n operators
kubectl get pods -n vault
```

### View Logs
```bash
kubectl logs keycloak-0 -n operators
kubectl logs vault-0 -n vault
```

### Unseal Vault (after restart)
```bash
UNSEAL_KEY=$(cat vault-keys.json | jq -r '.unseal_keys_b64[0]')
kubectl exec -n vault vault-0 -- vault operator unseal $UNSEAL_KEY
```

### Check Vault Status
```bash
kubectl exec -n vault vault-0 -- vault status
```

### Login to Vault CLI
```bash
ROOT_TOKEN=$(cat vault-keys.json | jq -r '.root_token')
kubectl exec -n vault vault-0 -- vault login $ROOT_TOKEN
```

---

## 📚 Documentation Files

- [`setup_guide.md`](file:///home/rami/.gemini/antigravity/brain/249d21e1-d176-451f-97d6-c51f20a9290a/setup_guide.md) - Complete step-by-step setup guide
- [`task.md`](file:///home/rami/.gemini/antigravity/brain/249d21e1-d176-451f-97d6-c51f20a9290a/task.md) - Setup task checklist
- `README.md` - Original project documentation
- `KEYCLOAK_SETUP.md` - Keycloak configuration details
- `VAULT_TEST.md` - Vault testing guide

---

## 🔄 After Minikube Restart

If you run `minikube stop` and later `minikube start`, you'll need to:

1. **Unseal Vault** (it will be sealed after restart):
   ```bash
   UNSEAL_KEY=$(cat vault-keys.json | jq -r '.unseal_keys_b64[0]')
   kubectl exec -n vault vault-0 -- vault operator unseal $UNSEAL_KEY
   ```

2. **Restart port-forwards**:
   ```bash
   kubectl port-forward -n operators svc/keycloak-service 8080:8080 --address=0.0.0.0 &
   kubectl port-forward -n vault svc/vault-ui 8200:8200 --address=0.0.0.0 &
   ```

**Quick restart script**: Run `./restart.sh` to do everything automatically!

See [`RESTART_GUIDE.md`](file:///home/rami/.gemini/antigravity/brain/249d21e1-d176-451f-97d6-c51f20a9290a/RESTART_GUIDE.md) for detailed instructions.

---

## ⚠️ Important Notes

1. **Port-forwards must be running** for UI access to work
2. **Vault will be sealed** after Minikube restarts - use the unseal command above
3. **Keep `vault-keys.json` secure** - it contains your root token and unseal key
4. **Data Persistence**:
   - PostgreSQL: 2Gi persistent storage - all Keycloak data survives restarts
   - Vault: 1Gi persistent storage - all secrets and OIDC config survives restarts
   - OIDC client secret in `keycloak-vault-client-secret.txt` persists in Keycloak
5. The temp-admin password in Keycloak master realm should be changed for production use
6. The admin password in vault realm is set to `admin` - change it for production use
