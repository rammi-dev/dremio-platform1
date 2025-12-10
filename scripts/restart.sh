#!/bin/bash
set -e

PROFILE="${MINIKUBE_PROFILE:-keycloak-vault}"

echo "Starting Minikube (profile: $PROFILE)..."
minikube start -p $PROFILE

echo "Waiting for pods to be ready..."
kubectl wait --for=condition=ready pod -l app=postgres -n operators --timeout=120s
kubectl wait --for=condition=ready pod/keycloak-0 -n operators --timeout=180s

echo "Unsealing Vault..."
UNSEAL_KEY=$(cat config/vault-keys.json | jq -r '.unseal_keys_b64[0]')
kubectl exec -n vault vault-0 -- vault operator unseal $UNSEAL_KEY

echo "Vault status:"
kubectl exec -n vault vault-0 -- vault status

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
