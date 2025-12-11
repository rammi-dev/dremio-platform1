#!/bin/bash
# Common functions for MinIO deployment across different environments

# Check if Keycloak is running
check_keycloak_status() {
  local deploy_script=$1
  echo "Checking Keycloak status..."
  if ! kubectl get pod keycloak-0 -n operators | grep -q "Running"; then
    echo "ERROR: Keycloak is not running. Please run $deploy_script first."
    exit 1
  fi
  echo "✓ Keycloak is running"
}

# Authenticate with Keycloak and get access token
authenticate_keycloak() {
  echo "Authenticating with Keycloak..."
  KEYCLOAK_USER=$(kubectl get secret keycloak-initial-admin -n operators -o jsonpath='{.data.username}' | base64 -d)
  KEYCLOAK_PASS=$(kubectl get secret keycloak-initial-admin -n operators -o jsonpath='{.data.password}' | base64 -d)
  
  TOKEN_RESPONSE=$(curl -s -X POST "http://localhost:8080/realms/master/protocol/openid-connect/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "username=$KEYCLOAK_USER" \
    -d "password=$KEYCLOAK_PASS" \
    -d "grant_type=password" \
    -d "client_id=admin-cli")
  
  # Export so it's available to calling scripts
  export ACCESS_TOKEN
  ACCESS_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r ".access_token")
  
  if [ "$ACCESS_TOKEN" == "null" ] || [ -z "$ACCESS_TOKEN" ]; then
    echo "ERROR: Failed to authenticate with Keycloak. Is port-forward 8080 active?"
    exit 1
  fi
}

# Configure Keycloak client for MinIO
configure_keycloak_client() {
  local access_token=$1
  echo "Configuring Keycloak 'minio' client..."
  
  # Check if client exists
  CLIENT_ID=$(curl -s -X GET "http://localhost:8080/admin/realms/vault/clients?clientId=minio" \
    -H "Authorization: Bearer $access_token" | jq -r '.[0].id')
  
  if [ "$CLIENT_ID" == "null" ]; then
    # Create client
    curl -s -X POST "http://localhost:8080/admin/realms/vault/clients" \
      -H "Authorization: Bearer $access_token" \
      -H "Content-Type: application/json" \
      -d '{"clientId": "minio", "name": "MinIO Console", "enabled": true, "protocol": "openid-connect", "publicClient": false, "directAccessGrantsEnabled": true, "standardFlowEnabled": true, "redirectUris": ["https://localhost:9091/*", "http://localhost:9091/*"], "webOrigins": ["+"]}' > /dev/null
    echo "✓ Created 'minio' client"
  else
    echo "✓ 'minio' client already exists - Updating Redirect URIs..."
    # Update existing client (in case port changed)
    CLIENT_UUID=$(curl -s -X GET "http://localhost:8080/admin/realms/vault/clients?clientId=minio" \
      -H "Authorization: Bearer $access_token" | jq -r '.[0].id')
      
    curl -s -X PUT "http://localhost:8080/admin/realms/vault/clients/$CLIENT_UUID" \
      -H "Authorization: Bearer $access_token" \
      -H "Content-Type: application/json" \
      -d '{"clientId": "minio", "name": "MinIO Console", "enabled": true, "protocol": "openid-connect", "publicClient": false, "directAccessGrantsEnabled": true, "standardFlowEnabled": true, "redirectUris": ["https://localhost:9091/*", "http://localhost:9091/*"], "webOrigins": ["+"]}' > /dev/null
    echo "✓ Updated 'minio' client configuration"
  fi
  
  # Get Client UUID
  # Export so it's available to calling scripts
  export CLIENT_UUID
  CLIENT_UUID=$(curl -s -X GET "http://localhost:8080/admin/realms/vault/clients?clientId=minio" \
    -H "Authorization: Bearer $access_token" | jq -r '.[0].id')
  
  # Get Client Secret
  # Export so it's available to calling scripts
  export CLIENT_SECRET
  CLIENT_SECRET=$(curl -s -X GET "http://localhost:8080/admin/realms/vault/clients/$CLIENT_UUID/client-secret" \
    -H "Authorization: Bearer $access_token" | jq -r '.value')
  
  echo "✓ Retrieved MinIO Client Secret"
}

