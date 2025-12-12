#!/bin/bash

# Stop any existing port forwards
pkill -f "kubectl port-forward" 2>/dev/null

# Get all passwords
KEYCLOAK_USER=$(kubectl get secret keycloak-initial-admin -n operators -o jsonpath='{.data.username}' | base64 -d)
KEYCLOAK_PASS=$(kubectl get secret keycloak-initial-admin -n operators -o jsonpath='{.data.password}' | base64 -d)
VAULT_TOKEN=$(kubectl get secret vault-init -n vault -o jsonpath='{.data.root-token}' | base64 -d)
MINIO_ROOT_USER=$(kubectl get secret minio-env-configuration -n minio -o jsonpath='{.data.config\.env}' | base64 -d | grep MINIO_ROOT_USER | cut -d'=' -f2 | tr -d '"')
MINIO_ROOT_PASSWORD=$(kubectl get secret minio-env-configuration -n minio -o jsonpath='{.data.config\.env}' | base64 -d | grep MINIO_ROOT_PASSWORD | cut -d'=' -f2 | tr -d '"')

# Start port forwards
echo "Starting port forwards..."
kubectl port-forward -n operators svc/keycloak-service 8080:8080 --address=0.0.0.0 > /dev/null 2>&1 &
kubectl port-forward -n vault svc/vault-ui 8200:8200 --address=0.0.0.0 > /dev/null 2>&1 &
kubectl port-forward -n minio svc/minio-console 9091:9443 --address=0.0.0.0 > /dev/null 2>&1 &
kubectl port-forward -n minio svc/minio 9000:443 --address=0.0.0.0 > /dev/null 2>&1 &

sleep 3

# Display access information
echo "========================================="
echo "Services are now accessible:"
echo "========================================="
echo ""
echo "Keycloak Admin Console:"
echo "  URL:      http://localhost:8080"
echo "  Username: $KEYCLOAK_USER"
echo "  Password: $KEYCLOAK_PASS"
echo ""
echo "Vault UI:"
echo "  URL:   http://localhost:8200"
echo "  Token: $VAULT_TOKEN"
echo ""
echo "MinIO Console:"
echo "  URL:      http://localhost:9091"
echo "  Username: $MINIO_ROOT_USER"
echo "  Password: $MINIO_ROOT_PASSWORD"
echo ""
echo "MinIO API:"
echo "  URL:      https://localhost:9000"
echo "  Username: $MINIO_ROOT_USER"
echo "  Password: $MINIO_ROOT_PASSWORD"
echo ""
echo "========================================="
echo ""
echo "Port forwards are running in the background."
echo "To stop them, run: pkill -f 'kubectl port-forward'"
