#!/bin/bash
# JupyterHub Common Functions
# Shared functions for JupyterHub deployment

# Ensure Keycloak port-forward is active
ensure_keycloak_port_forward() {
  echo "Checking Keycloak port-forward..."
  if ps aux | grep -q "[k]ubectl port-forward -n operators svc/keycloak-service 8080"; then
    echo "✓ Keycloak port-forward already running"
    return 0
  fi
  
  if curl -s -o /dev/null -w "%{http_code}" http://localhost:8080 | grep -q "200\|302\|401"; then
    echo "✓ Keycloak accessible on localhost:8080"
    return 0
  fi
  
  echo "Starting Keycloak port-forward..."
  pkill -f "kubectl port-forward -n operators svc/keycloak-service" 2>/dev/null || true
  nohup kubectl port-forward -n operators svc/keycloak-service 8080:8080 --address=0.0.0.0 > /dev/null 2>&1 &
  sleep 3
  
  if curl -s -o /dev/null -w "%{http_code}" http://localhost:8080 | grep -q "200\|302\|401"; then
    echo "✓ Keycloak port-forward started successfully"
  else
    echo "ERROR: Failed to start Keycloak port-forward"
    exit 1
  fi
}

# Authenticate with Keycloak
authenticate_keycloak() {
  ensure_keycloak_port_forward
  
  echo "Authenticating with Keycloak..."
  KEYCLOAK_USER=$(kubectl get secret keycloak-initial-admin -n operators -o jsonpath='{.data.username}' | base64 -d)
  KEYCLOAK_PASS=$(kubectl get secret keycloak-initial-admin -n operators -o jsonpath='{.data.password}' | base64 -d)
  
  TOKEN_RESPONSE=$(curl -s -X POST "http://localhost:8080/realms/master/protocol/openid-connect/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "username=$KEYCLOAK_USER" \
    -d "password=$KEYCLOAK_PASS" \
    -d "grant_type=password" \
    -d "client_id=admin-cli")
  
  export ACCESS_TOKEN
  ACCESS_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.access_token')
  
  if [ "$ACCESS_TOKEN" == "null" ] || [ -z "$ACCESS_TOKEN" ]; then
    echo "ERROR: Failed to authenticate with Keycloak"
    exit 1
  fi
}

# Configure Keycloak client for JupyterHub
configure_jupyterhub_keycloak_client() {
  local access_token=$1
  echo "Configuring Keycloak 'minio' client for JupyterHub..."
  
  # Check if 'minio' client exists (should be created by minio deployment)
  CLIENT_ID=$(curl -s -X GET "http://localhost:8080/admin/realms/vault/clients?clientId=minio" \
    -H "Authorization: Bearer $access_token" | jq -r '.[0].id')
  
  if [ "$CLIENT_ID" == "null" ]; then
    echo "ERROR: 'minio' client not found in Keycloak. Please deploy MinIO first."
    exit 1
  else
    echo "✓ 'minio' client found - Updating configuration with JupyterHub Redirect URIs..."
    CLIENT_UUID=$CLIENT_ID
    
    # Get current client configuration to preserve other settings
    CURRENT_CONFIG=$(curl -s -X GET "http://localhost:8080/admin/realms/vault/clients/$CLIENT_UUID" \
      -H "Authorization: Bearer $access_token")
      
    # Update redirect URIs to include both MinIO and JupyterHub
    # Using jq to merge new URIs into existing list
    echo "$CURRENT_CONFIG" | jq '.redirectUris += ["http://jupyterhub.local:8000/hub/oauth_callback", "http://localhost:8000/hub/oauth_callback", "http://*:8000/hub/oauth_callback"] | .redirectUris |= unique' > /tmp/minio_client_update.json
    
    curl -s -X PUT "http://localhost:8080/admin/realms/vault/clients/$CLIENT_UUID" \
      -H "Authorization: Bearer $access_token" \
      -H "Content-Type: application/json" \
      -d @/tmp/minio_client_update.json > /dev/null
      
    rm /tmp/minio_client_update.json
    echo "✓ Updated 'minio' client configuration"
  fi
  
  # Get Client UUID
  export CLIENT_UUID=$CLIENT_ID
  
  # Get Client Secret
  export JUPYTERHUB_CLIENT_SECRET
  JUPYTERHUB_CLIENT_SECRET=$(curl -s -X GET "http://localhost:8080/admin/realms/vault/clients/$CLIENT_UUID/client-secret" \
    -H "Authorization: Bearer $access_token" | jq -r '.value')
  
  echo "✓ Retrieved MinIO Client Secret for JupyterHub"
}

# Deploy JupyterHub
deploy_jupyterhub() {
  local client_secret=$1
  echo "Deploying JupyterHub..."
  
  # Add JupyterHub Helm repo
  echo "Adding JupyterHub Helm repo..."
  helm repo add jupyterhub https://hub.jupyter.org/helm-chart/ 2>/dev/null || true
  helm repo update
  
  # Create namespaces
  echo "Creating namespaces..."
  kubectl create namespace jupyterhub --dry-run=client -o yaml | kubectl apply -f -
  kubectl create namespace jupyterhub-users --dry-run=client -o yaml | kubectl apply -f -
  
  # Create RBAC for cross-namespace access
  echo "Configuring RBAC for cross-namespace access..."
  cat <<EOF | kubectl apply -f -
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: jupyterhub-user-pods
  namespace: jupyterhub-users
rules:
- apiGroups: [""]
  resources: ["pods", "pods/log", "pods/exec"]
  verbs: ["get", "list", "watch", "create", "delete", "deletecollection", "patch", "update"]
- apiGroups: [""]
  resources: ["persistentvolumeclaims"]
  verbs: ["get", "list", "watch", "create", "delete"]
- apiGroups: [""]
  resources: ["services"]
  verbs: ["get", "list", "watch", "create", "delete"]
- apiGroups: [""]
  resources: ["events"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: jupyterhub-user-pods
  namespace: jupyterhub-users
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: jupyterhub-user-pods
subjects:
- kind: ServiceAccount
  name: jupyterhub
  namespace: jupyterhub
EOF
  
  echo "✓ RBAC configured"
  
  # Deploy JupyterHub
  helm upgrade --install jupyterhub jupyterhub/jupyterhub \
    -n jupyterhub \
    -f helm/jupyterhub/values.yaml \
    --set hub.config.GenericOAuthenticator.client_secret="$client_secret" \
    --wait \
    --timeout=10m
  
  echo "✓ JupyterHub deployed"
}

# Wait for JupyterHub to be ready
wait_for_jupyterhub_ready() {
  echo "Waiting for JupyterHub to be ready..."
  kubectl wait --for=condition=ready pod -l component=hub -n jupyterhub --timeout=300s
  echo "✓ JupyterHub is ready"
}

# Start JupyterHub port-forward
start_jupyterhub_port_forward() {
  echo "Starting JupyterHub port-forward..."
  
  # Kill existing port-forward
  pkill -f "kubectl port-forward -n jupyterhub svc/proxy-public" 2>/dev/null || true
  
  # Start new port-forward
  nohup kubectl port-forward -n jupyterhub svc/proxy-public 8000:80 --address=0.0.0.0 > /dev/null 2>&1 &
  sleep 3
  
  echo "✓ JupyterHub accessible at http://jupyterhub.local:8000 (recommended) or http://localhost:8000"
}

# Print completion message
print_jupyterhub_completion() {
  echo ""
  echo "========================================="
  echo "JupyterHub Deployment Complete!"
  echo "========================================="
  echo ""
  echo "Architecture:"
  echo "  - JupyterHub Hub: jupyterhub namespace"
  echo "  - User Notebooks: jupyterhub-users namespace"
  echo ""
  echo "Access JupyterHub:"
  echo "  URL: http://jupyterhub.local:8000"
  echo "  Note: Ensure '127.0.0.1 jupyterhub.local' is in your /etc/hosts file (and Windows hosts file if using WSL)"
  echo "  Login: Sign in with Keycloak (admin/admin)"
  echo "  Username: admin"
  echo "  Password: admin"
  echo ""
  echo "MinIO S3 Access in Notebooks:"
  echo "  Environment variables are automatically set:"
  echo "  - AWS_ACCESS_KEY_ID"
  echo "  - AWS_SECRET_ACCESS_KEY"
  echo "  - AWS_SESSION_TOKEN"
  echo "  - S3_ENDPOINT"
  echo ""
  echo "Example Python code:"
  echo "  import boto3"
  echo "  import os"
  echo "  s3 = boto3.client('s3',"
  echo "      endpoint_url=os.environ['S3_ENDPOINT'],"
  echo "      verify=False)"
  echo "  s3.list_buckets()"
  echo ""
  echo "Check deployments:"
  echo "  kubectl get pods -n jupyterhub        # Hub pod"
  echo "  kubectl get pods -n jupyterhub-users  # User notebook pods"
  echo ""
  echo "========================================="
}
