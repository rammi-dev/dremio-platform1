#!/bin/bash
set -e

# Get the directory where this script is located and change to project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

echo "========================================="
echo "MinIO Deployment (Add-on) - GKE"
echo "========================================="
echo ""

# Check if Keycloak is running
echo "Checking Keycloak status..."
if ! kubectl get pod keycloak-0 -n operators | grep -q "Running"; then
  echo "ERROR: Keycloak is not running. Please run ./scripts/deploy-gke.sh first."
  exit 1
fi
echo "✓ Keycloak is running"

# Get Keycloak Access Token
echo "Authenticating with Keycloak..."
KEYCLOAK_USER=$(kubectl get secret keycloak-initial-admin -n operators -o jsonpath='{.data.username}' | base64 -d)
KEYCLOAK_PASS=$(kubectl get secret keycloak-initial-admin -n operators -o jsonpath='{.data.password}' | base64 -d)

TOKEN_RESPONSE=$(curl -s -X POST "http://localhost:8080/realms/master/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "username=$KEYCLOAK_USER" \
  -d "password=$KEYCLOAK_PASS" \
  -d "grant_type=password" \
  -d "client_id=admin-cli")

ACCESS_TOKEN=$(echo $TOKEN_RESPONSE | jq -r ".access_token")

if [ "$ACCESS_TOKEN" == "null" ] || [ -z "$ACCESS_TOKEN" ]; then
  echo "ERROR: Failed to authenticate with Keycloak. Is port-forward 8080 active?"
  exit 1
fi

# Configure Keycloak Client for MinIO
echo "Configuring Keycloak 'minio' client..."
# Check if client exists
CLIENT_ID=$(curl -s -X GET "http://localhost:8080/admin/realms/vault/clients?clientId=minio" \
  -H "Authorization: Bearer $ACCESS_TOKEN" | jq -r '.[0].id')

if [ "$CLIENT_ID" == "null" ]; then
  # Create client
  curl -s -X POST "http://localhost:8080/admin/realms/vault/clients" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{"clientId": "minio", "name": "MinIO Console", "enabled": true, "protocol": "openid-connect", "publicClient": false, "directAccessGrantsEnabled": true, "standardFlowEnabled": true, "redirectUris": ["https://localhost:9091/*", "http://localhost:9091/*"], "webOrigins": ["+"]}' > /dev/null
  echo "✓ Created 'minio' client"
else
  echo "✓ 'minio' client already exists - Updating Redirect URIs..."
  # Update existing client (in case port changed)
  CLIENT_UUID=$(curl -s -X GET "http://localhost:8080/admin/realms/vault/clients?clientId=minio" \
    -H "Authorization: Bearer $ACCESS_TOKEN" | jq -r '.[0].id')
    
  curl -s -X PUT "http://localhost:8080/admin/realms/vault/clients/$CLIENT_UUID" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{"clientId": "minio", "name": "MinIO Console", "enabled": true, "protocol": "openid-connect", "publicClient": false, "directAccessGrantsEnabled": true, "standardFlowEnabled": true, "redirectUris": ["https://localhost:9091/*", "http://localhost:9091/*"], "webOrigins": ["+"]}' > /dev/null
  echo "✓ Updated 'minio' client configuration"
fi

# Get Client UUID
CLIENT_UUID=$(curl -s -X GET "http://localhost:8080/admin/realms/vault/clients?clientId=minio" \
  -H "Authorization: Bearer $ACCESS_TOKEN" | jq -r '.[0].id')

# Get Client Secret
CLIENT_SECRET=$(curl -s -X GET "http://localhost:8080/admin/realms/vault/clients/$CLIENT_UUID/client-secret" \
  -H "Authorization: Bearer $ACCESS_TOKEN" | jq -r '.value')

echo "✓ Retrieved MinIO Client Secret"

# Create 'minio-access' group in Keycloak
echo "Configuring Keycloak RBAC..."
curl -s -X POST "http://localhost:8080/admin/realms/vault/groups" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name": "minio-access"}' > /dev/null

GROUP_ID=$(curl -s -X GET "http://localhost:8080/admin/realms/vault/groups?search=minio-access" \
  -H "Authorization: Bearer $ACCESS_TOKEN" | jq -r '.[0].id')

# Get Admin User ID (username: admin)
USER_ID=$(curl -s -X GET "http://localhost:8080/admin/realms/vault/users?username=admin" \
  -H "Authorization: Bearer $ACCESS_TOKEN" | jq -r '.[0].id')

# Add Admin to Group
curl -s -X PUT "http://localhost:8080/admin/realms/vault/users/$USER_ID/groups/$GROUP_ID" \
  -H "Authorization: Bearer $ACCESS_TOKEN" > /dev/null
echo "✓ Added 'admin' user to 'minio-access' group"

# Add Groups Mapper to Client
echo "Adding 'groups' mapper to 'minio' client..."
curl -s -X POST "http://localhost:8080/admin/realms/vault/clients/$CLIENT_UUID/protocol-mappers/models" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "groups-mapper",
    "protocol": "openid-connect",
    "protocolMapper": "oidc-group-membership-mapper",
    "consentRequired": false,
    "config": {
      "full.path": "false",
      "id.token.claim": "true",
      "access.token.claim": "true",
      "userinfo.token.claim": "true",
      "claim.name": "groups"
    }
  }' > /dev/null || true # Ignore if already exists for now
