#!/bin/bash
set -e

PROFILE="${MINIKUBE_PROFILE:-keycloak-vault}"

echo "Starting Minikube (profile: $PROFILE)..."
minikube start -p $PROFILE

echo "Waiting for pods to be ready..."
echo "Waiting for pods to be ready..."
kubectl wait --for=condition=ready pod -l app=postgres -n operators --timeout=120s

# Wait for Keycloak pod to exist first
echo "Waiting for Keycloak pod to be created..."
for i in {1..30}; do
  if kubectl get pod keycloak-0 -n operators > /dev/null 2>&1; then
    echo "✓ Keycloak pod found"
    break
  fi
  echo "Waiting for keycloak-0... ($i/30)"
  sleep 2
done
kubectl wait --for=condition=ready pod/keycloak-0 -n operators --timeout=180s

echo "Checking Vault status..."
if [ ! -f config/vault-keys.json ]; then
    echo "ERROR: config/vault-keys.json not found! Cannot unseal Vault."
    exit 1
fi

VAULT_SEALED=$(kubectl exec -n vault vault-0 -- vault status -format=json 2>/dev/null | jq -r .sealed)
if [ "$VAULT_SEALED" == "true" ]; then
    echo "Vault is sealed. Unsealing..."
    UNSEAL_KEY=$(cat config/vault-keys.json | jq -r '.unseal_keys_b64[0]')
    kubectl exec -n vault vault-0 -- vault operator unseal $UNSEAL_KEY > /dev/null
    echo "✓ Vault unsealed"
else
    echo "✓ Vault is already unsealed"
fi

echo "Starting port-forwards..."
kubectl port-forward -n operators svc/keycloak-service 8080:8080 --address=0.0.0.0 &
kubectl port-forward -n vault svc/vault-ui 8200:8200 --address=0.0.0.0 &

echo ""
echo "✅ All services ready!"
echo ""
echo "Keycloak: http://localhost:8080"
echo "  - Master realm: temp-admin / (check secret)"
echo "  - Vault realm: admin / admin"
echo ""
echo "Vault: http://localhost:8200"
echo "  - OIDC Method, Role: admin"
echo "  - Login with vault realm credentials (admin/admin)"
echo ""
echo "Note: All data persists across restarts!"
echo "  - PostgreSQL: 2Gi persistent storage"
echo "  - Vault: 1Gi persistent storage"
echo "  - No reconfiguration needed!"
