echo "Restoring MinIO Access..."

# Check if MinIO is running
if ! kubectl get pod -n minio -l v1.min.io/tenant=minio | grep -q "Running"; then
  echo "MinIO pods not found or not running."
  echo "Run ./scripts/deploy-minio.sh to install."
  exit 1
fi

echo "Starting MinIO Console Port-Forward..."
pkill -f "kubectl port-forward -n minio svc/minio-console" || true
nohup kubectl port-forward -n minio svc/minio-console 9091:9443 --address=0.0.0.0 > /dev/null 2>&1 &
echo "✓ Port-forward started"
echo "Console: https://localhost:9091"
echo ""
echo "MinIO Console: http://localhost:9090"
