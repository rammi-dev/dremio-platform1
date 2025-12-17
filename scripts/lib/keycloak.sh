#!/bin/bash
# =============================================================================
# Keycloak Deployment and Configuration Functions
# =============================================================================
# Functions for deploying Keycloak operator, instances, and configuring
# realms, clients, users, and groups via the Keycloak Admin API.
# =============================================================================

# Source common utilities
SCRIPT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_LIB_DIR/common.sh"

# =============================================================================
# DEPLOYMENT FUNCTIONS
# =============================================================================

# Deploy Keycloak CRDs and Operator
deploy_keycloak_operator() {
    log_info "Deploying Keycloak CRDs and Operator..."
    
    kubectl apply -f "$HELM_DIR/keycloak/manifests/keycloak-crd.yml"
    kubectl apply -f "$HELM_DIR/keycloak/manifests/keycloak-realm-crd.yml"
    kubectl apply -f "$HELM_DIR/keycloak/manifests/keycloak-operator.yml"
    
    log_info "Waiting for Keycloak operator..."
    wait_for_pod "app.kubernetes.io/name=keycloak-operator" "$NS_OPERATORS" "$TIMEOUT_SHORT"
    log_success "Keycloak operator ready"
}

# Deploy PostgreSQL for Keycloak
deploy_postgres() {
    log_info "Deploying PostgreSQL with persistent storage..."
    
    kubectl apply -f "$HELM_DIR/postgres/postgres-for-keycloak.yaml"
    
    log_info "Waiting for PostgreSQL..."
    wait_for_pod "app=postgres" "$NS_OPERATORS" "$TIMEOUT_SHORT"
    log_success "PostgreSQL ready (2Gi persistent storage)"
}

# Deploy Keycloak instance
deploy_keycloak_instance() {
    log_info "Deploying Keycloak instance..."
    
    kubectl apply -f "$HELM_DIR/keycloak/manifests/keycloak-instance.yaml"
    
    wait_for_pod_created "keycloak-0" "$NS_OPERATORS" 30
    
    log_info "Waiting for Keycloak to be ready (this takes 2-3 minutes)..."
    kubectl wait --for=condition=ready pod/keycloak-0 -n "$NS_OPERATORS" --timeout="${TIMEOUT_MEDIUM}s"
    log_success "Keycloak ready"
}

# =============================================================================
# CREDENTIAL FUNCTIONS
# =============================================================================

# Get Keycloak master realm admin credentials
get_keycloak_credentials() {
    export KEYCLOAK_MASTER_USER
    export KEYCLOAK_MASTER_PASS
    
    KEYCLOAK_MASTER_USER=$(get_secret_value "keycloak-initial-admin" "$NS_OPERATORS" "username")
    KEYCLOAK_MASTER_PASS=$(get_secret_value "keycloak-initial-admin" "$NS_OPERATORS" "password")
    
    if [ -z "$KEYCLOAK_MASTER_USER" ] || [ -z "$KEYCLOAK_MASTER_PASS" ]; then
        log_error "Failed to retrieve Keycloak credentials"
        return 1
    fi
    
    log_debug "Retrieved Keycloak master credentials"
}

# Get Keycloak admin access token
get_keycloak_token() {
    local max_retries=${1:-5}
    local retry_delay=${2:-3}
    
    get_keycloak_credentials || return 1
    
    for i in $(seq 1 "$max_retries"); do
        local token_response
        token_response=$(curl -s -X POST "http://localhost:$PORT_KEYCLOAK/realms/master/protocol/openid-connect/token" \
            -H "Content-Type: application/x-www-form-urlencoded" \
            -d "username=$KEYCLOAK_MASTER_USER" \
            -d "password=$KEYCLOAK_MASTER_PASS" \
            -d "grant_type=password" \
            -d "client_id=admin-cli" 2>/dev/null)
        
        export ACCESS_TOKEN
        ACCESS_TOKEN=$(echo "$token_response" | jq -r '.access_token')
        
        if [ "$ACCESS_TOKEN" != "null" ] && [ -n "$ACCESS_TOKEN" ]; then
            log_debug "Obtained Keycloak access token"
            return 0
        fi
        
        log_debug "Token request failed, retrying... ($i/$max_retries)"
        sleep "$retry_delay"
    done
    
    log_error "Failed to authenticate with Keycloak after $max_retries attempts"
    return 1
}

# =============================================================================
# REALM CONFIGURATION (via API)
# =============================================================================

# Create a realm
create_realm() {
    local realm_name=$1
    local display_name=${2:-$realm_name}
    
    log_info "Creating realm: $realm_name"
    
    curl -s -X POST "http://localhost:$PORT_KEYCLOAK/admin/realms" \
        -H "Authorization: Bearer $ACCESS_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"realm\": \"$realm_name\", \"enabled\": true, \"displayName\": \"$display_name\"}" > /dev/null
    
    log_success "Created realm: $realm_name"
}

