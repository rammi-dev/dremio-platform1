#!/bin/bash
# Common functions for Airflow deployment

# Function to authenticate with Keycloak
authenticate_keycloak() {
  echo "Authenticating with Keycloak..."
  
  KEYCLOAK_URL="http://localhost:8080"
  
  # Get admin token
  ACCESS_TOKEN=$(curl -s -X POST "${KEYCLOAK_URL}/realms/master/protocol/openid-connect/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "client_id=admin-cli" \
    -d "username=admin" \
    -d "password=admin" \
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
  
  local GROUPS=("airflow-admin" "data-engineers" "data-scientists")
  
  for GROUP in "${GROUPS[@]}"; do
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
  
  # Deploy Airflow
  if helm status airflow -n airflow > /dev/null 2>&1; then
    echo "Upgrading existing Airflow deployment..."
    helm upgrade airflow apache-airflow/airflow \
      -n airflow \
      -f helm/airflow/values.yaml \
      --set keycloakClientSecret="${CLIENT_SECRET}" \
      --timeout 10m
  else
    echo "Installing Airflow..."
    helm install airflow apache-airflow/airflow \
      -n airflow \
      -f helm/airflow/values.yaml \
      --set keycloakClientSecret="${CLIENT_SECRET}" \
      --timeout 10m
  fi
  
  echo "✓ Airflow deployment initiated"
}

# Function to wait for Airflow to be ready
wait_for_airflow_ready() {
  echo "Waiting for Airflow to be ready..."
  
  # Wait for webserver
  echo "  Waiting for webserver..."
  kubectl wait --for=condition=available deployment/airflow-webserver \
    -n airflow --timeout=300s 2>/dev/null || true
  
  # Wait for scheduler
  echo "  Waiting for scheduler..."
  kubectl wait --for=condition=available deployment/airflow-scheduler \
    -n airflow --timeout=300s 2>/dev/null || true
  
  # Check pod status
  echo "  Checking pod status..."
  kubectl get pods -n airflow
  
  echo "✓ Airflow is ready"
}

# Function to initialize Keycloak permissions
initialize_airflow_permissions() {
  echo ""
  echo "========================================="
  echo "Airflow Keycloak Permissions Setup"
  echo "========================================="
  echo ""
  echo "After Airflow is running, execute the following command to"
  echo "initialize Keycloak permissions for Airflow:"
  echo ""
  echo "  kubectl exec -it deploy/airflow-webserver -n airflow -- \\"
  echo "    airflow keycloak-auth-manager create-all \\"
  echo "      --username admin \\"
  echo "      --password admin \\"
  echo "      --user-realm vault"
  echo ""
  echo "This will create the necessary scopes, resources, and permissions"
  echo "in Keycloak for Airflow RBAC."
  echo ""
}

# Function to start port-forward
start_airflow_port_forward() {
  echo "Starting port-forward for Airflow..."
  
  # Kill existing port-forward
  pkill -f "kubectl port-forward.*airflow.*8085" 2>/dev/null || true
  sleep 1
  
  # Start new port-forward (using 8085 to avoid conflict with Keycloak on 8080)
  kubectl port-forward svc/airflow-webserver -n airflow 8085:8080 > /dev/null 2>&1 &
  
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
  echo "Default Credentials (before Keycloak setup):"
  echo "  Username: admin"
  echo "  Password: admin"
  echo ""
  echo "Keycloak Users (after permissions setup):"
  echo "  ┌─────────────────┬──────────────────┬────────────────┐"
  echo "  │ User            │ Group            │ Airflow Role   │"
  echo "  ├─────────────────┼──────────────────┼────────────────┤"
  echo "  │ admin           │ airflow-admin    │ Admin          │"
  echo "  │ jupyter-admin   │ data-engineers   │ Editor         │"
  echo "  │ jupyter-ds      │ data-scientists  │ Viewer         │"
  echo "  └─────────────────┴──────────────────┴────────────────┘"
  echo ""
  echo "Role Permissions:"
  echo "  Admin:  Full access to all Airflow features"
  echo "  Editor: Create/edit/execute DAGs, view logs"
  echo "  Viewer: Read-only access to DAGs and logs"
  echo ""
  echo "Next Steps:"
  echo "  1. Access Airflow UI at http://localhost:8085"
  echo "  2. Run permissions setup (see command above)"
  echo "  3. Login with Keycloak credentials"
  echo ""
}
