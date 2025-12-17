#!/bin/bash
# =============================================================================
# Common Utility Functions for Platform Deployment
# =============================================================================
# Shared functions used across all deployment scripts including logging,
# validation, Kubernetes helpers, and error handling.
# =============================================================================

# Source central configuration
SCRIPT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_LIB_DIR/../config.sh"

# =============================================================================
# LOGGING FUNCTIONS
# =============================================================================

# Color codes (disabled if not in terminal)
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m' # No Color
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    NC=''
fi

log_info() {
    echo -e "${BLUE}ℹ${NC}  $1"
}

log_success() {
    echo -e "${GREEN}✓${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}⚠${NC}  $1"
}

log_error() {
    echo -e "${RED}✗${NC} $1" >&2
}

log_debug() {
    if [ "$VERBOSE" = "true" ]; then
        echo -e "  [DEBUG] $1"
    fi
}

log_step() {
    local step=$1
    local total=$2
    local msg=$3
    echo ""
    echo -e "${BLUE}Step $step/$total:${NC} $msg"
}

log_header() {
    local title=$1
    echo ""
    echo "========================================="
    echo "$title"
    echo "========================================="
    echo ""
}

log_section() {
    local title=$1
    echo ""
    echo "-----------------------------------------"
    echo "$title"
    echo "-----------------------------------------"
}

# =============================================================================
# VALIDATION FUNCTIONS
# =============================================================================

# Check if a command exists
require_command() {
    local cmd=$1
    local install_hint=${2:-"Please install $cmd"}
    
    if ! command -v "$cmd" &> /dev/null; then
        log_error "Required command not found: $cmd"
        log_error "$install_hint"
        return 1
    fi
    log_debug "Found command: $cmd"
    return 0
}

# Validate all prerequisites for deployment
validate_prerequisites() {
    log_info "Validating prerequisites..."
    
    local failed=0
    
    require_command kubectl "Install: https://kubernetes.io/docs/tasks/tools/" || ((failed++))
    require_command helm "Install: https://helm.sh/docs/intro/install/" || ((failed++))
    require_command jq "Install: apt-get install jq / brew install jq" || ((failed++))
    require_command curl "Install: apt-get install curl / brew install curl" || ((failed++))
    
    if [ $failed -gt 0 ]; then
        log_error "$failed prerequisite(s) missing"
        return 1
    fi
    
    log_success "All prerequisites satisfied"
    return 0
}

# Verify cluster connection
verify_cluster_connection() {
    log_info "Verifying cluster connection..."
    
    if ! kubectl cluster-info &> /dev/null; then
        log_error "Cannot connect to Kubernetes cluster"
        log_error "Please configure kubectl for your cluster"
        return 1
    fi
    
    local context
    context=$(kubectl config current-context)
    log_success "Connected to cluster: $context"
    return 0
}

# =============================================================================
# KUBERNETES HELPER FUNCTIONS
# =============================================================================

# Create namespace if it doesn't exist
ensure_namespace() {
    local ns=$1
    kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - > /dev/null 2>&1
    log_debug "Namespace ensured: $ns"
}

# Create multiple namespaces
create_namespaces() {
    log_info "Creating namespaces..."
    ensure_namespace "$NS_OPERATORS"
    ensure_namespace "$NS_VAULT"
    log_success "Namespaces ready"
}

# Wait for a pod to be ready by label selector
wait_for_pod() {
    local label=$1
    local ns=$2
    local timeout=${3:-$TIMEOUT_MEDIUM}
    
    log_debug "Waiting for pod with label '$label' in namespace '$ns'"
    
    if ! kubectl wait --for=condition=ready pod -l "$label" -n "$ns" --timeout="${timeout}s" 2>/dev/null; then
        log_error "Timeout waiting for pod: $label in $ns"
        return 1
    fi
    return 0
}

