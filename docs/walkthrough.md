# Final Setup Walkthrough - Keycloak & Vault with Full Persistence

## Summary

Successfully deployed Keycloak and HashiCorp Vault on Minikube with full data persistence and OIDC integration.

---

## ✅ What Was Accomplished

### 1. Initial Deployment
- ✅ Minikube cluster with 4 CPUs and 8GB memory
- ✅ Keycloak with PostgreSQL backend
- ✅ HashiCorp Vault
- ✅ OIDC integration between Vault and Keycloak

### 2. Critical Persistence Fixes
- ✅ **PostgreSQL**: Converted from Deployment to StatefulSet with 2Gi persistent storage
- ✅ **Vault**: Confirmed 1Gi persistent storage (was already configured)
- ✅ **Result**: All data now survives Minikube restarts

### 3. Configuration
- ✅ Keycloak vault realm with OIDC client
- ✅ Vault OIDC authentication with admin role
- ✅ Group-based access control (vault-admins group)
- ✅ Admin user in vault realm

---

## 🎯 Current State

### Persistent Storage

**PostgreSQL (Keycloak Database)**:
- Type: StatefulSet with volumeClaimTemplate
- Storage: 2Gi persistent volume
- Data: All Keycloak realms, users, clients, and configuration

**Vault**:
- Type: StatefulSet (via Helm chart)
- Storage: 1Gi persistent volume
- Data: All secrets, OIDC configuration, policies, and auth methods

### Running Services

```
operators namespace:
- keycloak-0 (1/1 Running)
- postgres-0 (1/1 Running) 
- keycloak-operator

vault namespace:
- vault-0 (1/1 Running)
```

### Persistent Volume Claims

```
operators namespace:
- postgres-storage-postgres-0: 2Gi (Bound)

vault namespace:
- data-vault-0: 1Gi (Bound)
```

---

## 🔐 Access Information

### Keycloak
- **URL**: http://localhost:8080
- **Master Realm**: temp-admin / (from secret)
- **Vault Realm**: admin / admin

### Vault
- **URL**: http://localhost:8200
- **OIDC Login**: Method=OIDC, Role=admin, then login with admin/admin
- **Root Token**: hvs.wu8t4HgeMcdhwvzrIc4M7si3

---

## 🔄 Restart Behavior

### After `minikube stop` and `minikube start`:

**Automatic**:
- ✅ All pods restart
- ✅ PostgreSQL reconnects to persistent volume
- ✅ Keycloak data fully restored (realms, users, clients)
- ✅ Vault reconnects to persistent volume
- ✅ All Vault secrets and OIDC config intact

**Manual Steps Required**:
1. Unseal Vault:
   ```bash
   UNSEAL_KEY=$(cat vault-keys.json | jq -r '.unseal_keys_b64[0]')
   kubectl exec -n vault vault-0 -- vault operator unseal $UNSEAL_KEY
   ```

2. Restart port-forwards:
   ```bash
   kubectl port-forward -n operators svc/keycloak-service 8080:8080 --address=0.0.0.0 &
   kubectl port-forward -n vault svc/vault-ui 8200:8200 --address=0.0.0.0 &
   ```

**No Reconfiguration Needed**: OIDC settings, secrets, and all data persist!

---

## 📁 Key Files

### Generated During Deployment
- `vault-keys.json` - Vault root token and unseal key
- `keycloak-vault-client-secret.txt` - OIDC client secret (persists in Keycloak)

### Updated Configuration
- `k8s/postgres.yaml` - StatefulSet with persistent storage (was Deployment)
- `restart.sh` - Simplified restart script (no reconfiguration needed)

### Documentation
- `CREDENTIALS.md` - All access credentials and URLs
- `RESTART_GUIDE.md` - Restart procedure
- `OIDC_LOGIN_GUIDE.md` - OIDC login instructions
- `WINDOWS_SETUP.md` - Windows hosts file configuration
- `MULTI_CLUSTER.md` - Managing multiple Minikube profiles
- `setup_guide.md` - Complete deployment guide

---

## 🧪 Verification

