#!/bin/bash
# Clean up Dremio namespace by removing finalizers from stuck resources

set -e

NAMESPACE="${1:-dremio}"

echo "Cleaning up namespace: $NAMESPACE"

# Check if namespace exists
if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
    echo "Namespace $NAMESPACE does not exist"
    exit 0
fi

# Check if namespace is terminating
STATUS=$(kubectl get namespace "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
if [ "$STATUS" != "Terminating" ]; then
    echo "Namespace is not stuck in Terminating state"
    echo "Current status: $STATUS"
    echo "Deleting namespace..."
    kubectl delete namespace "$NAMESPACE" --wait=false
    exit 0
fi

echo "Namespace is stuck in Terminating state. Cleaning up..."

# Remove finalizers from OpenSearch clusters
echo "Removing finalizers from OpenSearch clusters..."
for resource in $(kubectl get opensearchcluster -n "$NAMESPACE" -o name 2>/dev/null); do
    echo "  - $resource"
    kubectl patch "$resource" -n "$NAMESPACE" -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
done

# Remove finalizers from PerconaServerMongoDB
echo "Removing finalizers from MongoDB clusters..."
for resource in $(kubectl get psmdb -n "$NAMESPACE" -o name 2>/dev/null); do
    echo "  - $resource"
    kubectl patch "$resource" -n "$NAMESPACE" -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
done

# Wait a bit for cleanup
sleep 5

# Check if namespace is gone
if kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
    echo "Namespace still exists. You may need to manually investigate."
    echo "Check remaining resources with:"
    echo "  kubectl api-resources --verbs=list --namespaced -o name | xargs -n 1 kubectl get -n $NAMESPACE --ignore-not-found"
else
    echo "✓ Namespace successfully cleaned up"
fi
