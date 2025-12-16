#!/bin/bash
echo "Testing login for user 'jupyter-ds'..."

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "http://localhost:8080/realms/vault/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "username=jupyter-ds" \
  -d "password=password123" \
  -d "grant_type=password" \
  -d "client_id=jupyterhub" \
  -d "client_secret=jupyterhub-secret")

if [ "$HTTP_CODE" == "200" ]; then
    echo "✓ Login successful for 'jupyter-ds'"
else
    echo "ERROR: Login failed (HTTP $HTTP_CODE)"
    exit 1
fi
