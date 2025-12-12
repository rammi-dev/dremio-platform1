#!/bin/bash

# MinIO STS Credential Generator
# This script generates temporary STS credentials using Keycloak OIDC authentication

# Get MinIO client secret
CLIENT_SECRET=$(kubectl get secret minio-env-configuration -n minio -o jsonpath='{.data.config\.env}' | base64 -d | grep MINIO_IDENTITY_OPENID_CLIENT_SECRET | cut -d'=' -f2 | tr -d '"')

echo "========================================="
echo "MinIO STS Credential Generator"
echo "========================================="
echo ""

# Step 1: Get OIDC token from Keycloak
echo "Step 1: Authenticating with Keycloak..."
TOKEN_RESPONSE=$(curl -s -X POST "http://localhost:8080/realms/vault/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "username=admin" \
  -d "password=admin" \
  -d "grant_type=password" \
  -d "client_id=minio" \
  -d "client_secret=$CLIENT_SECRET" \
  -d "scope=openid profile email")

ID_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.id_token')

if [ "$ID_TOKEN" == "null" ] || [ -z "$ID_TOKEN" ]; then
  echo "ERROR: Failed to get OIDC token"
  echo "Response: $TOKEN_RESPONSE"
  exit 1
fi

echo "✓ Got OIDC token from Keycloak"
echo ""

# Step 2: Exchange OIDC token for STS credentials
echo "Step 2: Requesting temporary STS credentials from MinIO..."
STS_RESPONSE=$(curl -s -k -X POST "https://localhost:9000" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "Action=AssumeRoleWithWebIdentity" \
  -d "WebIdentityToken=$ID_TOKEN" \
  -d "Version=2011-06-15" \
  -d "DurationSeconds=3600")

# Extract credentials from XML response
ACCESS_KEY=$(echo "$STS_RESPONSE" | grep -oP '(?<=<AccessKeyId>)[^<]+' | head -1)
SECRET_KEY=$(echo "$STS_RESPONSE" | grep -oP '(?<=<SecretAccessKey>)[^<]+' | head -1)
SESSION_TOKEN=$(echo "$STS_RESPONSE" | grep -oP '(?<=<SessionToken>)[^<]+' | head -1)
EXPIRATION=$(echo "$STS_RESPONSE" | grep -oP '(?<=<Expiration>)[^<]+' | head -1)

if [ -z "$ACCESS_KEY" ]; then
  echo "ERROR: Failed to get STS credentials"
  echo "$STS_RESPONSE" | xmllint --format - 2>/dev/null || echo "$STS_RESPONSE"
  exit 1
fi

echo "✓ Got temporary STS credentials"
echo ""
echo "========================================="
echo "Temporary STS Credentials (Valid for 1 hour):"
echo "========================================="
echo "Access Key:     $ACCESS_KEY"
echo "Secret Key:     $SECRET_KEY"
echo "Session Token:  ${SESSION_TOKEN:0:60}..."
echo "Expiration:     $EXPIRATION"
echo ""
echo "========================================="
echo "Usage Examples:"
echo "========================================="
echo ""
echo "# Export credentials to environment"
echo "export AWS_ACCESS_KEY_ID='$ACCESS_KEY'"
echo "export AWS_SECRET_ACCESS_KEY='$SECRET_KEY'"
echo "export AWS_SESSION_TOKEN='$SESSION_TOKEN'"
echo ""
echo "# AWS CLI"
echo "aws --endpoint-url https://localhost:9000 s3 ls --no-verify-ssl"
echo "aws --endpoint-url https://localhost:9000 s3 mb s3://my-bucket --no-verify-ssl"
echo ""
echo "# MinIO Client (mc)"
echo "mc alias set mytemp https://localhost:9000 $ACCESS_KEY $SECRET_KEY --api S3v4"
echo "mc ls mytemp"
echo ""
echo "# Python (boto3)"
echo "import boto3"
echo "s3 = boto3.client('s3',"
echo "    endpoint_url='https://localhost:9000',"
echo "    aws_access_key_id='$ACCESS_KEY',"
echo "    aws_secret_access_key='$SECRET_KEY',"
echo "    aws_session_token='$SESSION_TOKEN',"
echo "    verify=False)"
echo ""
