#!/bin/bash
# Deploy Apache Airflow on GKE with Keycloak authentication
# Uses LocalExecutor with PostgreSQL for standalone testing

set -e

# Get the directory where this script is located and change to project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

# Source common functions
source scripts/lib/airflow-common.sh

echo "========================================="
echo "Apache Airflow Deployment (Add-on) - GKE"
echo "========================================="
echo ""

# Check for --clean flag
CLEAN_INSTALL=false
if [[ "$1" == "--clean" ]]; then
  CLEAN_INSTALL=true
  echo "Clean install requested - will delete existing namespace and PVCs"
  echo ""
fi

# Step 0: Clean existing installation if requested
if [[ "$CLEAN_INSTALL" == "true" ]]; then
  echo "Step 0: Cleaning existing Airflow installation..."
  
  # Kill existing port-forwards
  pkill -f "kubectl port-forward.*airflow.*8085" 2>/dev/null || true
  
  # Delete helm release
  if helm status airflow -n airflow &>/dev/null; then
    echo "  Deleting Helm release..."
    helm uninstall airflow -n airflow --wait 2>/dev/null || true
  fi
  
  # Delete all resources in namespace
  if kubectl get namespace airflow &>/dev/null; then
    echo "  Deleting all resources in airflow namespace..."
    kubectl delete all --all -n airflow --timeout=60s 2>/dev/null || true
    kubectl delete pvc --all -n airflow --timeout=60s 2>/dev/null || true
    kubectl delete secrets --all -n airflow --timeout=60s 2>/dev/null || true
    kubectl delete configmaps --all -n airflow --timeout=60s 2>/dev/null || true
    
    echo "  Deleting namespace..."
    kubectl delete namespace airflow --timeout=120s 2>/dev/null || true
    
    # Wait for namespace deletion
    echo "  Waiting for namespace deletion..."
    for i in {1..30}; do
      if ! kubectl get namespace airflow &>/dev/null; then
        break
      fi
      sleep 2
    done
  fi
  
  # Delete Keycloak client to start fresh
  echo "  Deleting Airflow Keycloak client..."
  delete_airflow_keycloak_client 2>/dev/null || true
  
  echo "✓ Clean up complete"
  echo ""
fi

# Step 1: Verify prerequisites
echo "Step 1: Verifying prerequisites..."

# Check GKE connection
if ! kubectl cluster-info &> /dev/null; then
  echo "ERROR: Cannot connect to Kubernetes cluster. Please verify kubectl is configured for GKE."
  exit 1
fi
echo "✓ GKE cluster connected"

# Check if Keycloak is running
if ! kubectl get pod keycloak-0 -n operators 2>/dev/null | grep -q "Running"; then
  echo "ERROR: Keycloak is not running. Please run ./scripts/deploy-gke.sh first."
  exit 1
fi
echo "✓ Keycloak is running"

# Check if port-forward to Keycloak is active
if ! curl -s http://localhost:8080/realms/master > /dev/null 2>&1; then
  echo "WARNING: Keycloak port-forward not active. Starting it..."
  kubectl port-forward svc/keycloak-service -n operators 8080:8080 > /dev/null 2>&1 &
  sleep 3
fi
echo "✓ Keycloak accessible at localhost:8080"

# Ensure Keycloak hostname is set to 'keycloak' for proper logout redirects
echo "  Configuring Keycloak hostname..."
kubectl patch keycloak keycloak -n operators --type='merge' -p '{"spec":{"hostname":{"hostname":"keycloak","strict":false,"strictBackchannel":false}}}' 2>/dev/null || true
echo ""

# Step 2: Configure Keycloak
echo "Step 2: Configuring Keycloak for Airflow..."
authenticate_keycloak
configure_airflow_keycloak_client "$ACCESS_TOKEN"
configure_airflow_groups "$ACCESS_TOKEN"
assign_airflow_groups_to_users "$ACCESS_TOKEN"
echo ""

# Step 3: Deploy Airflow
echo "Step 3: Deploying Airflow..."
deploy_airflow "$AIRFLOW_CLIENT_SECRET"
echo ""

# Step 4: Create MinIO bucket for logs
echo "Step 4: Creating MinIO bucket for Airflow logs..."
create_airflow_logs_bucket
echo ""

# Step 5: Wait for Airflow to be ready
echo "Step 5: Waiting for Airflow to be ready..."
wait_for_airflow_ready
echo ""

# Step 6: Initialize Keycloak authorization (scopes, resources, permissions)
echo "Step 6: Initializing Keycloak authorization..."
initialize_airflow_permissions
echo ""

# Step 7: Configure authorization policies (link groups to permissions)
echo "Step 7: Configuring authorization policies..."
configure_airflow_authorization_policies
echo ""

# Step 8: Clear existing Keycloak SSO sessions (prevents auto-login issues)
echo "Step 8: Clearing Keycloak SSO sessions..."
clear_keycloak_sessions "$ACCESS_TOKEN"

# Step 9: Start port-forward
echo "Step 9: Starting port-forward..."
start_airflow_port_forward

# Print completion message
print_airflow_completion
