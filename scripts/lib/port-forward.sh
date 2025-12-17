#!/bin/bash
# =============================================================================
# Port-Forward Management Functions
# =============================================================================
# Unified functions for managing kubectl port-forwards across all services.
# Provides start, stop, and status checking functionality.
# =============================================================================

# Source common utilities
SCRIPT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_LIB_DIR/common.sh"

# =============================================================================
# CORE PORT-FORWARD FUNCTIONS
# =============================================================================

# Start a single port-forward
# Usage: start_port_forward <namespace> <service> <local_port> <remote_port> <name>
start_port_forward() {
    local ns=$1
    local service=$2
    local local_port=$3
    local remote_port=$4
    local name=$5
    
    # Kill existing port-forward for this service
    pkill -f "kubectl port-forward -n $ns svc/$service $local_port" 2>/dev/null || true
    sleep 1
    
    # Start new port-forward
    nohup kubectl port-forward -n "$ns" "svc/$service" "$local_port:$remote_port" --address=0.0.0.0 > /dev/null 2>&1 &
    local pid=$!
    sleep 2
    
    # Verify it started
    if ps -p "$pid" > /dev/null 2>&1; then
        log_success "$name port-forward started (localhost:$local_port -> $service:$remote_port)"
        return 0
    else
        log_warn "Failed to start $name port-forward"
        return 1
    fi
}

# Stop all port-forwards
stop_all_port_forwards() {
    log_info "Stopping all port-forwards..."
    pkill -f "kubectl port-forward" 2>/dev/null || true
    sleep 1
    log_success "All port-forwards stopped"
}

# Check if a port is accessible
is_port_accessible() {
    local port=$1
    local timeout=${2:-2}
    
    if command -v nc &> /dev/null; then
        nc -z localhost "$port" -w "$timeout" 2>/dev/null
    else
        curl -s -o /dev/null -w "%{http_code}" --connect-timeout "$timeout" "http://localhost:$port" 2>/dev/null | grep -q "200\|302\|401\|403"
    fi
}

# =============================================================================
# SERVICE-SPECIFIC PORT-FORWARDS
# =============================================================================

# Start Keycloak port-forward
start_keycloak_port_forward() {
    start_port_forward "$NS_OPERATORS" "keycloak-service" "$PORT_KEYCLOAK" 8080 "Keycloak"
}

# Start Vault port-forward
start_vault_port_forward() {
    start_port_forward "$NS_VAULT" "vault-ui" "$PORT_VAULT" 8200 "Vault"
}

# Start MinIO Console port-forward
start_minio_console_port_forward() {
    start_port_forward "$NS_MINIO" "minio-console" "$PORT_MINIO_CONSOLE" 9443 "MinIO Console"
}

# Start MinIO API port-forward
start_minio_api_port_forward() {
    start_port_forward "$NS_MINIO" "minio" "$PORT_MINIO_API" 443 "MinIO API"
}

# Start JupyterHub port-forward
start_jupyterhub_port_forward() {
    start_port_forward "$NS_JUPYTERHUB" "proxy-public" "$PORT_JUPYTERHUB" 80 "JupyterHub"
}

# Start Dremio port-forward
start_dremio_port_forward() {
    start_port_forward "$NS_DREMIO" "dremio-client" "$PORT_DREMIO" 9047 "Dremio"
}

# =============================================================================
# GROUPED PORT-FORWARDS
# =============================================================================

# Start core infrastructure port-forwards (Keycloak + Vault)
start_core_port_forwards() {
    log_info "Starting core port-forwards..."
    start_keycloak_port_forward
    start_vault_port_forward
}

# Start MinIO port-forwards (Console + API)
start_minio_port_forwards() {
    log_info "Starting MinIO port-forwards..."
    start_minio_console_port_forward
    start_minio_api_port_forward
}

