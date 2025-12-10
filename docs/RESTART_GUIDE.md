# Minikube Restart Guide

## What Happens After `minikube stop` and `minikube start`

✅ **Will work automatically:**
- Minikube cluster
- All Kubernetes resources (pods, services, etc.)
- Keycloak (will restart automatically with all data intact)
- PostgreSQL (will restart automatically with persistent data)
- **All Keycloak data persists** (realms, users, clients)
- **All Vault secrets persist** (but Vault will be sealed)

⚠️ **Requires manual action:**
- **Vault will be SEALED** and needs to be unsealed
- **Port-forwards** need to be restarted

> [!IMPORTANT]
> **Data Persistence**: Both PostgreSQL (2Gi) and Vault (1Gi) now have persistent storage. All your Keycloak realms, users, OIDC clients, and Vault secrets will survive restarts!

---

## Step-by-Step Restart Procedure

### 1. Stop Minikube
```bash
minikube stop
```

### 2. Start Minikube
```bash
minikube start
```

### 3. Wait for Pods to Be Ready
```bash
# Check operators namespace (Keycloak)
kubectl get pods -n operators

# Check vault namespace
kubectl get pods -n vault
```

Wait until all pods show `Running` status (may take 1-2 minutes).

### 4. Unseal Vault

Vault will be sealed after restart. Unseal it:

```bash
UNSEAL_KEY=$(cat vault-keys.json | jq -r '.unseal_keys_b64[0]')
kubectl exec -n vault vault-0 -- vault operator unseal $UNSEAL_KEY
```

Verify Vault is unsealed:
```bash
kubectl exec -n vault vault-0 -- vault status
```

Expected output: `Sealed: false`

> [!NOTE]
> **No reconfiguration needed!** All OIDC settings, policies, and secrets persist in Vault's storage.

### 5. Restart Port-Forwards

```bash
# Keycloak
kubectl port-forward -n operators svc/keycloak-service 8080:8080 --address=0.0.0.0 &

# Vault
kubectl port-forward -n vault svc/vault-ui 8200:8200 --address=0.0.0.0 &
```

### 6. Test Access

- **Keycloak**: http://localhost:8080
- **Vault**: http://localhost:8200

---

## Quick Restart Script

Save this as `restart.sh`:

```bash
#!/bin/bash
set -e

echo "Starting Minikube..."
minikube start

echo "Waiting for pods to be ready..."
kubectl wait --for=condition=ready pod -l app=postgres -n operators --timeout=120s
kubectl wait --for=condition=ready pod/keycloak-0 -n operators --timeout=180s

echo "Unsealing Vault..."
UNSEAL_KEY=$(cat vault-keys.json | jq -r '.unseal_keys_b64[0]')
kubectl exec -n vault vault-0 -- vault operator unseal $UNSEAL_KEY

echo "Vault status:"
kubectl exec -n vault vault-0 -- vault status

echo "Starting port-forwards..."
kubectl port-forward -n operators svc/keycloak-service 8080:8080 --address=0.0.0.0 &
kubectl port-forward -n vault svc/vault-ui 8200:8200 --address=0.0.0.0 &

echo "✅ All services ready!"
echo "Keycloak: http://localhost:8080"
echo "Vault: http://localhost:8200"
```

Make it executable:
```bash
chmod +x restart.sh
```

Run it:
```bash
./restart.sh
```

---

## Troubleshooting

### Vault Still Sealed
```bash
# Check vault status
kubectl exec -n vault vault-0 -- vault status

# If sealed, unseal again
UNSEAL_KEY=$(cat vault-keys.json | jq -r '.unseal_keys_b64[0]')
kubectl exec -n vault vault-0 -- vault operator unseal $UNSEAL_KEY
```

### Port-Forward Died
```bash
# Kill existing port-forwards
pkill -f "port-forward"

# Restart them
kubectl port-forward -n operators svc/keycloak-service 8080:8080 --address=0.0.0.0 &
kubectl port-forward -n vault svc/vault-ui 8200:8200 --address=0.0.0.0 &
```

### Pods Not Starting
```bash
# Check pod status
kubectl get pods -n operators
kubectl get pods -n vault

# View logs
kubectl logs keycloak-0 -n operators
kubectl logs vault-0 -n vault
```

---

## Important Notes

1. **Always keep `vault-keys.json` safe** - you need it to unseal Vault after every restart
2. **Port-forwards don't survive** - you need to restart them manually
3. **Keycloak data persists** - all your realms, users, and clients are preserved
4. **Vault data persists** - all secrets are preserved (but sealed)