# Wait for a specific pod by name to be created
wait_for_pod_created() {
    local pod_name=$1
    local ns=$2
    local max_attempts=${3:-30}
    
    for i in $(seq 1 "$max_attempts"); do
        if kubectl get pod "$pod_name" -n "$ns" > /dev/null 2>&1; then
            log_success "$pod_name pod created"
            return 0
        fi
        echo "Waiting for $pod_name... ($i/$max_attempts)"
        sleep 2
    done
    
    log_error "Timed out waiting for $pod_name to be created"
    return 1
}

# Wait for deployment to be available
wait_for_deployment() {
    local deployment=$1
    local ns=$2
    local timeout=${3:-$TIMEOUT_MEDIUM}
    
    log_debug "Waiting for deployment '$deployment' in namespace '$ns'"
    
    if ! kubectl wait --for=condition=available deployment/"$deployment" -n "$ns" --timeout="${timeout}s" 2>/dev/null; then
        log_error "Timeout waiting for deployment: $deployment in $ns"
        return 1
    fi
    return 0
}

# Wait for statefulset to be ready
wait_for_statefulset() {
    local statefulset=$1
    local ns=$2
    local timeout=${3:-$TIMEOUT_MEDIUM}
    
    log_debug "Waiting for statefulset '$statefulset' in namespace '$ns'"
    
    if ! kubectl rollout status statefulset/"$statefulset" -n "$ns" --timeout="${timeout}s" 2>/dev/null; then
        log_error "Timeout waiting for statefulset: $statefulset in $ns"
        return 1
    fi
    return 0
}

# Check if a pod is running
is_pod_running() {
    local pod_name=$1
    local ns=$2
    
    kubectl get pod "$pod_name" -n "$ns" 2>/dev/null | grep -q "Running"
}

# Check if a service exists
service_exists() {
    local service=$1
    local ns=$2
    
    kubectl get svc "$service" -n "$ns" > /dev/null 2>&1
}

# Get secret value (base64 decoded)
get_secret_value() {
    local secret_name=$1
    local ns=$2
    local key=$3
    
    kubectl get secret "$secret_name" -n "$ns" -o jsonpath="{.data.$key}" 2>/dev/null | base64 -d
}

# =============================================================================
# HELM HELPER FUNCTIONS
# =============================================================================

# Add helm repo if not exists
ensure_helm_repo() {
    local name=$1
    local url=$2
    
    if ! helm repo list 2>/dev/null | grep -q "^$name"; then
        helm repo add "$name" "$url" > /dev/null 2>&1
        log_debug "Added helm repo: $name"
    fi
    helm repo update "$name" > /dev/null 2>&1
}

# Check if helm release exists
helm_release_exists() {
    local release=$1
    local ns=$2
    
    helm status "$release" -n "$ns" > /dev/null 2>&1
}

# =============================================================================
# FILE HELPER FUNCTIONS
# =============================================================================

# Ensure config directory exists
ensure_config_dir() {
    mkdir -p "$CONFIG_DIR"
}

# Check if config file exists
config_file_exists() {
    local file=$1
    [ -f "$CONFIG_DIR/$file" ]
}

# =============================================================================
# MINIKUBE HELPER FUNCTIONS
# =============================================================================

# Start minikube with configured settings
start_minikube() {
    log_info "Starting Minikube (profile: $MINIKUBE_PROFILE)..."
    
    minikube start -p "$MINIKUBE_PROFILE" \
        --cpus "$MINIKUBE_CPUS" \
        --memory "$MINIKUBE_MEMORY" \
        --driver "$MINIKUBE_DRIVER"
    
    minikube addons enable ingress -p "$MINIKUBE_PROFILE"
    minikube profile "$MINIKUBE_PROFILE"
    
    log_success "Minikube started"
}

# =============================================================================
# ERROR HANDLING
# =============================================================================

# Trap handler for cleanup on error
cleanup_on_error() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        log_error "Script failed with exit code: $exit_code"
        log_error "Check the logs above for details"
    fi
}

# Enable error handling (call at script start)
enable_error_handling() {
    set -e
    trap cleanup_on_error EXIT
}
