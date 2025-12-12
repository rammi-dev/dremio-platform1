#!/bin/bash
set -e

# Get directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "========================================="
echo "Spark Operator Deployment"
echo "========================================="

# 1. Build Dependencies
echo "Step 1: Building Helm dependencies..."
helm dependency build "$PROJECT_ROOT/helm/spark"

# 2. Deploy Platform (Operator + RBAC)
echo "Step 2: Deploying Spark Platform Chart..."
# Note: We deploy to 'operators' but the chart creates RBAC in 'jupyterhub-users'
helm upgrade --install spark-platform "$PROJECT_ROOT/helm/spark" \
  --namespace operators \
  --create-namespace \
  --wait

echo "✓ Spark Platform deployed"

# 3. Deploy Application (Optional)
echo "Step 3: To deploy Spark Connect, run:"
echo "kubectl apply -f $PROJECT_ROOT/helm/spark/examples/spark-connect-server.yaml"

echo ""
echo "========================================="
echo "Spark Platform Ready!"
echo "========================================="
