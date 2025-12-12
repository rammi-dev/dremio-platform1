#!/bin/bash
set -e
source scripts/lib/minio-common.sh

start_port_forward

# Get Root Credentials
MINIO_ROOT_USER=$(kubectl get secret -n minio -o jsonpath='{.items[?(@.data.config\.env)].data.config\.env}' | base64 -d | grep "MINIO_ROOT_USER" | cut -d "=" -f2 | tr -d '"')
MINIO_ROOT_PASSWORD=$(kubectl get secret -n minio -o jsonpath='{.items[?(@.data.config\.env)].data.config\.env}' | base64 -d | grep "MINIO_ROOT_PASSWORD" | cut -d "=" -f2 | tr -d '"')

export MC_CONFIG_DIR="/tmp/.mc"
mkdir -p "$MC_CONFIG_DIR"
alias mc="docker run -v $MC_CONFIG_DIR:/root/.mc --network host --entrypoint mc minio/mc"

if ! command -v mc &> /dev/null; then
  # Use the one we downloaded earlier if available, or download again
  if [ -f /tmp/mc ]; then
    alias mc="/tmp/mc"
  else
    curl -s https://dl.min.io/client/mc/release/linux-amd64/mc -o /tmp/mc
    chmod +x /tmp/mc
    alias mc="/tmp/mc"
  fi
fi

mc alias set myminio https://localhost:9091 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" --insecure >/dev/null

echo "Existing Policies:"
mc admin policy list myminio --insecure

pkill -f "kubectl port-forward -n minio" || true