# Create an OIDC client
create_oidc_client() {
    local realm=$1
    local client_id=$2
    local client_name=$3
    local redirect_uris=$4  # JSON array string
    
    log_info "Creating OIDC client: $client_id"
    
    local client_config
    client_config=$(cat <<EOF
{
    "clientId": "$client_id",
    "name": "$client_name",
    "enabled": true,
    "protocol": "openid-connect",
    "publicClient": false,
    "directAccessGrantsEnabled": true,
    "standardFlowEnabled": true,
    "redirectUris": $redirect_uris,
    "webOrigins": ["+"]
}
EOF
)
    
    curl -s -X POST "http://localhost:$PORT_KEYCLOAK/admin/realms/$realm/clients" \
        -H "Authorization: Bearer $ACCESS_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$client_config" > /dev/null
    
    log_success "Created OIDC client: $client_id"
}

# Get client UUID by client ID
get_client_uuid() {
    local realm=$1
    local client_id=$2
    
    curl -s -X GET "http://localhost:$PORT_KEYCLOAK/admin/realms/$realm/clients?clientId=$client_id" \
        -H "Authorization: Bearer $ACCESS_TOKEN" | jq -r '.[0].id'
}

# Get client secret
get_client_secret() {
    local realm=$1
    local client_uuid=$2
    
    curl -s -X GET "http://localhost:$PORT_KEYCLOAK/admin/realms/$realm/clients/$client_uuid/client-secret" \
        -H "Authorization: Bearer $ACCESS_TOKEN" | jq -r '.value'
}

# =============================================================================
# USER AND GROUP MANAGEMENT
# =============================================================================

# Create a group
create_group() {
    local realm=$1
    local group_name=$2
    
    log_info "Creating group: $group_name"
    
    curl -s -X POST "http://localhost:$PORT_KEYCLOAK/admin/realms/$realm/groups" \
        -H "Authorization: Bearer $ACCESS_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"name\": \"$group_name\"}" > /dev/null
    
    log_success "Created group: $group_name"
}

# Get group ID by name
get_group_id() {
    local realm=$1
    local group_name=$2
    
    curl -s -X GET "http://localhost:$PORT_KEYCLOAK/admin/realms/$realm/groups?search=$group_name" \
        -H "Authorization: Bearer $ACCESS_TOKEN" | jq -r '.[0].id'
}

# Create a user
create_user() {
    local realm=$1
    local username=$2
    local email=$3
    local password=$4
    
    log_info "Creating user: $username"
    
    # Create user
    curl -s -X POST "http://localhost:$PORT_KEYCLOAK/admin/realms/$realm/users" \
        -H "Authorization: Bearer $ACCESS_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"username\": \"$username\", \"email\": \"$email\", \"enabled\": true, \"emailVerified\": true}" > /dev/null
    
    # Get user ID
    local user_id
    user_id=$(curl -s -X GET "http://localhost:$PORT_KEYCLOAK/admin/realms/$realm/users?username=$username" \
        -H "Authorization: Bearer $ACCESS_TOKEN" | jq -r '.[0].id')
    
    # Set password
    curl -s -X PUT "http://localhost:$PORT_KEYCLOAK/admin/realms/$realm/users/$user_id/reset-password" \
        -H "Authorization: Bearer $ACCESS_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"type\": \"password\", \"value\": \"$password\", \"temporary\": false}" > /dev/null
    
    echo "$user_id"
    log_success "Created user: $username"
}

# Get user ID by username
get_user_id() {
    local realm=$1
    local username=$2
    
    curl -s -X GET "http://localhost:$PORT_KEYCLOAK/admin/realms/$realm/users?username=$username" \
        -H "Authorization: Bearer $ACCESS_TOKEN" | jq -r '.[0].id'
}

# Add user to group
add_user_to_group() {
    local realm=$1
    local user_id=$2
    local group_id=$3
    
    curl -s -X PUT "http://localhost:$PORT_KEYCLOAK/admin/realms/$realm/users/$user_id/groups/$group_id" \
        -H "Authorization: Bearer $ACCESS_TOKEN" > /dev/null
    
    log_debug "Added user to group"
}

# =============================================================================
# PROTOCOL MAPPERS
# =============================================================================

# Add groups mapper to client
add_groups_mapper() {
    local realm=$1
    local client_uuid=$2
    local mapper_name=${3:-"groups"}
    
    log_info "Adding groups mapper to client..."
    
    local mapper_config
    mapper_config=$(cat <<EOF
{
    "name": "$mapper_name",
    "protocol": "openid-connect",
    "protocolMapper": "oidc-group-membership-mapper",
    "config": {
        "full.path": "false",
        "id.token.claim": "true",
        "access.token.claim": "true",
        "claim.name": "groups",
        "userinfo.token.claim": "true"
    }
}
EOF
)
    
    curl -s -X POST "http://localhost:$PORT_KEYCLOAK/admin/realms/$realm/clients/$client_uuid/protocol-mappers/models" \
        -H "Authorization: Bearer $ACCESS_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$mapper_config" > /dev/null 2>&1 || true
    
    log_success "Groups mapper configured"
}

