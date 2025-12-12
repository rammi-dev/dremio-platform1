# JupyterHub Integration with Keycloak and MinIO

This directory contains the configuration for deploying JupyterHub with Keycloak OIDC authentication and automatic MinIO STS credential injection.

## Overview

JupyterHub is deployed with the following integrations:

1. **Keycloak OIDC Authentication** - Users authenticate via Keycloak
2. **MinIO STS Credentials** - Temporary S3 credentials automatically injected into notebooks
3. **Persistent Storage** - Each user gets 10GB persistent storage for notebooks
4. **Resource Limits** - CPU and memory limits per user

## Architecture

```
┌─────────┐      ┌──────────┐      ┌────────────┐      ┌───────┐
│  User   │─────▶│ Keycloak │─────▶│ JupyterHub │─────▶│ MinIO │
└─────────┘      └──────────┘      └────────────┘      └───────┘
                      │                   │
                      │                   │
                      ▼                   ▼
                 OIDC Token         STS Credentials
                 (ID Token)         (Temporary)
```

### Namespace Architecture

JupyterHub is deployed across multiple namespaces for better isolation:

| Namespace | Components | Purpose |
|-----------|------------|---------|
| `jupyterhub` | Hub pod, Proxy pod | Central JupyterHub control plane |
| `jupyterhub-users` | User notebook pods, PVCs | Isolated user workloads |
| `operators` | Keycloak | Authentication provider |
| `minio` | MinIO tenant pods | S3 storage |
| `minio-operator` | MinIO operator | MinIO management |

**Benefits:**
- **Isolation**: User notebooks run in separate namespace from hub
- **Security**: RBAC limits hub's permissions to only what's needed
- **Resource Management**: Easier to apply quotas per namespace
- **Multi-tenancy**: Can apply different policies to user namespace

**RBAC Configuration:**
The JupyterHub service account in `jupyterhub` namespace has a Role and RoleBinding in `jupyterhub-users` namespace that grants permissions to:
- Create/delete/manage pods
- Create/delete persistent volume claims
- Create/delete services (for notebook access)
- View events (for debugging)

### Authentication Flow

1. User accesses JupyterHub at `http://localhost:8000`
2. Clicks "Sign in with Keycloak"
3. Redirected to Keycloak login page
4. Enters credentials (username: `admin`, password: `admin`)
5. Keycloak issues OIDC tokens (ID token, access token)
6. User redirected back to JupyterHub with tokens
7. JupyterHub validates tokens and creates user session

### STS Credential Injection Flow

1. User starts a Jupyter notebook server
2. **Pre-spawn hook** is triggered (before pod creation)
3. Hook extracts user's OIDC ID token from auth state
4. Hook calls MinIO STS API: `AssumeRoleWithWebIdentity`
5. MinIO validates OIDC token with Keycloak
6. MinIO returns temporary credentials (valid for 1 hour):
   - Access Key ID
   - Secret Access Key
   - Session Token
7. Hook injects credentials as environment variables
8. Notebook pod starts with credentials available

## Configuration Files

### [`values.yaml`](file:///home/rami/Work/dremio-platform1/helm/jupyterhub/values.yaml)

Main Helm chart configuration file.

#### Key Sections

**1. OIDC Authentication (`hub.config`)**

```yaml
hub:
  config:
    JupyterHub:
      authenticator_class: generic-oauth
    GenericOAuthenticator:
      client_id: jupyterhub
      oauth_callback_url: http://localhost:8000/hub/oauth_callback
      authorize_url: http://keycloak-service.operators.svc.cluster.local:8080/realms/vault/protocol/openid-connect/auth
      token_url: http://keycloak-service.operators.svc.cluster.local:8080/realms/vault/protocol/openid-connect/token
      userdata_url: http://keycloak-service.operators.svc.cluster.local:8080/realms/vault/protocol/openid-connect/userinfo
      username_claim: preferred_username
      enable_auth_state: true  # Required for storing OIDC tokens
```

**What's configured:**
- `client_id`: Keycloak client identifier (`jupyterhub`)
- `client_secret`: Set via `--set` during deployment (from Keycloak)
- `oauth_callback_url`: Where Keycloak redirects after authentication
- `authorize_url`: Keycloak authorization endpoint
- `token_url`: Keycloak token endpoint
- `userdata_url`: Keycloak user info endpoint
- `username_claim`: Which claim to use as username (`preferred_username`)
- `enable_auth_state`: Enables storing auth state (required for STS)

