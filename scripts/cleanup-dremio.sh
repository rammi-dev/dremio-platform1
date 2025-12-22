#!/bin/bash
# Clean Dremio deployment completely
set -e

echo "========================================="
echo "Cleaning Dremio Namespace"
echo "========================================="
echo ""

# Step 1: Delete Helm release
if helm status dremio -n dremio &>/dev/null; then
  echo "Step 1: Deleting Helm release..."
  helm uninstall dremio -n dremio --wait --timeout=5m
  echo "✓ Helm release deleted"
else
  echo "Step 1: No Helm release found"
fi
echo ""

# Step 2: Delete all resources
echo "Step 2: Deleting all resources in dremio namespace..."
if kubectl get namespace dremio &>/dev/null; then
  # Delete custom resources first
  echo "  Deleting custom resources..."
  kubectl delete engines.private.dremio.com --all -n dremio --timeout=60s 2>/dev/null || true
  kubectl delete perconaservermongodb --all -n dremio --timeout=60s 2>/dev/null || true
  
  # Delete all standard resources
  echo "  Deleting pods, services, deployments..."
  kubectl delete all --all -n dremio --timeout=120s 2>/dev/null || true
  
  # Delete statefulsets explicitly (sometimes not covered by 'all')
  echo "  Deleting statefulsets..."
  kubectl delete statefulset --all -n dremio --timeout=120s 2>/dev/null || true
  
  # Delete PVCs
  echo "  Deleting PVCs (this will delete all data)..."
  PVC_COUNT=$(kubectl get pvc -n dremio --no-headers 2>/dev/null | wc -l)
  if [ "$PVC_COUNT" -gt 0 ]; then
    echo "    Found $PVC_COUNT PVCs to delete:"
    kubectl get pvc -n dremio --no-headers 2>/dev/null | awk '{print "      - " $1 " (" $4 ")"}'
    kubectl delete pvc --all -n dremio --timeout=180s 2>/dev/null || true
    echo "    ✓ PVCs deleted"
  else
    echo "    No PVCs found"
  fi
  
  # Delete secrets (except image pull secret if you want to keep it)
  echo "  Deleting secrets..."
  kubectl delete secret --all -n dremio --timeout=60s 2>/dev/null || true
  
  # Delete configmaps
  echo "  Deleting configmaps..."
  kubectl delete configmap --all -n dremio --timeout=60s 2>/dev/null || true
  
  # Delete jobs
  echo "  Deleting jobs..."
  kubectl delete job --all -n dremio --timeout=60s 2>/dev/null || true
  
  echo "✓ All resources deleted"
else
  echo "  Namespace 'dremio' does not exist"
fi
echo ""

# Step 3: Delete namespace
echo "Step 3: Deleting namespace..."
if kubectl get namespace dremio &>/dev/null; then
  kubectl delete namespace dremio --timeout=300s
  
  # Sometimes namespaces get stuck, force cleanup if needed
  echo "  Waiting for namespace deletion..."
  for i in {1..60}; do
    if ! kubectl get namespace dremio &>/dev/null; then
      echo "✓ Namespace deleted successfully"
      break
    fi
    if [ $i -eq 60 ]; then
      echo "⚠️  WARNING: Namespace deletion is taking longer than expected"
      echo "   You may need to manually remove finalizers:"
      echo "   kubectl get namespace dremio -o json | jq '.spec.finalizers = []' | kubectl replace --raw /api/v1/namespaces/dremio/finalize -f -"
    fi
    sleep 5
  done
else
  echo "✓ Namespace already deleted"
fi
echo ""

echo "========================================="
echo "Dremio Cleanup Complete!"
echo "========================================="
echo ""
echo "You can now redeploy with:"
echo "  ./scripts/deploy-dremio-ee.sh"
echo ""
