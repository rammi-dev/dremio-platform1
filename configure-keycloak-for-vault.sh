#!/bin/bash
set -e

echo "=== Configuring Keycloak for Vault OIDC ==="
echo ""

# Keycloak admin credentials
KEYCLOAK_URL="http://localhost:8080"
ADMIN_USER="admin"
ADMIN_PASS="admin"  # You'll need to set this

# Get admin token
echo "Step 1: Getting admin access token..."
TOKEN_RESPONSE=$(curl -s -X POST "$KEYCLOAK_URL/realms/master/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "username=$ADMIN_USER" \
  -d "password=$ADMIN_PASS" \
  -d "grant_type=password" \
  -d "client_id=admin-cli")

ACCESS_TOKEN=$(echo $TOKEN_RESPONSE | jq -r '.access_token')

if [ "$ACCESS_TOKEN" == "null" ]; then
    echo "ERROR: Failed to get access token. Please check your admin password."
    exit 1
fi

echo "✓ Successfully authenticated"

# Create vault realm
echo ""
echo "Step 2: Creating vault realm..."
curl -s -X POST "$KEYCLOAK_URL/admin/realms" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "realm": "vault",
    "enabled": true,
    "displayName": "Vault"
  }'
echo "✓ Vault realm created"

# Create vault client
echo ""
echo "Step 3: Creating vault OIDC client..."
curl -s -X POST "$KEYCLOAK_URL/admin/realms/vault/clients" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "clientId": "vault",
    "name": "HashiCorp Vault",
    "enabled": true,
    "protocol": "openid-connect",
    "publicClient": false,
    "serviceAccountsEnabled": false,
    "directAccessGrantsEnabled": true,
    "standardFlowEnabled": true,
    "implicitFlowEnabled": false,
    "redirectUris": [
      "http://localhost:8200/ui/vault/auth/oidc/oidc/callback",
      "http://localhost:8250/oidc/callback"
    ],
    "webOrigins": ["+"],
    "attributes": {
      "post.logout.redirect.uris": "http://localhost:8200"
    }
  }'
echo "✓ Vault client created"

# Get client UUID
echo ""
echo "Step 4: Getting client UUID..."
CLIENT_UUID=$(curl -s -X GET "$KEYCLOAK_URL/admin/realms/vault/clients?clientId=vault" \
  -H "Authorization: Bearer $ACCESS_TOKEN" | jq -r '.[0].id')

# Get client secret
echo ""
echo "Step 5: Retrieving client secret..."
CLIENT_SECRET=$(curl -s -X GET "$KEYCLOAK_URL/admin/realms/vault/clients/$CLIENT_UUID/client-secret" \
  -H "Authorization: Bearer $ACCESS_TOKEN" | jq -r '.value')

echo "✓ Client secret retrieved"
echo ""
echo "CLIENT SECRET: $CLIENT_SECRET"
echo ""

# Save to file
echo "$CLIENT_SECRET" > keycloak-vault-client-secret.txt
echo "✓ Client secret saved to keycloak-vault-client-secret.txt"

# Create vault-admins group
echo ""
echo "Step 6: Creating vault-admins group..."
curl -s -X POST "$KEYCLOAK_URL/admin/realms/vault/groups" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "vault-admins"
  }'
echo "✓ vault-admins group created"

# Get group ID
GROUP_ID=$(curl -s -X GET "$KEYCLOAK_URL/admin/realms/vault/groups?search=vault-admins" \
  -H "Authorization: Bearer $ACCESS_TOKEN" | jq -r '.[0].id')

# Create admin user in vault realm
echo ""
echo "Step 7: Creating admin user in vault realm..."
curl -s -X POST "$KEYCLOAK_URL/admin/realms/vault/users" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "username": "admin",
    "email": "krystalografia@gmail.com",
    "enabled": true,
    "emailVerified": true
  }'

# Get user ID
USER_ID=$(curl -s -X GET "$KEYCLOAK_URL/admin/realms/vault/users?username=admin" \
  -H "Authorization: Bearer $ACCESS_TOKEN" | jq -r '.[0].id')

# Set password
echo "Step 8: Setting admin password..."
curl -s -X PUT "$KEYCLOAK_URL/admin/realms/vault/users/$USER_ID/reset-password" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{
    \"type\": \"password\",
    \"value\": \"$ADMIN_PASS\",
    \"temporary\": false
  }"
echo "✓ Password set"

# Add user to group
echo ""
echo "Step 9: Adding admin user to vault-admins group..."
curl -s -X PUT "$KEYCLOAK_URL/admin/realms/vault/users/$USER_ID/groups/$GROUP_ID" \
  -H "Authorization: Bearer $ACCESS_TOKEN"
echo "✓ User added to group"

# Add group mapper to client
echo ""
echo "Step 10: Configuring group claim mapper..."
curl -s -X POST "$KEYCLOAK_URL/admin/realms/vault/clients/$CLIENT_UUID/protocol-mappers/models" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "groups",
    "protocol": "openid-connect",
    "protocolMapper": "oidc-group-membership-mapper",
    "config": {
      "full.path": "false",
      "id.token.claim": "true",
      "access.token.claim": "true",
      "claim.name": "groups",
      "userinfo.token.claim": "true"
    }
  }'
echo "✓ Group mapper configured"

echo ""
echo "=== Keycloak Configuration Complete! ==="
echo ""
echo "Client Secret: $CLIENT_SECRET"
echo ""
echo "Next step: Run the Vault configuration script:"
echo "  export KEYCLOAK_CLIENT_SECRET='$CLIENT_SECRET'"
echo "  ./configure-vault-oidc.sh"
echo ""