### Test Data Persistence

1. **Create test data in Keycloak**:
   - Create a new user in vault realm
   - Note the username

2. **Create test secret in Vault**:
   ```bash
   kubectl exec -n vault vault-0 -- vault kv put secret/test password=mypassword
   ```

3. **Restart Minikube**:
   ```bash
   minikube stop
   minikube start
   ```

4. **Unseal Vault and verify**:
   ```bash
   UNSEAL_KEY=$(cat vault-keys.json | jq -r '.unseal_keys_b64[0]')
   kubectl exec -n vault vault-0 -- vault operator unseal $UNSEAL_KEY
   kubectl exec -n vault vault-0 -- vault kv get secret/test
   ```

5. **Check Keycloak**:
   - Access http://localhost:8080
   - Login to vault realm
   - Verify your test user still exists

**Expected Result**: All data persists! ✅

---

## 🚀 Quick Start Commands

### Initial Deployment
```bash
# Start Minikube
minikube start --cpus 4 --memory 8192
minikube addons enable ingress

# Deploy everything
./deploy-all.sh
```

### After Restart
```bash
# Just run the restart script
./restart.sh
```

### Access Services
```bash
# Keycloak
open http://localhost:8080

# Vault
open http://localhost:8200
```

---

## 📊 Architecture

```
┌─────────────────────────────────────────────────────────┐
│                  Minikube Cluster                        │
│                                                          │
│  ┌──────────────────────┐    ┌──────────────────────┐  │
│  │  operators namespace │    │   vault namespace    │  │
│  │                      │    │                      │  │
│  │  ┌────────────────┐ │    │  ┌────────────────┐ │  │
│  │  │   Keycloak     │ │    │  │     Vault      │ │  │
│  │  │   StatefulSet  │◄├────┼──┤  StatefulSet   │ │  │
│  │  │                │ │OIDC│  │                │ │  │
│  │  └────────────────┘ │    │  └────────────────┘ │  │
│  │         ▲           │    │         ▲           │  │
│  │         │           │    │         │           │  │
│  │  ┌────────────────┐ │    │  ┌────────────────┐ │  │
│  │  │   PostgreSQL   │ │    │  │  Persistent    │ │  │
│  │  │   StatefulSet  │ │    │  │  Volume 1Gi    │ │  │
│  │  │                │ │    │  └────────────────┘ │  │
│  │  └────────────────┘ │    │                      │  │
│  │         ▲           │    │                      │  │
│  │  ┌────────────────┐ │    │                      │  │
│  │  │  Persistent    │ │    │                      │  │
│  │  │  Volume 2Gi    │ │    │                      │  │
│  │  └────────────────┘ │    │                      │  │
│  └──────────────────────┘    └──────────────────────┘  │
└─────────────────────────────────────────────────────────┘
```

---

## ✨ Key Achievements

1. **Full Data Persistence**: Both Keycloak and Vault data survive restarts
2. **Simplified Restart**: No reconfiguration needed after restart
3. **Production-Ready Storage**: StatefulSets with persistent volumes
4. **Comprehensive Documentation**: Complete guides for deployment, restart, and troubleshooting
5. **OIDC Integration**: Fully functional OIDC authentication between Vault and Keycloak

---

## 🎓 Lessons Learned

1. **PostgreSQL Must Have Persistent Storage**: Initially deployed as Deployment without volumes, causing data loss
2. **Vault Persistence Works Out of the Box**: Helm chart includes persistent storage by default
3. **OIDC Client Secret Persists**: Stored in Keycloak's PostgreSQL database
4. **Vault Sealing is Normal**: Vault always starts sealed after restart for security
5. **Port-Forwards Don't Persist**: Must be manually restarted after Minikube restart

---

## 📝 Next Steps

For production deployment, consider:
1. Change default passwords (temp-admin, admin)
2. Configure TLS/SSL certificates
3. Set up Vault auto-unseal
4. Implement backup strategy for persistent volumes
5. Configure proper RBAC policies
6. Use external databases instead of in-cluster PostgreSQL
7. Set up monitoring and alerting
