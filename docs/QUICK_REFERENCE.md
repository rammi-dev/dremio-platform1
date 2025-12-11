# Quick Reference - Access Credentials

**Last Updated**: December 11, 2025

---

## 🔐 Current Credentials

### Keycloak - Master Realm (Admin Console)
```
URL:      http://localhost:8080
Username: temp-admin
Password: <dynamically generated>
```

**Get Current Password**:
```bash
kubectl get secret keycloak-initial-admin -n operators -o jsonpath='{.data.password}' | base64 -d
```



---

### Keycloak - Vault Realm (OIDC Users)
```
URL:      http://localhost:8080/realms/vault
Username: admin
Password: admin
```

> **Important**: This user is ONLY for OIDC login to Vault and MinIO.  
> It does NOT work for the Keycloak admin console.

---

### Vault
```
URL: http://localhost:8200
```

**Option 1: Root Token**
```bash
cat config/vault-keys.json | jq -r '.root_token'
```


**Option 2: OIDC Login** (Recommended)
1. Select "OIDC" method
2. Role: `admin`
3. Click "Sign in with OIDC Provider"
4. Login with: `admin` / `admin`

---

### MinIO Console
```
URL: https://localhost:9091  (⚠️ HTTPS required)
```

**Login**:
1. Click "Login with OpenID"
2. Login with: `admin` / `admin`

**Root Credentials** (stored in Vault):
```bash
# Login to Vault first, then:
kubectl exec -n vault vault-0 -- vault kv get secret/minio
```

---

## 🚀 Quick Commands

### Get All Credentials at Once
```bash
echo "=== Keycloak Master Realm ==="
echo "Username: temp-admin"
echo "Password: $(kubectl get secret keycloak-initial-admin -n operators -o jsonpath='{.data.password}' | base64 -d)"
echo ""
echo "=== Vault Root Token ==="
echo "Token: $(cat config/vault-keys.json | jq -r '.root_token')"
echo ""
echo "=== Vault Realm (OIDC) ==="
echo "Username: admin"
echo "Password: admin"
```

### Check Service Status
```bash
kubectl get pods -A | grep -E "keycloak|vault|minio"
```

### Check Port Forwards
```bash
ps aux | grep "kubectl port-forward" | grep -v grep
```

### Restart Port Forwards
```bash
pkill -f "kubectl port-forward"
./scripts/restart.sh
./scripts/restart-minio.sh
```

### Get Minikube IP
```bash
minikube ip -p keycloak-vault
```


### Unseal Vault
```bash
UNSEAL_KEY=$(cat config/vault-keys.json | jq -r '.unseal_keys_b64[0]')
kubectl exec -n vault vault-0 -- vault operator unseal $UNSEAL_KEY
```

---

## 📊 Service URLs

| Service | URL | Credentials |
|---------|-----|-------------|
| Keycloak Admin | http://localhost:8080 | temp-admin / *(dynamic)* |
| Vault | http://localhost:8200 | Token or OIDC (admin/admin) |
| MinIO Console | https://localhost:9091 | OIDC (admin/admin) |

---

## 🔐 Realm Clarification

**Master Realm**:
- Purpose: Manage Keycloak itself
- User: `temp-admin` (dynamic password)
- Access: Keycloak Admin Console only
- Cannot be used for: OIDC login to applications

**Vault Realm**:
- Purpose: OIDC authentication for applications
- User: `admin` / `admin`
- Access: Vault, MinIO (via OIDC)
- Cannot be used for: Keycloak Admin Console

---

## 💾 Configuration Files

All credentials are stored in:
- `config/vault-keys.json` - Vault root token and unseal key
- `config/keycloak-vault-client-secret.txt` - OIDC client secret
- Kubernetes secret: `keycloak-initial-admin` (master realm password)

> **Security Note**: These files are gitignored and should never be committed.

---

## 🔄 After System Restart

```bash
# 1. Start Minikube
minikube start -p keycloak-vault

# 2. Restart services
./scripts/restart.sh
./scripts/restart-minio.sh

# 3. Get credentials (they persist)
kubectl get secret keycloak-initial-admin -n operators -o jsonpath='{.data.password}' | base64 -d
cat config/vault-keys.json | jq -r '.root_token'
```

---

**For detailed documentation, see**:
- [README.md](../README.md) - Main documentation
- [CREDENTIALS.md](CREDENTIALS.md) - Full credentials guide
- [RESTART_GUIDE.md](RESTART_GUIDE.md) - Restart procedures