**2. STS Credential Injection (`hub.extraConfig.pre_spawn_hook`)**

```python
async def pre_spawn_hook(spawner):
    # Get user's OIDC token
    auth_state = await spawner.user.get_auth_state()
    id_token = auth_state['id_token']
    
    # Call MinIO STS API
    sts_response = requests.post(
        'https://minio.minio.svc.cluster.local:443',
        data={
            'Action': 'AssumeRoleWithWebIdentity',
            'WebIdentityToken': id_token,
            'Version': '2011-06-15',
            'DurationSeconds': '3600'
        }
    )
    
    # Parse credentials and inject as environment variables
    spawner.environment.update({
        'AWS_ACCESS_KEY_ID': access_key,
        'AWS_SECRET_ACCESS_KEY': secret_key,
        'AWS_SESSION_TOKEN': session_token,
        'S3_ENDPOINT': 'https://minio.minio.svc.cluster.local:443'
    })
```

**What's passed:**
- `id_token`: User's OIDC ID token from Keycloak
- `WebIdentityToken`: The ID token sent to MinIO STS API
- `DurationSeconds`: How long credentials are valid (3600 = 1 hour)

**What's injected:**
- `AWS_ACCESS_KEY_ID`: Temporary access key
- `AWS_SECRET_ACCESS_KEY`: Temporary secret key
- `AWS_SESSION_TOKEN`: Session token (required for STS credentials)
- `S3_ENDPOINT`: MinIO endpoint URL

**3. User Resources (`singleuser`)**

```yaml
singleuser:
  image:
    name: jupyter/scipy-notebook
    tag: latest
  
  cpu:
    limit: 2
    guarantee: 0.5
  
  memory:
    limit: 2G
    guarantee: 512M
  
  storage:
    type: dynamic
    capacity: 10Gi
```

**What's configured:**
- **Image**: `jupyter/scipy-notebook` (includes pandas, numpy, scipy, matplotlib)
- **CPU**: 0.5-2 cores per user
- **Memory**: 512MB-2GB per user
- **Storage**: 10GB persistent volume per user

## Deployment Scripts

### [`scripts/deploy-jupyterhub-gke.sh`](file:///home/rami/Work/dremio-platform1/scripts/deploy-jupyterhub-gke.sh)

Main deployment script.

**Steps:**
1. Checks prerequisites (Keycloak and MinIO running)
2. Authenticates with Keycloak admin API
3. Creates/updates `jupyterhub` client in Keycloak
4. Retrieves client secret
5. Deploys JupyterHub via Helm with client secret
6. Waits for JupyterHub to be ready
7. Starts port-forward on localhost:8000

### [`scripts/lib/jupyterhub-common.sh`](file:///home/rami/Work/dremio-platform1/scripts/lib/jupyterhub-common.sh)

Shared functions library.

**Key Functions:**
- `configure_jupyterhub_keycloak_client()`: Creates Keycloak client
- `deploy_jupyterhub()`: Deploys JupyterHub via Helm
- `wait_for_jupyterhub_ready()`: Waits for pods to be ready
- `start_jupyterhub_port_forward()`: Starts port-forward

## Keycloak Configuration

### Client Settings

**Created in Keycloak realm: `vault`**

| Setting | Value | Purpose |
|---------|-------|---------|
| Client ID | `jupyterhub` | Identifies JupyterHub to Keycloak |
| Client Protocol | `openid-connect` | OIDC authentication |
| Access Type | `confidential` | Requires client secret |
| Standard Flow | `Enabled` | Browser-based login |
| Direct Access Grants | `Enabled` | Password grant (for testing) |
| Valid Redirect URIs | `http://localhost:8000/hub/oauth_callback` | Where to redirect after login |
| Web Origins | `+` | Allow CORS from redirect URIs |

### What's Passed to JupyterHub

**During Authentication:**
1. **Authorization Code** (from Keycloak to JupyterHub)
2. **ID Token** (contains user identity)
3. **Access Token** (for API access)
4. **Refresh Token** (to renew tokens)

**Stored in Auth State:**
```python
{
    'id_token': '<jwt-token>',
    'access_token': '<jwt-token>',
    'refresh_token': '<jwt-token>',
    'token_response': {...}
}
```

## Keycloak User Configuration and Mapping

### User Attributes in Keycloak

When a user is created in Keycloak (realm: `vault`), the following attributes are configured:

