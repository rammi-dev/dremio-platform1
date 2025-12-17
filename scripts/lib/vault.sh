#!/bin/bash
# =============================================================================
# Vault Deployment and Configuration Functions
# =============================================================================
# Functions for deploying HashiCorp Vault, initializing, unsealing, and
# configuring OIDC authentication with Keycloak.
# =============================================================================

# Source common utilities
SCRIPT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_LIB_DIR/common.sh"

# =============================================================================
# DEPLOYMENT FUNCTIONS
# =============================================================================

# Deploy Vault using Helm
deploy_vault() {
    log_info "Deploying Vault..."
    
    ensure_helm_repo "hashicorp" "$HELM_REPO_HASHICORP"
    
    if helm_release_exists "vault" "$NS_VAULT"; then
        log_warn "Vault release already exists"
        return 0
    fi
    
    helm install vault hashicorp/vault -n "$NS_VAULT" -f "$HELM_DIR/vault/values.yaml"
    
    log_info "Waiting for Vault pod to start..."
    sleep 10
    
    # Wait for pod to be running (not ready - it won't be ready until initialized)
    local max_attempts=30
    for i in $(seq 1 "$max_attempts"); do
        if kubectl get pod vault-0 -n "$NS_VAULT" 2>/dev/null | grep -q "Running"; then
            log_success "Vault pod running"
            return 0
        fi
        echo "Waiting for Vault pod... ($i/$max_attempts)"
        sleep 5
    done
    
    log_error "Timeout waiting for Vault pod"
    return 1
}

# =============================================================================
# INITIALIZATION FUNCTIONS
# =============================================================================

# Check if Vault is initialized
is_vault_initialized() {
    local status
    status=$(kubectl exec -n "$NS_VAULT" vault-0 -- vault status -format=json 2>/dev/null | jq -r '.initialized')
    [ "$status" == "true" ]
}

# Check if Vault is sealed
is_vault_sealed() {
    local status
    status=$(kubectl exec -n "$NS_VAULT" vault-0 -- vault status -format=json 2>/dev/null | jq -r '.sealed')
    [ "$status" == "true" ]
}

# Initialize Vault
initialize_vault() {
    log_info "Checking Vault initialization status..."
    sleep 5
    
    if is_vault_initialized; then
        log_info "Vault is already initialized"
        
        if [ ! -f "$VAULT_KEYS_FILE" ]; then
            log_warn "Vault is initialized but $VAULT_KEYS_FILE is missing!"
            log_warn "You will need the original keys to unseal."
        fi
        return 0
    fi
    
    log_info "Initializing Vault..."
    ensure_config_dir
    
    kubectl exec -n "$NS_VAULT" vault-0 -- vault operator init \
        -key-shares="$VAULT_KEY_SHARES" \
        -key-threshold="$VAULT_KEY_THRESHOLD" \
        -format=json > "$VAULT_KEYS_FILE"
    
    log_success "Vault initialized"
    log_info "Keys saved to: $VAULT_KEYS_FILE"
}

# Unseal Vault
unseal_vault() {
    log_info "Checking Vault seal status..."
    
    if ! is_vault_sealed; then
        log_info "Vault is already unsealed"
        return 0
    fi
    
    if [ ! -f "$VAULT_KEYS_FILE" ]; then
        log_error "Cannot unseal Vault: $VAULT_KEYS_FILE not found"
        return 1
    fi
    
    log_info "Unsealing Vault..."
    
    local unseal_key
    unseal_key=$(jq -r '.unseal_keys_b64[0]' "$VAULT_KEYS_FILE")
    
    kubectl exec -n "$NS_VAULT" vault-0 -- vault operator unseal "$unseal_key" > /dev/null
    
    log_success "Vault unsealed"
}

# Get Vault root token
get_vault_root_token() {
    if [ ! -f "$VAULT_KEYS_FILE" ]; then
        log_error "Vault keys file not found: $VAULT_KEYS_FILE"
        return 1
    fi
    
    jq -r '.root_token' "$VAULT_KEYS_FILE"
}

# Login to Vault with root token
vault_login() {
    local root_token
    root_token=$(get_vault_root_token) || return 1
    
    kubectl exec -n "$NS_VAULT" vault-0 -- vault login "$root_token" > /dev/null
    log_debug "Logged into Vault"
}

# =============================================================================
# OIDC CONFIGURATION
# =============================================================================

