# MinIO STS Credentials - Quick Reference

## What is STS?
STS (Secure Token Service) provides temporary, time-limited credentials for accessing MinIO. These credentials automatically expire after a set duration (default: 1 hour), providing better security than permanent access keys.

## How It Works
1. User authenticates with Keycloak (OIDC provider)
2. Keycloak issues an ID token
3. MinIO exchanges the ID token for temporary STS credentials
4. Credentials include: Access Key, Secret Key, and Session Token
5. Credentials expire after the specified duration

## Prerequisites
- Keycloak must be running and accessible on localhost:8080
- MinIO must be configured with OIDC (done automatically by deployment script)
- User must exist in Keycloak and be member of 'minio-access' group

## Generate STS Credentials

### Using the Script
```bash
./scripts/get-minio-sts-credentials.sh
```

### Manual Process
```bash
# 1. Get MinIO client secret
CLIENT_SECRET=$(kubectl get secret minio-env-configuration -n minio -o jsonpath='{.data.config\.env}' | base64 -d | grep MINIO_IDENTITY_OPENID_CLIENT_SECRET | cut -d'=' -f2 | tr -d '"')

# 2. Get OIDC token from Keycloak
TOKEN_RESPONSE=$(curl -s -X POST "http://localhost:8080/realms/vault/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "username=admin" \
  -d "password=admin" \
  -d "grant_type=password" \
  -d "client_id=minio" \
  -d "client_secret=$CLIENT_SECRET" \
  -d "scope=openid profile email")

ID_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.id_token')

# 3. Exchange OIDC token for STS credentials
curl -k -X POST "https://localhost:9000" \
  -d "Action=AssumeRoleWithWebIdentity" \
  -d "WebIdentityToken=$ID_TOKEN" \
  -d "Version=2011-06-15" \
  -d "DurationSeconds=3600"
```

## Using STS Credentials

### AWS CLI
```bash
export AWS_ACCESS_KEY_ID='<access-key>'
export AWS_SECRET_ACCESS_KEY='<secret-key>'
export AWS_SESSION_TOKEN='<session-token>'

aws --endpoint-url https://localhost:9000 s3 ls --no-verify-ssl
aws --endpoint-url https://localhost:9000 s3 mb s3://my-bucket --no-verify-ssl
```

### Python (boto3)
```python
import boto3

s3 = boto3.client('s3',
    endpoint_url='https://localhost:9000',
    aws_access_key_id='<access-key>',
    aws_secret_access_key='<secret-key>',
    aws_session_token='<session-token>',
    verify=False
)

# List buckets
response = s3.list_buckets()
print(response['Buckets'])
```

### MinIO Client (mc)
```bash
mc alias set mytemp https://localhost:9000 <access-key> <secret-key> --api S3v4
mc ls mytemp
```

## Keycloak Configuration

The MinIO deployment script automatically configures Keycloak with:
- **Client ID**: `minio`
- **Direct Access Grants**: Enabled (allows password grant for STS)
- **Standard Flow**: Enabled (allows browser-based SSO login)
- **Redirect URIs**: `http://localhost:9091/*`, `https://localhost:9091/*`

This configuration is done in the `configure_keycloak_client()` function in `scripts/lib/minio-common.sh`.

## Troubleshooting

### "Invalid client or Invalid client credentials"
- Ensure Keycloak port-forward is running: `./scripts/start-port-forwards.sh`
- Verify client secret is correct
- Check that directAccessGrantsEnabled is true for the minio client

### "None of the given policies are defined"
- Ensure `minio-access` policy exists in MinIO
- Verify user is member of `minio-access` group in Keycloak
- Run the deployment script which creates the policy automatically

### Credentials expired
- STS credentials expire after 1 hour by default
- Generate new credentials using the script
- You can request longer duration (max 7 days) by changing DurationSeconds parameter