| Attribute | Example Value | Purpose |
|-----------|---------------|---------|
| **Username** | `admin` | Unique identifier for the user |
| **Email** | `admin@vault.local` | User's email address |
| **First Name** | `Admin` | User's first name |
| **Last Name** | `User` | User's last name |
| **Email Verified** | `true` | Whether email is verified |
| **Enabled** | `true` | Whether user account is active |

### User Groups

Users are assigned to groups for access control:

| Group | Purpose | MinIO Policy |
|-------|---------|--------------|
| `minio-access` | Grants access to MinIO | `minio-access` (full S3 access) |
| `vault-admins` | Vault administrator access | N/A for JupyterHub |

**How groups are used:**
1. User logs into JupyterHub via Keycloak
2. Keycloak includes user's groups in the ID token (via `groups` claim)
3. MinIO STS validates the token and checks group membership
4. MinIO applies the `minio-access` policy if user is in `minio-access` group
5. Temporary credentials are issued with policy permissions

### OIDC Token Claims

When a user authenticates, Keycloak issues an **ID Token** (JWT) containing these claims:

```json
{
  "sub": "467a529c-7f37-47e3-9ab2-8cc7977fcbe1",
  "preferred_username": "admin",
  "email": "admin@vault.local",
  "email_verified": true,
  "name": "Admin User",
  "given_name": "Admin",
  "family_name": "User",
  "groups": ["minio-access", "vault-admins"],
  "iss": "http://keycloak-service.operators.svc.cluster.local:8080/realms/vault",
  "aud": "jupyterhub",
  "exp": 1733995200,
  "iat": 1733991600
}
```

### How Keycloak Users Map to JupyterHub

**1. Username Mapping**

JupyterHub uses the `preferred_username` claim from the ID token:

```yaml
# In values.yaml
GenericOAuthenticator:
  username_claim: preferred_username
```

**Flow:**
```
Keycloak User: admin
    ↓
ID Token Claim: "preferred_username": "admin"
    ↓
JupyterHub Username: admin
    ↓
Notebook Server: jupyter-admin
```

**2. User Home Directory**

Each JupyterHub user gets a persistent volume mounted at `/home/jovyan`:

```
Keycloak Username: admin
    ↓
JupyterHub User: admin
    ↓
PVC Name: claim-admin
    ↓
Mount Path: /home/jovyan
```

**3. Group-Based Access Control**

Groups from Keycloak are passed to MinIO for policy enforcement:

```
Keycloak Groups: ["minio-access", "vault-admins"]
    ↓
ID Token: "groups": ["minio-access", "vault-admins"]
    ↓
MinIO STS: Validates token and checks groups
    ↓
MinIO Policy: Applies "minio-access" policy
    ↓
S3 Permissions: Full access to all buckets
```

### Keycloak Client Mappers

The `jupyterhub` client in Keycloak has the following mappers configured:

#### 1. Groups Mapper

**Purpose:** Include user's groups in the ID token

| Setting | Value |
|---------|-------|
| Mapper Type | `Group Membership` |
| Token Claim Name | `groups` |
| Full group path | `OFF` |
| Add to ID token | `ON` |
| Add to access token | `ON` |
| Add to userinfo | `ON` |

**Result in ID Token:**
```json
{
  "groups": ["minio-access", "vault-admins"]
}
```

#### 2. Email Mapper

**Purpose:** Include user's email in the ID token

| Setting | Value |
|---------|-------|
| Mapper Type | `User Property` |
| Property | `email` |
| Token Claim Name | `email` |
| Add to ID token | `ON` |

#### 3. Full Name Mapper

**Purpose:** Include user's full name in the ID token

| Setting | Value |
|---------|-------|
| Mapper Type | `User's full name` |
| Token Claim Name | `name` |
| Add to ID token | `ON` |

### User Lifecycle

**1. User Creation in Keycloak**

```bash
# Create user via Keycloak admin API
curl -X POST "http://localhost:8080/admin/realms/vault/users" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "username": "alice",
    "email": "alice@example.com",
    "firstName": "Alice",
    "lastName": "Smith",
    "enabled": true,
    "emailVerified": true,
    "credentials": [{
      "type": "password",
      "value": "password123",
      "temporary": false
    }]
  }'

# Add user to minio-access group
curl -X PUT "http://localhost:8080/admin/realms/vault/users/$USER_ID/groups/$GROUP_ID" \
  -H "Authorization: Bearer $ACCESS_TOKEN"
```

**2. First Login to JupyterHub**