# =============================================================================
# HIGH-LEVEL CONFIGURATION FUNCTIONS
# =============================================================================

# Configure the vault realm with all components
configure_vault_realm() {
    log_section "Configuring Keycloak Vault Realm"
    
    get_keycloak_token || return 1
    
    # Create realm
    create_realm "$KEYCLOAK_REALM" "Vault"
    
    # Create Vault OIDC client
    local vault_redirect_uris='["http://localhost:8200/ui/vault/auth/oidc/oidc/callback", "http://127.0.0.1:8200/ui/vault/auth/oidc/oidc/callback", "http://localhost:8250/oidc/callback"]'
    create_oidc_client "$KEYCLOAK_REALM" "$OIDC_CLIENT_VAULT" "HashiCorp Vault" "$vault_redirect_uris"
    
    # Get and save client secret
    local client_uuid
    client_uuid=$(get_client_uuid "$KEYCLOAK_REALM" "$OIDC_CLIENT_VAULT")
    
    local client_secret
    client_secret=$(get_client_secret "$KEYCLOAK_REALM" "$client_uuid")
    
    ensure_config_dir
    echo "$client_secret" > "$KEYCLOAK_CLIENT_SECRET_FILE"
    
    # Create groups
    create_group "$KEYCLOAK_REALM" "vault-admins"
    create_group "$KEYCLOAK_REALM" "data-science"
    
    # Create admin user
    local user_id
    user_id=$(create_user "$KEYCLOAK_REALM" "$KEYCLOAK_ADMIN_USER" "admin@vault.local" "$KEYCLOAK_ADMIN_PASS")
    
    # Add user to vault-admins group
    local group_id
    group_id=$(get_group_id "$KEYCLOAK_REALM" "vault-admins")
    add_user_to_group "$KEYCLOAK_REALM" "$user_id" "$group_id"
    
    # Add groups mapper
    add_groups_mapper "$KEYCLOAK_REALM" "$client_uuid"
    
    log_success "Keycloak vault realm configured"
    log_info "  - Realm: $KEYCLOAK_REALM"
    log_info "  - OIDC Client: $OIDC_CLIENT_VAULT"
    log_info "  - Client Secret saved to: $KEYCLOAK_CLIENT_SECRET_FILE"
    log_info "  - Groups: vault-admins, data-science"
    log_info "  - User: $KEYCLOAK_ADMIN_USER / $KEYCLOAK_ADMIN_PASS"
}

# Configure MinIO OIDC client
configure_minio_client() {
    log_section "Configuring MinIO OIDC Client"
    
    get_keycloak_token || return 1
    
    # Check if client exists
    local existing_client
    existing_client=$(get_client_uuid "$KEYCLOAK_REALM" "$OIDC_CLIENT_MINIO")
    
    if [ "$existing_client" == "null" ] || [ -z "$existing_client" ]; then
        local minio_redirect_uris='["https://localhost:9091/*", "http://localhost:9091/*"]'
        create_oidc_client "$KEYCLOAK_REALM" "$OIDC_CLIENT_MINIO" "MinIO Console" "$minio_redirect_uris"
    else
        log_info "MinIO client already exists, updating..."
    fi
    
    # Get client UUID and secret
    export MINIO_CLIENT_UUID
    export MINIO_CLIENT_SECRET
    
    MINIO_CLIENT_UUID=$(get_client_uuid "$KEYCLOAK_REALM" "$OIDC_CLIENT_MINIO")
    MINIO_CLIENT_SECRET=$(get_client_secret "$KEYCLOAK_REALM" "$MINIO_CLIENT_UUID")
    
    # Add groups mapper
    add_groups_mapper "$KEYCLOAK_REALM" "$MINIO_CLIENT_UUID" "groups-mapper"
    
    # Create minio-access group
    create_group "$KEYCLOAK_REALM" "minio-access"
    
    # Add admin to minio-access group
    local admin_id
    admin_id=$(get_user_id "$KEYCLOAK_REALM" "$KEYCLOAK_ADMIN_USER")
    local minio_group_id
    minio_group_id=$(get_group_id "$KEYCLOAK_REALM" "minio-access")
    add_user_to_group "$KEYCLOAK_REALM" "$admin_id" "$minio_group_id"
    
    log_success "MinIO OIDC client configured"
}

# Print Keycloak credentials summary
print_keycloak_credentials() {
    get_keycloak_credentials
    
    echo ""
    echo "Keycloak Master Realm Credentials:"
    echo "  Username: $KEYCLOAK_MASTER_USER"
    echo "  Password: $KEYCLOAK_MASTER_PASS"
    echo ""
    echo "Keycloak Vault Realm Credentials:"
    echo "  Username: $KEYCLOAK_ADMIN_USER"
    echo "  Password: $KEYCLOAK_ADMIN_PASS"
}
