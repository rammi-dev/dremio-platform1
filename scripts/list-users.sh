#!/bin/bash
source scripts/lib/minio-common.sh

# Authenticate to get token
authenticate_keycloak

echo "Checking users in 'vault' realm..."
curl -s -X GET "http://localhost:8080/admin/realms/vault/users" \
  -H "Authorization: Bearer $ACCESS_TOKEN" | jq -r '.[] | .username'