```
User: alice
    ↓
Keycloak Authentication
    ↓
ID Token with claims:
  - preferred_username: "alice"
  - email: "alice@example.com"
  - groups: ["minio-access"]
    ↓
JupyterHub creates user: alice
    ↓
Persistent volume created: claim-alice
    ↓
User home directory: /home/jovyan
```

**3. Starting Notebook Server**

```
User clicks "Start My Server"
    ↓
Pre-spawn hook triggered
    ↓
Extract ID token from auth state
    ↓
Call MinIO STS with ID token
    ↓
MinIO validates token:
  - Checks signature
  - Verifies issuer (Keycloak)
  - Checks expiration
  - Extracts groups claim
    ↓
MinIO checks group membership:
  - User in "minio-access" group? YES
  - Apply "minio-access" policy
    ↓
MinIO issues temporary credentials
    ↓
Credentials injected as environment variables
    ↓
Notebook pod starts with S3 access
```

### User Session Management

**Token Expiration:**
- **ID Token**: Expires after 5 minutes (Keycloak default)
- **Access Token**: Expires after 5 minutes
- **Refresh Token**: Expires after 30 minutes
- **STS Credentials**: Expire after 12 hours (43200 seconds)

> **Note:** STS credentials are currently set for 12 hours. MinIO supports up to 7 days (604800 seconds).
> 
> **Future Improvement:** Implement automatic credential renewal via a sidecar container that refreshes credentials before expiration, allowing notebooks to run indefinitely without restart.

**Token Refresh:**
JupyterHub automatically refreshes tokens using the refresh token when:
- Access token expires
- User accesses JupyterHub after token expiration
- User starts a new notebook server

**Session Persistence:**
- User's auth state is stored in JupyterHub database
- Survives JupyterHub pod restarts
- Cleared when user explicitly logs out

### Example: Adding a New User

**Step 1: Create user in Keycloak**
```bash
# Via Keycloak admin console or API
Username: bob
Email: bob@example.com
Password: bobpassword
```

**Step 2: Add to minio-access group**
```bash
# Via Keycloak admin console:
# Users → bob → Groups → Available Groups → minio-access → Join
```

**Step 3: User logs into JupyterHub**
```
1. Navigate to http://localhost:8000
2. Click "Sign in with Keycloak"
3. Enter username: bob, password: bobpassword
4. Redirected to JupyterHub
5. Username shown: bob
```

**Step 4: User starts notebook**
```
1. Click "Start My Server"
2. Pre-spawn hook runs:
   - Gets bob's ID token
   - Token includes: "groups": ["minio-access"]
   - Calls MinIO STS
   - MinIO validates and issues credentials
3. Notebook starts with environment variables:
   - AWS_ACCESS_KEY_ID=<temporary-key>
   - AWS_SECRET_ACCESS_KEY=<temporary-secret>
   - AWS_SESSION_TOKEN=<session-token>
4. Bob can now access MinIO S3
```

### Customizing User Mapping

You can customize how Keycloak users map to JupyterHub by modifying `values.yaml`:

**Use email as username:**
```yaml
GenericOAuthenticator:
  username_claim: email  # Instead of preferred_username
```

**Add custom claim processing:**
```yaml
hub:
  extraConfig:
    custom_claim_processing: |
      async def custom_claim_processing(authenticator, handler, auth_model):
          # Extract custom claims from ID token
          user_info = auth_model['auth_state']['oauth_user']
          
          # Set admin status based on group
          if 'vault-admins' in user_info.get('groups', []):
              auth_model['admin'] = True
          
          return auth_model
      
      c.GenericOAuthenticator.modify_auth_state_hook = custom_claim_processing
```



## MinIO STS Integration

### STS API Call

**Endpoint:** `https://minio.minio.svc.cluster.local:443`

**Request Parameters:**
```
Action=AssumeRoleWithWebIdentity
WebIdentityToken=<id-token-from-keycloak>
Version=2011-06-15
DurationSeconds=3600
```

**Response (XML):**
```xml
<AssumeRoleWithWebIdentityResponse>
  <AssumeRoleWithWebIdentityResult>
    <Credentials>
      <AccessKeyId>AKIAIOSFODNN7EXAMPLE</AccessKeyId>
      <SecretAccessKey>wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY</SecretAccessKey>
      <SessionToken>AQoDYXdzEJr.....</SessionToken>
      <Expiration>2025-12-12T10:00:00Z</Expiration>
    </Credentials>
  </AssumeRoleWithWebIdentityResult>
</AssumeRoleWithWebIdentityResponse>
```