# Configure Keycloak RBAC for MinIO
configure_keycloak_rbac() {
  local access_token=$1
  echo "Configuring Keycloak RBAC..."
  
  # Create 'minio-access' group in Keycloak
  curl -s -X POST "http://localhost:8080/admin/realms/vault/groups" \
    -H "Authorization: Bearer $access_token" \
    -H "Content-Type: application/json" \
    -d '{"name": "minio-access"}' > /dev/null
  
  GROUP_ID=$(curl -s -X GET "http://localhost:8080/admin/realms/vault/groups?search=minio-access" \
    -H "Authorization: Bearer $access_token" | jq -r '.[0].id')
  
  # Get Admin User ID (username: admin)
  USER_ID=$(curl -s -X GET "http://localhost:8080/admin/realms/vault/users?username=admin" \
    -H "Authorization: Bearer $access_token" | jq -r '.[0].id')
  
  # Add Admin to Group
  curl -s -X PUT "http://localhost:8080/admin/realms/vault/users/$USER_ID/groups/$GROUP_ID" \
    -H "Authorization: Bearer $access_token" > /dev/null
  echo "✓ Added 'admin' user to 'minio-access' group"
}

# Add groups mapper to Keycloak client
add_groups_mapper() {
  local access_token=$1
  local client_uuid=$2
  echo "Adding 'groups' mapper to 'minio' client..."
  
  curl -s -X POST "http://localhost:8080/admin/realms/vault/clients/$client_uuid/protocol-mappers/models" \
    -H "Authorization: Bearer $access_token" \
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
    }' > /dev/null || true # Ignore if already exists
  echo "✓ 'groups' mapper configured"
}

# Deploy MinIO Operator
deploy_minio_operator() {
  echo "Deploying MinIO Operator..."
  echo "Adding MinIO Helm repo..."
  helm repo add minio-operator https://operator.min.io/ 2>/dev/null || echo "Repo already exists"
  helm repo update minio-operator
  
  kubectl create namespace minio-operator --dry-run=client -o yaml | kubectl apply -f -
  echo "Installing/Upgrading MinIO Operator..."
  helm upgrade --install minio-operator minio-operator/operator -n minio-operator -f helm/minio/operator-values.yaml --wait
  
  echo "✓ MinIO Operator ready"
}

# Deploy MinIO Tenant
deploy_minio_tenant() {
  local client_secret=$1
  echo "Deploying MinIO Tenant..."
  kubectl create namespace minio --dry-run=client -o yaml | kubectl apply -f -
  
  # Pass OIDC secret via --set
  helm upgrade --install minio minio-operator/tenant -n minio -f helm/minio/tenant-values.yaml \
    --set tenant.configuration.envs[2].name=MINIO_IDENTITY_OPENID_CLIENT_ID \
    --set tenant.configuration.envs[2].value=minio \
    --set tenant.configuration.envs[3].name=MINIO_IDENTITY_OPENID_CLIENT_SECRET \
    --set tenant.configuration.envs[3].value="$client_secret" \
    --wait
  
  echo "✓ MinIO Tenant deployed"
}

# Configure OIDC for MinIO
configure_minio_oidc() {
  local client_secret=$1
  echo "Waiting for MinIO Secret..."
  sleep 5
  
  # Extract MinIO Credentials
  # The secret name is typically <tenant-name>-configuration or similar depending on chart version.
  # We will look for the secret that contains MINIO_ROOT_USER
  # Export so it's available to other functions
  export MINIO_SECRET_NAME
  MINIO_SECRET_NAME=$(kubectl get secret -n minio -o jsonpath='{.items[?(@.data.config\.env)].metadata.name}' | awk '{print $1}')
  
  if [ -z "$MINIO_SECRET_NAME" ]; then
    # Fallback: look for user-specified name
    MINIO_SECRET_NAME="minio-env-configuration"
  fi
  
  # ROBUST OIDC PATCH: Explicitly inject OIDC config into Secret and Restart Pod
  # This ensures OIDC is active regardless of Operator sync issues
  echo "Ensuring OIDC Configuration Persistence..."
  if ! CURRENT_ENV=$(kubectl get secret "$MINIO_SECRET_NAME" -n minio -o jsonpath='{.data.config\.env}' | base64 -d); then
    echo "ERROR: Failed to retrieve MinIO secret configuration"
    exit 1
  fi
  
  # Construct OIDC block
  OIDC_ENV="
export MINIO_BROWSER_REDIRECT_URL=\"https://localhost:9091\"
export MINIO_IDENTITY_OPENID_CONFIG_URL=\"http://keycloak-service.operators.svc.cluster.local:8080/realms/vault/.well-known/openid-configuration\"
export MINIO_IDENTITY_OPENID_CLIENT_ID=\"minio\"
export MINIO_IDENTITY_OPENID_CLIENT_SECRET=\"$client_secret\"
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
      kubectl create secret generic "$MINIO_SECRET_NAME" -n minio --from-literal=config.env="$NEW_ENV" --dry-run=client -o yaml | kubectl apply -f -
      
      echo "Restarting MinIO Pod to apply configuration..."
      # We use 'wait=true' to ensure the old pod is gone. Allow failure if pod doesn't exist yet.
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
}