# Configure Vault OIDC authentication with Keycloak
configure_vault_oidc() {
    log_section "Configuring Vault OIDC Authentication"
    
    # Get client secret
    local client_secret
    if [ -f "$KEYCLOAK_CLIENT_SECRET_FILE" ]; then
        client_secret=$(cat "$KEYCLOAK_CLIENT_SECRET_FILE")
    else
        log_error "Keycloak client secret not found: $KEYCLOAK_CLIENT_SECRET_FILE"
        return 1
    fi
    
    # Login to Vault
    vault_login || return 1
    
    # Create admin policy
    log_info "Creating admin policy..."
    cat > /tmp/admin-policy.hcl <<'EOF'
path "*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}
EOF
    kubectl cp /tmp/admin-policy.hcl "$NS_VAULT/vault-0:/tmp/admin-policy.hcl"
    kubectl exec -n "$NS_VAULT" vault-0 -- vault policy write admin /tmp/admin-policy.hcl > /dev/null
    rm /tmp/admin-policy.hcl
    
    # Enable OIDC auth
    log_info "Enabling OIDC authentication..."
    kubectl exec -n "$NS_VAULT" vault-0 -- vault auth enable oidc > /dev/null 2>&1 || true
    
    # Configure OIDC with retry (Keycloak DNS might not be ready)
    log_info "Configuring OIDC settings..."
    local max_retries=10
    for i in $(seq 1 "$max_retries"); do
        if kubectl exec -n "$NS_VAULT" vault-0 -- vault write auth/oidc/config \
            oidc_discovery_url="http://keycloak-service.$NS_OPERATORS.svc.cluster.local:8080/realms/$KEYCLOAK_REALM" \
            oidc_client_id="$OIDC_CLIENT_VAULT" \
            oidc_client_secret="$client_secret" \
            default_role="admin" > /dev/null 2>&1; then
            log_success "OIDC config written"
            break
        fi
        echo "Waiting for Keycloak OIDC endpoint... ($i/$max_retries)"
        sleep 5
    done
    
    # Create OIDC role
    log_info "Creating OIDC role..."
    kubectl exec -n "$NS_VAULT" vault-0 -- vault write auth/oidc/role/admin \
        bound_audiences="$OIDC_CLIENT_VAULT" \
        allowed_redirect_uris="http://localhost:$PORT_VAULT/ui/vault/auth/oidc/oidc/callback" \
        allowed_redirect_uris="http://127.0.0.1:$PORT_VAULT/ui/vault/auth/oidc/oidc/callback" \
        allowed_redirect_uris="http://localhost:8250/oidc/callback" \
        user_claim="sub" \
        groups_claim="groups" \
        policies="admin" \
        ttl="1h" > /dev/null
    
    # Create group mapping
    log_info "Creating group mapping..."
    local oidc_accessor
    oidc_accessor=$(kubectl exec -n "$NS_VAULT" vault-0 -- vault auth list -format=json | jq -r '.["oidc/"].accessor')
    
    kubectl exec -n "$NS_VAULT" vault-0 -- vault write identity/group \
        name="vault-admins" \
        type="external" \
        policies="admin" > /dev/null
    
    local group_id
    group_id=$(kubectl exec -n "$NS_VAULT" vault-0 -- vault read -field=id identity/group/name/vault-admins)
    
    kubectl exec -n "$NS_VAULT" vault-0 -- vault write identity/group-alias \
        name="vault-admins" \
        mount_accessor="$oidc_accessor" \
        canonical_id="$group_id" > /dev/null
    
    log_success "Vault OIDC configured"
}

# =============================================================================
# SECRETS ENGINE CONFIGURATION
# =============================================================================

# Enable KV secrets engine
enable_kv_engine() {
    local path=${1:-"secret"}
    
    log_info "Enabling KV secrets engine at path: $path"
    
    vault_login || return 1
    
    kubectl exec -n "$NS_VAULT" vault-0 -- \
        vault secrets enable -path="$path" kv-v2 2>/dev/null || \
        log_debug "KV engine already enabled at $path"
    
    log_success "KV engine ready at: $path"
}

# Store a secret in Vault
store_secret() {
    local path=$1
    shift
    local kv_pairs="$@"
    
    vault_login || return 1
    
    kubectl exec -n "$NS_VAULT" vault-0 -- vault kv put "$path" $kv_pairs > /dev/null
    log_debug "Secret stored at: $path"
}

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

# Verify persistent storage
verify_vault_storage() {
    log_info "Verifying Vault persistent storage..."
    
    if kubectl get pvc -n "$NS_VAULT" | grep -q "vault"; then
        log_success "Vault PVC found"
        kubectl get pvc -n "$NS_VAULT" | grep vault
    else
        log_warn "No Vault PVC found"
    fi
}

# Print Vault access information
print_vault_credentials() {
    local root_token
    root_token=$(get_vault_root_token 2>/dev/null) || root_token="(not available)"
    
    echo ""
    echo "Vault UI: http://localhost:$PORT_VAULT"
    echo "  Root Token: $root_token"
    echo "  OIDC Login: Method=OIDC, Role=admin"
    echo "  Then login with: $KEYCLOAK_ADMIN_USER / $KEYCLOAK_ADMIN_PASS"
}