### Policy Applied

Users authenticated via Keycloak get the `minio-access` policy, which grants:
- Full S3 access (`s3:*`)
- To all buckets (`arn:aws:s3:::*`)

## Usage in Jupyter Notebooks

### Accessing MinIO S3

Environment variables are automatically available:

```python
import boto3
import os

# Create S3 client using environment variables
s3 = boto3.client('s3',
    endpoint_url=os.environ['S3_ENDPOINT'],
    aws_access_key_id=os.environ['AWS_ACCESS_KEY_ID'],
    aws_secret_access_key=os.environ['AWS_SECRET_ACCESS_KEY'],
    aws_session_token=os.environ['AWS_SESSION_TOKEN'],
    verify=False  # For self-signed certificates
)

# List buckets
response = s3.list_buckets()
print(response['Buckets'])

# Upload file
s3.upload_file('local-file.txt', 'default-bucket', 'remote-file.txt')

# Download file
s3.download_file('default-bucket', 'remote-file.txt', 'downloaded-file.txt')

# List objects in bucket
response = s3.list_objects_v2(Bucket='default-bucket')
for obj in response.get('Contents', []):
    print(obj['Key'])
```

### Using pandas with S3

```python
import pandas as pd
import os

# Read CSV from S3
df = pd.read_csv(
    f"s3://default-bucket/data.csv",
    storage_options={
        'client_kwargs': {
            'endpoint_url': os.environ['S3_ENDPOINT'],
            'verify': False
        }
    }
)

# Write CSV to S3
df.to_csv(
    f"s3://default-bucket/output.csv",
    storage_options={
        'client_kwargs': {
            'endpoint_url': os.environ['S3_ENDPOINT'],
            'verify': False
        }
    },
    index=False
)
```

## Deployment

### Prerequisites

1. Keycloak must be running (deployed via `./scripts/deploy-gke.sh`)
2. MinIO must be running (deployed via `./scripts/deploy-minio-gke.sh`)
3. Port-forwards should be active for Keycloak (8080)

### Deploy JupyterHub

```bash
./scripts/deploy-jupyterhub-gke.sh
```

### Access JupyterHub

1. Open browser to `http://localhost:8000`
2. Click "Sign in with Keycloak"
3. Login with:
   - Username: `admin`
   - Password: `admin`
4. Start your server
5. Open a notebook and test S3 access

## Troubleshooting

### Authentication Issues

**Problem:** "Invalid redirect URI"
- **Solution:** Check Keycloak client redirect URIs include `http://localhost:8000/hub/oauth_callback`

**Problem:** "Client authentication failed"
- **Solution:** Verify client secret is correctly passed to Helm chart

### STS Credential Issues

**Problem:** No environment variables in notebook
- **Solution:** Check JupyterHub hub pod logs for pre-spawn hook errors:
  ```bash
  kubectl logs -n jupyterhub -l component=hub
  ```

**Problem:** "Access Denied" when accessing S3
- **Solution:** Verify user is member of `minio-access` group in Keycloak
- **Solution:** Check MinIO policy exists:
  ```bash
  kubectl exec -n minio minio-pool-0-0 -c minio -- mc admin policy list myminio --insecure
  ```

**Problem:** Credentials expired
- **Solution:** Restart notebook server (credentials are regenerated on each spawn)

### Pod Issues

**Problem:** Notebook pod won't start
- **Solution:** Check pod events:
  ```bash
  kubectl get events -n jupyterhub --sort-by='.lastTimestamp'
  ```
- **Solution:** Check resource availability (CPU/memory)

## Security Considerations

1. **Credential Expiration**: STS credentials expire after 12 hours (configurable up to 7 days)
2. **Token Storage**: Auth state stored in JupyterHub database (encrypted)
3. **Network Isolation**: All communication within Kubernetes cluster
4. **TLS**: MinIO uses TLS (self-signed certificates in dev)
5. **RBAC**: Keycloak groups control MinIO access policies
6. **Namespace Isolation**: User notebooks isolated in separate namespace

## Future Improvements

1. **Automatic Credential Renewal**: Implement sidecar container to refresh STS credentials before expiration
2. Configure custom user images with pre-installed packages
3. Set up user-specific bucket prefixes
4. Integrate with Dremio for data analytics
5. Add GPU support for ML workloads
6. Configure external access (Ingress)
