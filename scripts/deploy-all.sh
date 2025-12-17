#!/bin/bash
# =============================================================================
# Main Deployment Orchestrator
# =============================================================================
# Master script to deploy all platform components in the correct order.
# Supports selective component deployment and multiple platforms.
#
# Usage:
#   ./deploy-all.sh                  # Deploy core only
#   ./deploy-all.sh all              # Deploy all components
#   ./deploy-all.sh core minio       # Deploy specific components
#   ./deploy-all.sh --list           # List available components
# =============================================================================

set -e

# Get script directory and source config
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"
source "$SCRIPT_DIR/lib/common.sh"

# =============================================================================
# AVAILABLE COMPONENTS
# =============================================================================

declare -A COMPONENTS=(
    ["core"]="Keycloak + Vault (core infrastructure)"
    ["minio"]="MinIO object storage with OIDC"
    ["jupyterhub"]="JupyterHub with Keycloak auth"
    ["dremio"]="Dremio Enterprise"
    ["spark"]="Spark Operator"
)

DEPLOYMENT_ORDER=("core" "minio" "jupyterhub" "dremio" "spark")

# =============================================================================
# FUNCTIONS
# =============================================================================

usage() {
    echo "Usage: $0 [OPTIONS] [COMPONENTS...]"
    echo ""
    echo "Deploy platform components in the correct order."
    echo ""
    echo "Components:"
    for comp in "${DEPLOYMENT_ORDER[@]}"; do
        printf "  %-12s %s\n" "$comp" "${COMPONENTS[$comp]}"
    done
    echo "  all          Deploy all components"
    echo ""
    echo "Options:"
    echo "  --platform <name>  Force platform (minikube, gke, eks, aks)"
    echo "  --list             List available components"
    echo "  --dry-run          Show what would be deployed"
    echo "  --skip-core        Skip core if already deployed"
    echo "  -h, --help         Show this help"
    echo ""
    echo "Examples:"
    echo "  $0                     # Deploy core infrastructure only"
    echo "  $0 all                 # Deploy everything"
    echo "  $0 core minio          # Deploy core and MinIO"
    echo "  $0 --skip-core minio   # Deploy MinIO (assumes core exists)"
}

list_components() {
    echo "Available Components:"
    echo ""
    for comp in "${DEPLOYMENT_ORDER[@]}"; do
        printf "  %-12s %s\n" "$comp" "${COMPONENTS[$comp]}"
    done
    echo ""
    echo "Deployment Order: ${DEPLOYMENT_ORDER[*]}"
}

deploy_component() {
    local component=$1
    
    case $component in
        core)
            log_header "Deploying Core Infrastructure"
            "$SCRIPT_DIR/deploy/deploy-core.sh" ${PLATFORM_ARG:-}
            ;;
        minio)
            log_header "Deploying MinIO"
            "$SCRIPT_DIR/deploy/deploy-minio.sh"
            ;;
        jupyterhub)
            log_header "Deploying JupyterHub"
            if [ -f "$SCRIPT_DIR/deploy/deploy-jupyterhub.sh" ]; then
                "$SCRIPT_DIR/deploy/deploy-jupyterhub.sh"
            else
                # Fallback to old script
                "$SCRIPT_DIR/deploy-jupyterhub-gke.sh"
            fi
            ;;
        dremio)
            log_header "Deploying Dremio"
            if [ -f "$SCRIPT_DIR/deploy/deploy-dremio.sh" ]; then
                "$SCRIPT_DIR/deploy/deploy-dremio.sh"
            else
                "$SCRIPT_DIR/start-dremio.sh"
            fi
            ;;
        spark)
            log_header "Deploying Spark Operator"
            if [ -f "$SCRIPT_DIR/deploy/deploy-spark.sh" ]; then
                "$SCRIPT_DIR/deploy/deploy-spark.sh"
            else
                "$SCRIPT_DIR/deploy-spark-operator.sh"
            fi
            ;;
        *)
            log_error "Unknown component: $component"
            return 1
            ;;
    esac
}

# =============================================================================
# ARGUMENT PARSING
# =============================================================================

SELECTED_COMPONENTS=()
DRY_RUN=false
SKIP_CORE=false
PLATFORM_ARG=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --platform)
            PLATFORM_ARG="--$2"
            shift 2
            ;;
        --list)
            list_components
            exit 0
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --skip-core)
            SKIP_CORE=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        all)
            SELECTED_COMPONENTS=("${DEPLOYMENT_ORDER[@]}")
            shift
            ;;
        *)
            if [[ -n "${COMPONENTS[$1]:-}" ]]; then
                SELECTED_COMPONENTS+=("$1")
            else
                log_error "Unknown option or component: $1"
                usage
                exit 1
            fi
            shift
            ;;
    esac
done

# Default to core only
if [ ${#SELECTED_COMPONENTS[@]} -eq 0 ]; then
    SELECTED_COMPONENTS=("core")
fi

# Remove core if --skip-core
if [ "$SKIP_CORE" = true ]; then
    SELECTED_COMPONENTS=("${SELECTED_COMPONENTS[@]/core}")
fi

# =============================================================================
# EXECUTION
# =============================================================================

log_header "Platform Deployment Orchestrator"
echo "Components to deploy: ${SELECTED_COMPONENTS[*]}"
echo ""

if [ "$DRY_RUN" = true ]; then
    echo "Dry-run mode - would deploy:"
    for comp in "${SELECTED_COMPONENTS[@]}"; do
        echo "  - $comp: ${COMPONENTS[$comp]}"
    done
    exit 0
fi

# Validate prerequisites
validate_prerequisites

# Deploy components in order
for comp in "${DEPLOYMENT_ORDER[@]}"; do
    # Check if this component is selected
    if [[ " ${SELECTED_COMPONENTS[*]} " =~ " ${comp} " ]]; then
        deploy_component "$comp"
        echo ""
    fi
done

# =============================================================================
# FINAL SUMMARY
# =============================================================================

log_header "Deployment Complete!"

echo "Deployed components:"
for comp in "${SELECTED_COMPONENTS[@]}"; do
    echo "  ✓ $comp"
done

echo ""
echo "To view access information:"
echo "  ./scripts/show-access-info.sh"
echo ""
echo "To start port-forwards:"
echo "  ./scripts/start-port-forwards.sh"
echo ""