# Start all port-forwards
start_all_port_forwards() {
    log_info "Starting all port-forwards..."
    
    # Core
    start_keycloak_port_forward
    start_vault_port_forward
    
    # MinIO (if deployed)
    if service_exists "minio-console" "$NS_MINIO"; then
        start_minio_console_port_forward
        start_minio_api_port_forward
    fi
    
    # JupyterHub (if deployed)
    if service_exists "proxy-public" "$NS_JUPYTERHUB"; then
        start_jupyterhub_port_forward
    fi
    
    # Dremio (if deployed)
    if service_exists "dremio-client" "$NS_DREMIO"; then
        start_dremio_port_forward
    fi
}

# =============================================================================
# ENSURE FUNCTIONS (start if not running)
# =============================================================================

# Ensure Keycloak port-forward is active
ensure_keycloak_port_forward() {
    # Check if already accessible
    if is_port_accessible "$PORT_KEYCLOAK"; then
        log_debug "Keycloak port-forward already active"
        return 0
    fi
    
    # Check if port-forward process exists
    if pgrep -f "kubectl port-forward.*keycloak-service.*$PORT_KEYCLOAK" > /dev/null 2>&1; then
        log_debug "Keycloak port-forward process exists, waiting..."
        sleep 3
        if is_port_accessible "$PORT_KEYCLOAK"; then
            return 0
        fi
    fi
    
    # Start port-forward
    log_info "Starting Keycloak port-forward..."
    start_keycloak_port_forward
}

# Ensure Vault port-forward is active
ensure_vault_port_forward() {
    if is_port_accessible "$PORT_VAULT"; then
        log_debug "Vault port-forward already active"
        return 0
    fi
    
    log_info "Starting Vault port-forward..."
    start_vault_port_forward
}

# Ensure MinIO port-forwards are active
ensure_minio_port_forwards() {
    local need_start=false
    
    if ! is_port_accessible "$PORT_MINIO_CONSOLE"; then
        need_start=true
    fi
    
    if [ "$need_start" = true ]; then
        start_minio_port_forwards
    else
        log_debug "MinIO port-forwards already active"
    fi
}

# =============================================================================
# STATUS FUNCTIONS
# =============================================================================

# List running port-forwards
list_port_forwards() {
    log_info "Running port-forwards:"
    ps aux | grep "[k]ubectl port-forward" | awk '{print "  " $0}'
}

# Print port-forward status
print_port_forward_status() {
    echo ""
    echo "Port-Forward Status:"
    echo "-------------------------------------------"
    
    if is_port_accessible "$PORT_KEYCLOAK"; then
        echo "  ✓ Keycloak:     http://localhost:$PORT_KEYCLOAK"
    else
        echo "  ✗ Keycloak:     not accessible"
    fi
    
    if is_port_accessible "$PORT_VAULT"; then
        echo "  ✓ Vault:        http://localhost:$PORT_VAULT"
    else
        echo "  ✗ Vault:        not accessible"
    fi
    
    if service_exists "minio-console" "$NS_MINIO" 2>/dev/null; then
        if is_port_accessible "$PORT_MINIO_CONSOLE"; then
            echo "  ✓ MinIO:        https://localhost:$PORT_MINIO_CONSOLE"
        else
            echo "  ✗ MinIO:        not accessible"
        fi
    fi
    
    if service_exists "proxy-public" "$NS_JUPYTERHUB" 2>/dev/null; then
        if is_port_accessible "$PORT_JUPYTERHUB"; then
            echo "  ✓ JupyterHub:   http://localhost:$PORT_JUPYTERHUB"
        else
            echo "  ✗ JupyterHub:   not accessible"
        fi
    fi
    
    if service_exists "dremio-client" "$NS_DREMIO" 2>/dev/null; then
        if is_port_accessible "$PORT_DREMIO"; then
            echo "  ✓ Dremio:       http://localhost:$PORT_DREMIO"
        else
            echo "  ✗ Dremio:       not accessible"
        fi
    fi
    
    echo ""
}

# =============================================================================
# CLEANUP
# =============================================================================

# Kill port-forward for specific service
kill_port_forward() {
    local service=$1
    pkill -f "kubectl port-forward.*$service" 2>/dev/null || true
}