echo "✓ 'groups' mapper configured"

# Deploy MinIO Operator
echo "Deploying MinIO Operator..."
echo "Adding MinIO Helm repo..."
helm repo add minio-operator https://operator.min.io/ 2>/dev/null || echo "Repo already exists"
helm repo update minio-operator

kubectl create namespace minio-operator --dry-run=client -o yaml | kubectl apply -f -
echo "Installing/Upgrading MinIO Operator..."
# Pin to specific version to prevent supply-chain attacks
helm upgrade --install minio-operator minio-operator/operator \
  --version 6.0.4 \
  -n minio-operator \
  -f helm/minio/operator-values.yaml \
  --wait

echo "✓ MinIO Operator ready"

# Deploy MinIO Tenant
echo "Deploying MinIO Tenant..."
kubectl create namespace minio --dry-run=client -o yaml | kubectl apply -f -

# Pass OIDC secret via --set
# Pin to specific version to prevent supply-chain attacks
helm upgrade --install minio minio-operator/tenant \
  --version 6.0.4 \
  -n minio \
  -f helm/minio/tenant-values.yaml \
  --set tenant.configuration.envs[2].name=MINIO_IDENTITY_OPENID_CLIENT_ID \
  --set tenant.configuration.envs[2].value=minio \
  --set tenant.configuration.envs[3].name=MINIO_IDENTITY_OPENID_CLIENT_SECRET \
  --set tenant.configuration.envs[3].value=$CLIENT_SECRET \
  --wait

echo "✓ MinIO Tenant deployed"

echo "Waiting for MinIO Secret..."
sleep 5
# Extract MinIO Credentials
MINIO_SECRET_NAME=$(kubectl get secret -n minio -o jsonpath='{.items[?(@.data.config\.env)].metadata.name}' | awk '{print $1}')

if [ -z "$MINIO_SECRET_NAME" ]; then
  # Fallback: look for user-specified name
  MINIO_SECRET_NAME="minio-env-configuration"
fi

# ROBUST OIDC PATCH: Explicitly inject OIDC config into Secret and Restart Pod
echo "Ensuring OIDC Configuration Persistence..."
CURRENT_ENV=$(kubectl get secret $MINIO_SECRET_NAME -n minio -o jsonpath='{.data.config\.env}' | base64 -d)

# Construct OIDC block
OIDC_ENV="
export MINIO_BROWSER_REDIRECT_URL=\"https://localhost:9091\"
export MINIO_IDENTITY_OPENID_CONFIG_URL=\"http://keycloak-service.operators.svc.cluster.local:8080/realms/vault/.well-known/openid-configuration\"
export MINIO_IDENTITY_OPENID_CLIENT_ID=\"minio\"
export MINIO_IDENTITY_OPENID_CLIENT_SECRET=\"$CLIENT_SECRET\"
export MINIO_IDENTITY_OPENID_CLAIM_NAME=\"groups\"
export MINIO_IDENTITY_OPENID_SCOPES=\"openid,profile,email\"
export MINIO_IDENTITY_OPENID_DISPLAY_NAME=\"Keycloak\"
"

# Append if not present
if echo "$CURRENT_ENV" | grep -q "MINIO_BROWSER_REDIRECT_URL=\"https://localhost:9091\""; then
    echo "OIDC config appears up to date."
else
    echo "Injecting OIDC variables into Secret..."
    NEW_ENV="$CURRENT_ENV
$OIDC_ENV"
    
    # Apply Patch
    kubectl create secret generic $MINIO_SECRET_NAME -n minio --from-literal=config.env="$NEW_ENV" --dry-run=client -o yaml | kubectl apply -f -
    
    echo "Restarting MinIO Pod to apply configuration..."
    kubectl delete pod -n minio -l v1.min.io/tenant=minio --wait=true 2>/dev/null || true
    echo "✓ MinIO Pod restart triggered (if running)"
    
    # Wait for readiness again
    echo "Waiting for MinIO Pods to be created..."
    for i in {1..60}; do
      if kubectl get pod -n minio -l v1.min.io/tenant=minio 2>/dev/null | grep -q "minio"; then
        break
      fi
      echo "Waiting for operator to create MinIO pods... ($i/60)"
      sleep 2
    done

    echo "Waiting for MinIO to be ready..."
    kubectl wait --for=condition=ready pod -l v1.min.io/tenant=minio -n minio --timeout=300s
