#!/bin/bash
# Create dremio bucket in MinIO if it doesn't exist

set -e

echo "Creating dremio bucket in MinIO..."

# Check if MinIO is running
if ! kubectl get tenant minio -n minio &>/dev/null; then
    echo "ERROR: MinIO tenant not found. Please deploy MinIO first."
    exit 1
fi

# Get MinIO pod
MINIO_POD=$(kubectl get pod -n minio -l v1.min.io/tenant=minio -o jsonpath='{.items[0].metadata.name}')

if [ -z "$MINIO_POD" ]; then
    echo "ERROR: MinIO pod not found"
    exit 1
fi

# Get MinIO Credentials
# Get MinIO Credentials
echo "Retrieving MinIO credentials..."
# Use known secret name for reliability
MINIO_SECRET="minio-env-configuration"
if ! kubectl get secret "$MINIO_SECRET" -n minio &>/dev/null; then
    # Fallback to dynamic lookup if default name doesn't exist
    MINIO_SECRET=$(kubectl get secret -n minio -o jsonpath='{.items[?(@.data.config\\.env)].metadata.name}' | awk '{print $1}')
fi

if [ -z "$MINIO_SECRET" ]; then
    echo "ERROR: Could not find MinIO configuration secret"
    exit 1
fi

MINIO_ENV=$(kubectl get secret "$MINIO_SECRET" -n minio -o jsonpath='{.data.config\.env}' | base64 -d)
MINIO_ROOT_USER=$(echo "$MINIO_ENV" | grep "MINIO_ROOT_USER" | cut -d'=' -f2 | tr -d '\n\r"')
MINIO_ROOT_PASSWORD=$(echo "$MINIO_ENV" | grep "MINIO_ROOT_PASSWORD" | cut -d'=' -f2 | tr -d '\n\r"')

if [ -z "$MINIO_ROOT_USER" ]; then
    echo "ERROR: Could not extract MINIO_ROOT_USER"
    exit 1
fi

echo "Using MinIO pod: $MINIO_POD"

# Create bucket using mc (MinIO client) via stdin to avoid quoting issues
cat <<EOF | kubectl exec -i -n minio "$MINIO_POD" -- sh
    # Configure mc alias
    mc alias set local https://localhost:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" --insecure

    # Check if bucket exists
    if mc ls local/dremio --insecure >/dev/null 2>&1; then
        echo "✓ Bucket dremio already exists"
    else
        # Create bucket
        mc mb local/dremio --insecure
        echo "✓ Created bucket: dremio"
    fi

    # List buckets
    echo ""
    echo "Available buckets:"
    mc ls local --insecure
EOF

echo ""
echo "✓ Dremio bucket is ready"