# Extract MinIO credentials
extract_minio_credentials() {
  echo "Extracting credentials from secret: $MINIO_SECRET_NAME"
  MINIO_CONFIG_ENV=$(kubectl get secret "$MINIO_SECRET_NAME" -n minio -o jsonpath='{.data.config\.env}' | base64 -d)
  
  # Parse existing env vars for User/Pass
  # Export so they're available to calling scripts
  export MINIO_ROOT_USER
  export MINIO_ROOT_PASSWORD
  MINIO_ROOT_USER=$(echo "$MINIO_CONFIG_ENV" | grep "MINIO_ROOT_USER" | cut -d'=' -f2 | tr -d '\n\r"')
  MINIO_ROOT_PASSWORD=$(echo "$MINIO_CONFIG_ENV" | grep "MINIO_ROOT_PASSWORD" | cut -d'=' -f2 | tr -d '\n\r"')
  
  if [ -z "$MINIO_ROOT_USER" ]; then
      echo "WARNING: Could not auto-detect MinIO root credentials."
  else
      echo "✓ Detected MinIO Root Credentials"
  fi
}

# Store MinIO credentials in Vault
store_credentials_in_vault() {
  local minio_user=$1
  local minio_password=$2
  
  echo "Storing MinIO credentials in Vault..."
  
  # Ensure we have Vault token
  if [ -f config/vault-keys.json ]; then
      ROOT_TOKEN=$(jq -r '.root_token' config/vault-keys.json)
      
      if ! kubectl exec -n vault vault-0 -- vault login "$ROOT_TOKEN" > /dev/null; then
        echo "ERROR: Failed to login to Vault"
        return 1
      fi
      
      # Enable secret engine if not exists
      echo "Enabling 'secret' KV engine..."
      kubectl exec -n vault vault-0 -- vault secrets enable -path=secret kv-v2 2>/dev/null || echo "Engine already enabled or error (ignoring)"

      kubectl exec -n vault vault-0 -- vault kv put secret/minio \
          access_key="$minio_user" \
          secret_key="$minio_password" \
          bucket="default-bucket" \
          endpoint="http://minio.minio.svc.cluster.local:80" > /dev/null
          
      echo "✓ Credentials stored in Vault at 'secret/minio'"
  else
      echo "WARNING: config/vault-keys.json not found. Cannot store credentials in Vault."
  fi
}

# Wait for MinIO pods to be ready
wait_for_minio_ready() {
  echo "Waiting for MinIO Service to be ready..."
  echo "Waiting for MinIO pods to be created..."
  for i in {1..60}; do
    if kubectl get pod -n minio -l v1.min.io/tenant=minio 2>/dev/null | grep -q "minio"; then
      echo "✓ MinIO pods created"
      break
    fi
    if [ "$i" -eq 60 ]; then
       echo "ERROR: Timed out waiting for MinIO pods to be created"
       exit 1
    fi
    echo "Waiting for operator to create MinIO pods... ($i/60)"
    sleep 2
  done
  
  kubectl wait --for=condition=ready pod -l v1.min.io/tenant=minio -n minio --timeout=300s
  sleep 5
}

# Create MinIO policy
create_minio_policy() {
  local minio_user=$1
  local minio_password=$2
  
  echo "Creating MinIO Policy 'minio-access'..."
  POLICY_JSON='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["s3:*"],"Resource":["arn:aws:s3:::default-bucket","arn:aws:s3:::default-bucket/*"]}]}'
  
  if kubectl run minio-policy-setup --image=quay.io/minio/mc:latest --restart=Never --rm -i --command -- \
    /bin/sh -c "
    echo 'Connecting to MinIO...';
    mc alias set myminio https://minio.minio.svc.cluster.local:443 '$minio_user' '$minio_password' --insecure;
    echo '$POLICY_JSON' > /tmp/policy.json;
    mc admin policy create myminio minio-access /tmp/policy.json --insecure;
    echo 'Policy minio-access created';
    "; then
    echo "✓ MinIO Policy 'minio-access' created"
  else
    echo "WARNING: Failed to create MinIO Policy. Check logs above."
  fi
}

# Start port-forward for MinIO console
start_port_forward() {
  echo "Starting MinIO Console Port-Forward..."
  pkill -f "kubectl port-forward -n minio svc/minio-console" || true
  # Use 127.0.0.1 for localhost-only access for security
  nohup kubectl port-forward -n minio svc/minio-console 9091:9443 --address=127.0.0.1 > /dev/null 2>&1 &
  echo "✓ Port-forward started"
}

# Print completion message
print_completion_message() {
  echo ""
  echo "========================================="
  echo "MinIO Ready!"
  echo "========================================="
  echo "Console: http://localhost:9091"
  echo "Login: Click 'Login with OpenID' -> Login with 'admin' / 'admin'"
  echo ""
}
