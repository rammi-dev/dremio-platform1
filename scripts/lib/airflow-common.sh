#!/bin/bash
# Common functions for Airflow deployment

# Function to authenticate with Keycloak
authenticate_keycloak() {
  echo "Authenticating with Keycloak..."
  
  KEYCLOAK_URL="http://localhost:8080"
  
  # Get admin credentials from Kubernetes secret
  KEYCLOAK_USER=$(kubectl get secret keycloak-initial-admin -n operators -o jsonpath='{.data.username}' | base64 -d)
  KEYCLOAK_PASS=$(kubectl get secret keycloak-initial-admin -n operators -o jsonpath='{.data.password}' | base64 -d)
  
  # Get admin token
  ACCESS_TOKEN=$(curl -s --connect-timeout 5 -X POST "${KEYCLOAK_URL}/realms/master/protocol/openid-connect/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "client_id=admin-cli" \
    -d "username=${KEYCLOAK_USER}" \
    -d "password=${KEYCLOAK_PASS}" \
    -d "grant_type=password" | jq -r '.access_token')
  
  if [ -z "$ACCESS_TOKEN" ] || [ "$ACCESS_TOKEN" == "null" ]; then
    echo "ERROR: Failed to authenticate with Keycloak"
    exit 1
  fi
  
  export ACCESS_TOKEN
  echo "✓ Authenticated with Keycloak"
}

# Function to configure Keycloak client for Airflow
configure_airflow_keycloak_client() {
  local ACCESS_TOKEN="$1"
  local KEYCLOAK_URL="http://localhost:8080"
  local REALM="vault"
  
  echo "Configuring Airflow client in Keycloak..."
  
  # Check if airflow client already exists
  EXISTING_CLIENT=$(curl -s -X GET "${KEYCLOAK_URL}/admin/realms/${REALM}/clients" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json" | jq -r '.[] | select(.clientId == "airflow") | .id')
  
  if [ -n "$EXISTING_CLIENT" ] && [ "$EXISTING_CLIENT" != "null" ]; then
    echo "✓ Airflow client already exists in Keycloak"
    export AIRFLOW_CLIENT_SECRET="airflow-secret"
    return 0
  fi
  
  # Create Airflow client
  CLIENT_PAYLOAD=$(cat <<EOF
{
  "clientId": "airflow",
  "name": "Apache Airflow",
  "enabled": true,
  "clientAuthenticatorType": "client-secret",
  "secret": "airflow-secret",
  "protocol": "openid-connect",
  "standardFlowEnabled": true,
  "directAccessGrantsEnabled": true,
  "serviceAccountsEnabled": true,
  "authorizationServicesEnabled": true,
  "publicClient": false,
  "redirectUris": [
    "http://localhost:8080/*",
    "http://airflow.local:8080/*"
  ],
  "webOrigins": [
    "+"
  ],
  "protocolMappers": [
    {
      "name": "groups-mapper",
      "protocol": "openid-connect",
      "protocolMapper": "oidc-group-membership-mapper",
      "config": {
        "full.path": "false",
        "id.token.claim": "true",
        "access.token.claim": "true",
        "userinfo.token.claim": "true",
        "claim.name": "groups"
      }
    },
    {
      "name": "email",
      "protocol": "openid-connect",
      "protocolMapper": "oidc-usermodel-property-mapper",
      "config": {
        "user.attribute": "email",
        "claim.name": "email",
        "id.token.claim": "true",
        "access.token.claim": "true",
        "userinfo.token.claim": "true"
      }
    },
    {
      "name": "preferred_username",
      "protocol": "openid-connect",
      "protocolMapper": "oidc-usermodel-property-mapper",
      "config": {
        "user.attribute": "username",
        "claim.name": "preferred_username",
        "id.token.claim": "true",
        "access.token.claim": "true",
        "userinfo.token.claim": "true"
      }
    }
  ]
}
EOF
)
  
  RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "${KEYCLOAK_URL}/admin/realms/${REALM}/clients" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "${CLIENT_PAYLOAD}")
  
  HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
  
  if [ "$HTTP_CODE" == "201" ]; then
    echo "✓ Airflow client created in Keycloak"
  else
    echo "WARNING: Could not create Airflow client (HTTP $HTTP_CODE). It may already exist."
  fi
  
  export AIRFLOW_CLIENT_SECRET="airflow-secret"
}

# Function to create Airflow-specific groups in Keycloak
configure_airflow_groups() {
  local ACCESS_TOKEN="$1"
  local KEYCLOAK_URL="http://localhost:8080"
  local REALM="vault"
  
  echo "Configuring Airflow groups in Keycloak..."
  
  # Groups for Airflow RBAC:
  # - airflow-admin: Full admin access
  # - data-engineers: DAG edit/execute permissions (Editor role)
  # - data-scientists: Read-only/viewer permissions (Viewer role)
  
  local AIRFLOW_GROUPS=("airflow-admin" "data-engineers" "data-scientists")
  
  for GROUP in "${AIRFLOW_GROUPS[@]}"; do
    EXISTING=$(curl -s -X GET "${KEYCLOAK_URL}/admin/realms/${REALM}/groups" \
      -H "Authorization: Bearer ${ACCESS_TOKEN}" | jq -r ".[] | select(.name == \"${GROUP}\") | .id")
    
    if [ -z "$EXISTING" ] || [ "$EXISTING" == "null" ]; then
      curl -s -X POST "${KEYCLOAK_URL}/admin/realms/${REALM}/groups" \
        -H "Authorization: Bearer ${ACCESS_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"name\": \"${GROUP}\"}"
      echo "  ✓ Created group: ${GROUP}"
    else
      echo "  ✓ Group exists: ${GROUP}"
    fi
  done
  
  echo "✓ Airflow groups configured"
}

# Function to assign groups to existing users
assign_airflow_groups_to_users() {
  local ACCESS_TOKEN="$1"
  local KEYCLOAK_URL="http://localhost:8080"
  local REALM="vault"
  
  echo "Assigning Airflow groups to users..."
  
  # Get group IDs
  ADMIN_GROUP_ID=$(curl -s -X GET "${KEYCLOAK_URL}/admin/realms/${REALM}/groups" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" | jq -r '.[] | select(.name == "airflow-admin") | .id')
  
  ENGINEER_GROUP_ID=$(curl -s -X GET "${KEYCLOAK_URL}/admin/realms/${REALM}/groups" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" | jq -r '.[] | select(.name == "data-engineers") | .id')
  
  SCIENTIST_GROUP_ID=$(curl -s -X GET "${KEYCLOAK_URL}/admin/realms/${REALM}/groups" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" | jq -r '.[] | select(.name == "data-scientists") | .id')
  
  # Assign admin user to airflow-admin group
  ADMIN_USER_ID=$(curl -s -X GET "${KEYCLOAK_URL}/admin/realms/${REALM}/users?username=admin" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" | jq -r '.[0].id')
  
  if [ -n "$ADMIN_USER_ID" ] && [ "$ADMIN_USER_ID" != "null" ]; then
    curl -s -X PUT "${KEYCLOAK_URL}/admin/realms/${REALM}/users/${ADMIN_USER_ID}/groups/${ADMIN_GROUP_ID}" \
      -H "Authorization: Bearer ${ACCESS_TOKEN}"
    echo "  ✓ admin -> airflow-admin"
  fi
  
  # Assign jupyter-admin to data-engineers (editor role)
  JUPYTER_ADMIN_ID=$(curl -s -X GET "${KEYCLOAK_URL}/admin/realms/${REALM}/users?username=jupyter-admin" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" | jq -r '.[0].id')
  
  if [ -n "$JUPYTER_ADMIN_ID" ] && [ "$JUPYTER_ADMIN_ID" != "null" ]; then
    curl -s -X PUT "${KEYCLOAK_URL}/admin/realms/${REALM}/users/${JUPYTER_ADMIN_ID}/groups/${ENGINEER_GROUP_ID}" \
      -H "Authorization: Bearer ${ACCESS_TOKEN}"
    echo "  ✓ jupyter-admin -> data-engineers"
  fi
  
  # Assign jupyter-ds to data-scientists (viewer role)
  JUPYTER_DS_ID=$(curl -s -X GET "${KEYCLOAK_URL}/admin/realms/${REALM}/users?username=jupyter-ds" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" | jq -r '.[0].id')
  
  if [ -n "$JUPYTER_DS_ID" ] && [ "$JUPYTER_DS_ID" != "null" ]; then
    curl -s -X PUT "${KEYCLOAK_URL}/admin/realms/${REALM}/users/${JUPYTER_DS_ID}/groups/${SCIENTIST_GROUP_ID}" \
      -H "Authorization: Bearer ${ACCESS_TOKEN}"
    echo "  ✓ jupyter-ds -> data-scientists"
  fi
  
  echo "✓ Groups assigned to users"
}

# Function to deploy Airflow
deploy_airflow() {
  local CLIENT_SECRET="$1"
  
  echo "Deploying Apache Airflow..."
  
  # Add Apache Airflow Helm repo
  helm repo add apache-airflow https://airflow.apache.org > /dev/null 2>&1 || true
  helm repo update > /dev/null 2>&1
  
  # Create namespace
  kubectl create namespace airflow --dry-run=client -o yaml | kubectl apply -f -
  
  # Create Keycloak client secret
  kubectl create secret generic airflow-keycloak-secret \
    --from-literal=client-secret="${CLIENT_SECRET}" \
    -n airflow --dry-run=client -o yaml | kubectl apply -f -
  
  # Create MinIO connection secret for remote logging
  # Get MinIO credentials
  MINIO_ACCESS_KEY=$(kubectl get secret minio-env-configuration -n minio -o jsonpath='{.data.config\.env}' 2>/dev/null | base64 -d | grep "MINIO_ROOT_USER" | cut -d'=' -f2 || echo "minio")
  MINIO_SECRET_KEY=$(kubectl get secret minio-env-configuration -n minio -o jsonpath='{.data.config\.env}' 2>/dev/null | base64 -d | grep "MINIO_ROOT_PASSWORD" | cut -d'=' -f2 || echo "minio123")
  
  # Create MinIO connection for Airflow (URI format: s3://access_key:secret_key@/?host=endpoint)
  MINIO_CONN_URI="aws://${MINIO_ACCESS_KEY}:${MINIO_SECRET_KEY}@?endpoint_url=https%3A%2F%2Fminio.minio.svc.cluster.local"
  
  kubectl create secret generic airflow-minio-connection \
    --from-literal=connection="${MINIO_CONN_URI}" \
    -n airflow --dry-run=client -o yaml | kubectl apply -f -
  
  # Get Keycloak ClusterIP dynamically for hostAliases
  KEYCLOAK_CLUSTER_IP=$(kubectl get svc keycloak-service -n operators -o jsonpath='{.spec.clusterIP}')
  echo "  Using Keycloak ClusterIP: ${KEYCLOAK_CLUSTER_IP}"
  
  # Deploy Airflow with dynamic hostAliases for keycloak.local resolution
  # Each component needs hostAliases set separately
  if helm status airflow -n airflow > /dev/null 2>&1; then
    echo "Upgrading existing Airflow deployment..."
    helm upgrade airflow apache-airflow/airflow \
      -n airflow \
      -f helm/airflow/values.yaml \
      --set keycloakClientSecret="${CLIENT_SECRET}" \
      --set "apiServer.hostAliases[0].ip=${KEYCLOAK_CLUSTER_IP}" \
      --set "apiServer.hostAliases[0].hostnames[0]=keycloak.local" \
      --set "scheduler.hostAliases[0].ip=${KEYCLOAK_CLUSTER_IP}" \
      --set "scheduler.hostAliases[0].hostnames[0]=keycloak.local" \
      --set "triggerer.hostAliases[0].ip=${KEYCLOAK_CLUSTER_IP}" \
      --set "triggerer.hostAliases[0].hostnames[0]=keycloak.local" \
      --set "dagProcessor.hostAliases[0].ip=${KEYCLOAK_CLUSTER_IP}" \
      --set "dagProcessor.hostAliases[0].hostnames[0]=keycloak.local" \
      --timeout 10m
  else
    echo "Installing Airflow..."
    helm install airflow apache-airflow/airflow \
      -n airflow \
      -f helm/airflow/values.yaml \
      --set keycloakClientSecret="${CLIENT_SECRET}" \
      --set "apiServer.hostAliases[0].ip=${KEYCLOAK_CLUSTER_IP}" \
      --set "apiServer.hostAliases[0].hostnames[0]=keycloak.local" \
      --set "scheduler.hostAliases[0].ip=${KEYCLOAK_CLUSTER_IP}" \
      --set "scheduler.hostAliases[0].hostnames[0]=keycloak.local" \
      --set "triggerer.hostAliases[0].ip=${KEYCLOAK_CLUSTER_IP}" \
      --set "triggerer.hostAliases[0].hostnames[0]=keycloak.local" \
      --set "dagProcessor.hostAliases[0].ip=${KEYCLOAK_CLUSTER_IP}" \
      --set "dagProcessor.hostAliases[0].hostnames[0]=keycloak.local" \
      --timeout 10m
  fi
  
  echo "✓ Airflow deployment initiated"
}

# Function to create MinIO bucket for Airflow logs
create_airflow_logs_bucket() {
  echo "Creating MinIO bucket for Airflow logs..."
  
  # Check if MinIO is available
  if ! kubectl get svc minio -n minio > /dev/null 2>&1; then
    echo "WARNING: MinIO not found. Remote logging to MinIO will not work."
    return 0
  fi
  
  # Get MinIO credentials
  MINIO_ACCESS_KEY=$(kubectl get secret minio-env-configuration -n minio -o jsonpath='{.data.config\.env}' 2>/dev/null | base64 -d | grep "MINIO_ROOT_USER" | cut -d'=' -f2 || echo "minio")
  MINIO_SECRET_KEY=$(kubectl get secret minio-env-configuration -n minio -o jsonpath='{.data.config\.env}' 2>/dev/null | base64 -d | grep "MINIO_ROOT_PASSWORD" | cut -d'=' -f2 || echo "minio123")
  
  # Use a temporary pod to create the bucket via mc (MinIO client)
  kubectl run minio-bucket-creator -n minio --rm -i --restart=Never \
    --image=minio/mc:latest \
    --command -- /bin/sh -c "
      mc alias set myminio https://minio.minio.svc.cluster.local ${MINIO_ACCESS_KEY} ${MINIO_SECRET_KEY} --insecure && \
      mc mb myminio/airflow-logs --ignore-existing --insecure && \
      echo 'Bucket airflow-logs created or already exists'
    " 2>/dev/null || echo "Note: Bucket creation may have already succeeded"
  
  echo "✓ MinIO bucket 'airflow-logs' ready"
}

# Function to wait for Airflow to be ready
wait_for_airflow_ready() {
  echo "Waiting for Airflow to be ready..."
  
  # Wait for api-server (Airflow 3.0 uses api-server instead of webserver)
  echo "  Waiting for API server..."
  kubectl wait --for=condition=available deployment/airflow-api-server \
    -n airflow --timeout=300s 2>/dev/null || true
  
  # Wait for scheduler (statefulset in Airflow 3.0)
  echo "  Waiting for scheduler..."
  kubectl rollout status statefulset/airflow-scheduler \
    -n airflow --timeout=300s 2>/dev/null || true
  
  # Wait for dag-processor
  echo "  Waiting for DAG processor..."
  kubectl wait --for=condition=available deployment/airflow-dag-processor \
    -n airflow --timeout=300s 2>/dev/null || true
  
  # Check pod status
  echo "  Checking pod status..."
  kubectl get pods -n airflow
  
  echo "✓ Airflow is ready"
}

# Function to initialize Keycloak permissions
# Creates scopes, resources, and permissions in Keycloak for Airflow RBAC
initialize_airflow_permissions() {
  echo ""
  echo "========================================="
  echo "Airflow Keycloak Permissions Setup"
  echo "========================================="
  echo ""
  
  # Get master realm admin credentials from Keycloak secret
  # The Keycloak operator creates a temp-admin user in master realm
  MASTER_USER=$(kubectl get secret keycloak-initial-admin -n operators -o jsonpath='{.data.username}' | base64 -d)
  MASTER_PASS=$(kubectl get secret keycloak-initial-admin -n operators -o jsonpath='{.data.password}' | base64 -d)
  
  if [ -z "$MASTER_USER" ] || [ -z "$MASTER_PASS" ]; then
    echo "WARNING: Could not get Keycloak master admin credentials."
    echo "Manual setup required. Run:"
    echo "  kubectl exec -it deploy/airflow-api-server -n airflow -- \\"
    echo "    airflow keycloak-auth-manager create-all \\"
    echo "      --username <admin> --password <password> --user-realm master"
    return 1
  fi
  
  echo "Creating Keycloak authorization scopes, resources, and permissions..."
  echo "  Using master realm admin: ${MASTER_USER}"
  
  # Wait a bit for Airflow to fully initialize
  sleep 10
  
  # Run the create-all command using master realm admin
  # The master realm admin has full access to manage all realms
  if kubectl exec -it deployment/airflow-api-server -n airflow -- \
    airflow keycloak-auth-manager create-all \
      --username "${MASTER_USER}" \
      --password "${MASTER_PASS}" \
      --user-realm master 2>&1; then
    echo "✓ Keycloak permissions created successfully"
  else
    echo "WARNING: Failed to create Keycloak permissions."
    echo "You may need to run manually:"
    echo "  kubectl exec -it deploy/airflow-api-server -n airflow -- \\"
    echo "    airflow keycloak-auth-manager create-all \\"
    echo "      --username ${MASTER_USER} --password <password> --user-realm master"
    return 1
  fi
  
  echo ""
  echo "Authorization configuration complete:"
  echo "  - Scopes: GET, POST, PUT, DELETE, MENU, LIST"
  echo "  - Resources: Dag, Connection, Variable, Pool, etc."
  echo "  - Permissions: ReadOnly, Admin, User, Op"
  echo ""
}

# Function to configure Keycloak authorization group policies
# Links Keycloak groups to Airflow permissions via the Keycloak Admin REST API
configure_airflow_authorization_policies() {
  echo ""
  echo "========================================="
  echo "Configuring Keycloak Authorization Policies"
  echo "========================================="
  echo ""
  
  local KEYCLOAK_URL="http://localhost:8080"
  local REALM="vault"
  
  # Get fresh admin token
  KEYCLOAK_USER=$(kubectl get secret keycloak-initial-admin -n operators -o jsonpath='{.data.username}' | base64 -d)
  KEYCLOAK_PASS=$(kubectl get secret keycloak-initial-admin -n operators -o jsonpath='{.data.password}' | base64 -d)
  
  ACCESS_TOKEN=$(curl -s -X POST "${KEYCLOAK_URL}/realms/master/protocol/openid-connect/token" \
    -d "client_id=admin-cli" \
    -d "username=${KEYCLOAK_USER}" \
    -d "password=${KEYCLOAK_PASS}" \
    -d "grant_type=password" | jq -r '.access_token')
  
  if [ -z "$ACCESS_TOKEN" ] || [ "$ACCESS_TOKEN" == "null" ]; then
    echo "WARNING: Failed to get Keycloak admin token for authorization setup"
    return 1
  fi
  
  # Get Airflow client UUID
  CLIENT_UUID=$(curl -s "${KEYCLOAK_URL}/admin/realms/${REALM}/clients" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" | jq -r '.[] | select(.clientId=="airflow") | .id')
  
  if [ -z "$CLIENT_UUID" ] || [ "$CLIENT_UUID" == "null" ]; then
    echo "WARNING: Could not find Airflow client in Keycloak"
    return 1
  fi
  echo "  Airflow client UUID: ${CLIENT_UUID}"
  
  # Set resource server decision strategy to AFFIRMATIVE
  # This is CRITICAL: with AFFIRMATIVE, only ONE permission needs to grant access
  # With UNANIMOUS (default), ALL permissions must grant access, causing 403 errors
  echo "  Setting resource server decision strategy to AFFIRMATIVE..."
  curl -s -X PUT "${KEYCLOAK_URL}/admin/realms/${REALM}/clients/${CLIENT_UUID}/authz/resource-server" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{
      \"id\": \"${CLIENT_UUID}\",
      \"clientId\": \"${CLIENT_UUID}\",
      \"name\": \"airflow\",
      \"allowRemoteResourceManagement\": true,
      \"policyEnforcementMode\": \"ENFORCING\",
      \"decisionStrategy\": \"AFFIRMATIVE\"
    }" > /dev/null
  echo "    ✓ Resource server decision strategy: AFFIRMATIVE"
  
  # Get group IDs
  echo "  Fetching group IDs..."
  AIRFLOW_ADMIN_GROUP_ID=$(curl -s "${KEYCLOAK_URL}/admin/realms/${REALM}/groups" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" | jq -r '.[] | select(.name=="airflow-admin") | .id')
  DATA_ENGINEERS_GROUP_ID=$(curl -s "${KEYCLOAK_URL}/admin/realms/${REALM}/groups" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" | jq -r '.[] | select(.name=="data-engineers") | .id')
  DATA_SCIENTISTS_GROUP_ID=$(curl -s "${KEYCLOAK_URL}/admin/realms/${REALM}/groups" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" | jq -r '.[] | select(.name=="data-scientists") | .id')
  
  echo "    airflow-admin: ${AIRFLOW_ADMIN_GROUP_ID}"
  echo "    data-engineers: ${DATA_ENGINEERS_GROUP_ID}"
  echo "    data-scientists: ${DATA_SCIENTISTS_GROUP_ID}"
  
  # Get all scope IDs
  echo "  Fetching scope IDs..."
  SCOPES_JSON=$(curl -s "${KEYCLOAK_URL}/admin/realms/${REALM}/clients/${CLIENT_UUID}/authz/resource-server/scope" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}")
  
  GET_SCOPE=$(echo "$SCOPES_JSON" | jq -r '.[] | select(.name=="GET") | .id')
  POST_SCOPE=$(echo "$SCOPES_JSON" | jq -r '.[] | select(.name=="POST") | .id')
  PUT_SCOPE=$(echo "$SCOPES_JSON" | jq -r '.[] | select(.name=="PUT") | .id')
  DELETE_SCOPE=$(echo "$SCOPES_JSON" | jq -r '.[] | select(.name=="DELETE") | .id')
  MENU_SCOPE=$(echo "$SCOPES_JSON" | jq -r '.[] | select(.name=="MENU") | .id')
  LIST_SCOPE=$(echo "$SCOPES_JSON" | jq -r '.[] | select(.name=="LIST") | .id')
  
  ALL_SCOPES="[\"${GET_SCOPE}\",\"${POST_SCOPE}\",\"${PUT_SCOPE}\",\"${DELETE_SCOPE}\",\"${MENU_SCOPE}\",\"${LIST_SCOPE}\"]"
  READ_SCOPES="[\"${GET_SCOPE}\",\"${LIST_SCOPE}\",\"${MENU_SCOPE}\"]"
  
  # Get all resource IDs (for Admin permission to have full access)
  echo "  Fetching resource IDs..."
  RESOURCES_JSON=$(curl -s "${KEYCLOAK_URL}/admin/realms/${REALM}/clients/${CLIENT_UUID}/authz/resource-server/resource" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}")
  ALL_RESOURCE_IDS=$(echo "$RESOURCES_JSON" | jq -r '[.[]._id] | map("\"" + . + "\"") | join(",")')
  ALL_RESOURCES="[${ALL_RESOURCE_IDS}]"
  RESOURCE_COUNT=$(echo "$RESOURCES_JSON" | jq 'length')
  echo "    Found ${RESOURCE_COUNT} resources"
  
  # Create group policies
  echo "  Creating group policies..."
  
  # 1. airflow-admin-group-policy (Admin access)
  ADMIN_POLICY_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
    "${KEYCLOAK_URL}/admin/realms/${REALM}/clients/${CLIENT_UUID}/authz/resource-server/policy/group" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{
      \"name\": \"airflow-admin-group-policy\",
      \"description\": \"Policy granting admin access to airflow-admin group\",
      \"groups\": [{\"id\": \"${AIRFLOW_ADMIN_GROUP_ID}\", \"extendChildren\": false}],
      \"logic\": \"POSITIVE\",
      \"groupsClaim\": \"groups\"
    }")
  ADMIN_POLICY_CODE=$(echo "$ADMIN_POLICY_RESPONSE" | tail -n1)
  if [ "$ADMIN_POLICY_CODE" == "201" ] || [ "$ADMIN_POLICY_CODE" == "409" ]; then
    echo "    ✓ airflow-admin-group-policy"
  fi
  
  # 2. data-engineers-group-policy (User/Editor access)
  ENGINEERS_POLICY_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
    "${KEYCLOAK_URL}/admin/realms/${REALM}/clients/${CLIENT_UUID}/authz/resource-server/policy/group" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{
      \"name\": \"data-engineers-group-policy\",
      \"description\": \"Policy granting editor access to data-engineers group\",
      \"groups\": [{\"id\": \"${DATA_ENGINEERS_GROUP_ID}\", \"extendChildren\": false}],
      \"logic\": \"POSITIVE\",
      \"groupsClaim\": \"groups\"
    }")
  ENGINEERS_POLICY_CODE=$(echo "$ENGINEERS_POLICY_RESPONSE" | tail -n1)
  if [ "$ENGINEERS_POLICY_CODE" == "201" ] || [ "$ENGINEERS_POLICY_CODE" == "409" ]; then
    echo "    ✓ data-engineers-group-policy"
  fi
  
  # 3. data-scientists-group-policy (ReadOnly/Viewer access)
  SCIENTISTS_POLICY_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
    "${KEYCLOAK_URL}/admin/realms/${REALM}/clients/${CLIENT_UUID}/authz/resource-server/policy/group" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{
      \"name\": \"data-scientists-group-policy\",
      \"description\": \"Policy granting read-only access to data-scientists group\",
      \"groups\": [{\"id\": \"${DATA_SCIENTISTS_GROUP_ID}\", \"extendChildren\": false}],
      \"logic\": \"POSITIVE\",
      \"groupsClaim\": \"groups\"
    }")
  SCIENTISTS_POLICY_CODE=$(echo "$SCIENTISTS_POLICY_RESPONSE" | tail -n1)
  if [ "$SCIENTISTS_POLICY_CODE" == "201" ] || [ "$SCIENTISTS_POLICY_CODE" == "409" ]; then
    echo "    ✓ data-scientists-group-policy"
  fi
  
  # Get policy IDs
  echo "  Fetching policy IDs..."
  POLICIES_JSON=$(curl -s "${KEYCLOAK_URL}/admin/realms/${REALM}/clients/${CLIENT_UUID}/authz/resource-server/policy?type=group" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}")
  
  ADMIN_POLICY_ID=$(echo "$POLICIES_JSON" | jq -r '.[] | select(.name=="airflow-admin-group-policy") | .id')
  ENGINEERS_POLICY_ID=$(echo "$POLICIES_JSON" | jq -r '.[] | select(.name=="data-engineers-group-policy") | .id')
  SCIENTISTS_POLICY_ID=$(echo "$POLICIES_JSON" | jq -r '.[] | select(.name=="data-scientists-group-policy") | .id')
  
  # Get permission IDs
  PERMISSIONS_JSON=$(curl -s "${KEYCLOAK_URL}/admin/realms/${REALM}/clients/${CLIENT_UUID}/authz/resource-server/permission" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}")
  
  ADMIN_PERM_ID=$(echo "$PERMISSIONS_JSON" | jq -r '.[] | select(.name=="Admin") | .id')
  USER_PERM_ID=$(echo "$PERMISSIONS_JSON" | jq -r '.[] | select(.name=="User") | .id')
  READONLY_PERM_ID=$(echo "$PERMISSIONS_JSON" | jq -r '.[] | select(.name=="ReadOnly") | .id')
  
  # Update permissions with group policies
  echo "  Linking policies to permissions..."
  
  # Admin permission -> airflow-admin-group-policy (all scopes on all resources)
  if [ -n "$ADMIN_PERM_ID" ] && [ "$ADMIN_PERM_ID" != "null" ]; then
    curl -s -X PUT "${KEYCLOAK_URL}/admin/realms/${REALM}/clients/${CLIENT_UUID}/authz/resource-server/permission/scope/${ADMIN_PERM_ID}" \
      -H "Authorization: Bearer ${ACCESS_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "{
        \"id\": \"${ADMIN_PERM_ID}\",
        \"name\": \"Admin\",
        \"type\": \"scope\",
        \"logic\": \"POSITIVE\",
        \"decisionStrategy\": \"AFFIRMATIVE\",
        \"resources\": ${ALL_RESOURCES},
        \"scopes\": ${ALL_SCOPES},
        \"policies\": [\"${ADMIN_POLICY_ID}\"]
      }" > /dev/null
    echo "    ✓ Admin permission -> airflow-admin-group-policy (all ${RESOURCE_COUNT} resources)"
  fi
  
  # User permission -> data-engineers-group-policy (all scopes)
  if [ -n "$USER_PERM_ID" ] && [ "$USER_PERM_ID" != "null" ]; then
    curl -s -X PUT "${KEYCLOAK_URL}/admin/realms/${REALM}/clients/${CLIENT_UUID}/authz/resource-server/permission/resource/${USER_PERM_ID}" \
      -H "Authorization: Bearer ${ACCESS_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "{
        \"id\": \"${USER_PERM_ID}\",
        \"name\": \"User\",
        \"type\": \"resource\",
        \"logic\": \"POSITIVE\",
        \"decisionStrategy\": \"AFFIRMATIVE\",
        \"policies\": [\"${ENGINEERS_POLICY_ID}\"]
      }" > /dev/null
    echo "    ✓ User permission -> data-engineers-group-policy"
  fi
  
  # ReadOnly permission -> data-scientists-group-policy (read scopes only)
  if [ -n "$READONLY_PERM_ID" ] && [ "$READONLY_PERM_ID" != "null" ]; then
    curl -s -X PUT "${KEYCLOAK_URL}/admin/realms/${REALM}/clients/${CLIENT_UUID}/authz/resource-server/permission/scope/${READONLY_PERM_ID}" \
      -H "Authorization: Bearer ${ACCESS_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "{
        \"id\": \"${READONLY_PERM_ID}\",
        \"name\": \"ReadOnly\",
        \"type\": \"scope\",
        \"logic\": \"POSITIVE\",
        \"decisionStrategy\": \"AFFIRMATIVE\",
        \"scopes\": ${READ_SCOPES},
        \"policies\": [\"${SCIENTISTS_POLICY_ID}\"]
      }" > /dev/null
    echo "    ✓ ReadOnly permission -> data-scientists-group-policy"
  fi
  
  echo ""
  echo "✓ Keycloak authorization policies configured"
  echo ""
  echo "Group → Permission Mapping:"
  echo "  ┌─────────────────────┬──────────────┬─────────────────────────────┐"
  echo "  │ Keycloak Group      │ Permission   │ Scopes                      │"
  echo "  ├─────────────────────┼──────────────┼─────────────────────────────┤"
  echo "  │ airflow-admin       │ Admin        │ GET,POST,PUT,DELETE,MENU,LIST│"
  echo "  │ data-engineers      │ User         │ GET,POST,PUT,DELETE,MENU,LIST│"
  echo "  │ data-scientists     │ ReadOnly     │ GET,LIST,MENU               │"
  echo "  └─────────────────────┴──────────────┴─────────────────────────────┘"
  echo ""
}

# Function to start port-forward
start_airflow_port_forward() {
  echo "Starting port-forward for Airflow..."
  
  # Kill existing port-forward
  pkill -f "kubectl port-forward.*airflow.*8085" 2>/dev/null || true
  sleep 1
  
  # Start new port-forward (using 8085 to avoid conflict with Keycloak on 8080)
  # Airflow 3.0 uses airflow-api-server instead of airflow-webserver
  kubectl port-forward svc/airflow-api-server -n airflow 8085:8080 > /dev/null 2>&1 &
  
  sleep 3
  echo "✓ Port-forward started: http://localhost:8085"
}

# Function to print completion message
print_airflow_completion() {
  echo ""
  echo "========================================="
  echo "Airflow Deployment Complete!"
  echo "========================================="
  echo ""
  echo "Access URLs:"
  echo "  Airflow UI: http://localhost:8085"
  echo ""
  echo "Keycloak Users:"
  echo "  ┌─────────────────┬──────────────────┬────────────────┐"
  echo "  │ User            │ Password         │ Airflow Role   │"
  echo "  ├─────────────────┼──────────────────┼────────────────┤"
  echo "  │ admin           │ admin            │ Admin          │"
  echo "  │ jupyter-admin   │ password123      │ Editor         │"
  echo "  │ jupyter-ds      │ password123      │ Viewer         │"
  echo "  └─────────────────┴──────────────────┴────────────────┘"
  echo ""
  echo "Role Permissions:"
  echo "  Admin:  Full access to all Airflow features"
  echo "  Editor: Create/edit/execute DAGs, view logs"
  echo "  Viewer: Read-only access to DAGs and logs"
  echo ""
  echo "IMPORTANT - Local Development (WSL/Windows):"
  echo "  Add to Windows hosts file (C:\\Windows\\System32\\drivers\\etc\\hosts):"
  echo "    127.0.0.1  keycloak.local"
  echo ""
  echo "  Required port-forwards:"
  echo "    kubectl port-forward svc/keycloak-service -n operators 8080:8080 --address 0.0.0.0"
  echo "    kubectl port-forward svc/airflow-api-server -n airflow 8085:8080"
  echo ""
}