fi

echo "Extracting credentials from secret: $MINIO_SECRET_NAME"
MINIO_CONFIG_ENV=$(kubectl get secret $MINIO_SECRET_NAME -n minio -o jsonpath='{.data.config\.env}' | base64 -d)

# Parse existing env vars for User/Pass
MINIO_ROOT_USER=$(echo "$MINIO_CONFIG_ENV" | grep "MINIO_ROOT_USER" | cut -d'=' -f2 | tr -d '\n\r"')
MINIO_ROOT_PASSWORD=$(echo "$MINIO_CONFIG_ENV" | grep "MINIO_ROOT_PASSWORD" | cut -d'=' -f2 | tr -d '\n\r"')

if [ -z "$MINIO_ROOT_USER" ]; then
    echo "WARNING: Could not auto-detect MinIO root credentials."
else
    echo "✓ Detected MinIO Root Credentials"
    
    # Store in Vault
    echo "Storing MinIO credentials in Vault..."
    
    # Ensure we have Vault token
    if [ -f config/vault-keys.json ]; then
        ROOT_TOKEN=$(cat config/vault-keys.json | jq -r '.root_token')
        
        kubectl exec -n vault vault-0 -- vault login $ROOT_TOKEN > /dev/null
        
        # Enable secret engine if not exists
        echo "Enabling 'secret' KV engine..."
        kubectl exec -n vault vault-0 -- vault secrets enable -path=secret kv-v2 2>/dev/null || echo "Engine already enabled or error (ignoring)"

        kubectl exec -n vault vault-0 -- vault kv put secret/minio \
            access_key="$MINIO_ROOT_USER" \
            secret_key="$MINIO_ROOT_PASSWORD" \
            bucket="default-bucket" \
            endpoint="http://minio.minio.svc.cluster.local:80" > /dev/null
            
        echo "✓ Credentials stored in Vault at 'secret/minio'"
    else
        echo "WARNING: config/vault-keys.json not found. Cannot store credentials in Vault."
    fi
fi

# Create 'minio-access' policy in MinIO
echo "Waiting for MinIO Service to be ready..."
echo "Waiting for MinIO pods to be created..."
for i in {1..60}; do
  if kubectl get pod -n minio -l v1.min.io/tenant=minio 2>/dev/null | grep -q "minio"; then
    echo "✓ MinIO pods created"
    break
  fi
  if [ $i -eq 60 ]; then
     echo "ERROR: Timed out waiting for MinIO pods to be created"
     exit 1
  fi
  echo "Waiting for operator to create MinIO pods... ($i/60)"
  sleep 2
done

kubectl wait --for=condition=ready pod -l v1.min.io/tenant=minio -n minio --timeout=300s
sleep 5

echo "Creating MinIO Policy 'minio-access'..."
POLICY_JSON='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["s3:*"],"Resource":["arn:aws:s3:::default-bucket","arn:aws:s3:::default-bucket/*"]}]}'

kubectl run minio-policy-setup --image=quay.io/minio/mc:latest --restart=Never --rm -i --command -- \
  /bin/sh -c "
  echo 'Connecting to MinIO...';
  mc alias set myminio https://minio.minio.svc.cluster.local:443 $MINIO_ROOT_USER $MINIO_ROOT_PASSWORD --insecure;
  echo '$POLICY_JSON' > /tmp/policy.json;
  mc admin policy create myminio minio-access /tmp/policy.json --insecure;
  echo 'Policy minio-access created';
  "

if [ $? -eq 0 ]; then
  echo "✓ MinIO Policy 'minio-access' created"
else
  echo "WARNING: Failed to create MinIO Policy. Check logs above."
fi

# Start Port-Forward
echo "Starting MinIO Console Port-Forward..."
pkill -f "kubectl port-forward -n minio svc/minio-console" || true
nohup kubectl port-forward -n minio svc/minio-console 9091:9443 --address=0.0.0.0 > /dev/null 2>&1 &
echo "✓ Port-forward started"

echo ""
echo "========================================="
echo "MinIO Ready!"
echo "========================================="
echo "Console: http://localhost:9091"
echo "Login: Click 'Login with OpenID' -> Login with 'admin' / 'admin'"
echo ""
