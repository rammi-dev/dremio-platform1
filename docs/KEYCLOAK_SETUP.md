# Keycloak Initial Setup Guide

## Access Information

- **URL**: http://localhost:8080 (via port-forward)
- **Admin Username**: `temp-admin`
- **Admin Password**: `dc708357408746589062f181bfd7ee26`

## Initial Configuration Steps

### 1. Create a Permanent Admin User (IMPORTANT - Do This First!)

The default `temp-admin` account is temporary and should be replaced with a permanent admin user.

**Steps:**

1. **Stay in the `master` realm** (admin realm - shown in top-left dropdown)
2. Go to **Users** in the left sidebar
3. Click **Add user**
4. Fill in:
   - **Username**: `admin` (or your preferred admin username)
   - **Email**: your email address
   - **First name** / **Last name**: (optional)
   - **Email verified**: Toggle **ON**
5. Click **Create**
6. Go to the **Credentials** tab
7. Click **Set password**
8. Enter a strong password
9. **Important**: Toggle **Temporary** to **OFF** (so you won't be forced to change it)
10. Click **Save**
11. Go to the **Role mapping** tab
12. Click **Assign role**
13. Click **Filter by clients** dropdown
14. Search and assign these roles:
    - `admin` (from realm-management)
    - `realm-admin` (from realm-management)
15. Click **Assign**

**Verify:**
- Log out from temp-admin
- Log in with your new admin account
- Once verified, delete the `temp-admin` user from Users list

### 2. Create a New Realm

A realm manages a set of users, credentials, roles, and groups. The `master` realm is for admin purposes only.

1. Click the dropdown in the top-left (currently showing "master")
2. Click **"Create Realm"**
3. Enter a **Realm name** (e.g., `myrealm` or `dremio`)
4. Click **Create**

### 2. Create a Client

Clients are applications that can request authentication from Keycloak.

1. In your new realm, go to **Clients** (left sidebar)
2. Click **Create client**
3. Configure:
   - **Client ID**: Your application identifier (e.g., `dremio-app`)
   - **Client Protocol**: `openid-connect`
   - Click **Next**
4. **Capability config**:
   - Enable **Client authentication** (for confidential clients)
   - Enable **Authorization** (if needed)
   - Click **Next**
5. **Login settings**:
   - **Valid redirect URIs**: Add your application's callback URL (e.g., `http://localhost:9047/*` for Dremio)
   - **Web origins**: `+` (to allow all valid redirect URIs)
   - Click **Save**

### 3. Create Users

1. Go to **Users** (left sidebar)
2. Click **Add user**
3. Fill in:
   - **Username**: (required)
   - **Email**, **First name**, **Last name** (optional)
   - **Email verified**: Toggle ON if you want to skip email verification
4. Click **Create**
5. Go to the **Credentials** tab
6. Click **Set password**
7. Enter password, toggle **Temporary** OFF if you don't want the user to change it on first login
8. Click **Save**

### 4. Create Roles (Optional)

Roles define permissions for users.

1. Go to **Realm roles** (left sidebar)
2. Click **Create role**
3. Enter **Role name** (e.g., `admin`, `user`, `viewer`)
4. Click **Save**
5. Assign roles to users:
   - Go to **Users** → Select user → **Role mapping** tab
   - Click **Assign role** → Select roles → **Assign**

### 5. Get Client Credentials

For confidential clients (with authentication enabled):

1. Go to **Clients** → Select your client
2. Go to **Credentials** tab
3. Copy the **Client secret** - you'll need this for your application

## Common Use Cases

### For Dremio Integration

1. Create a realm: `dremio`
2. Create a client: `dremio-app`
   - Client authentication: ON
   - Valid redirect URIs: `http://localhost:9047/*`
3. Create users with appropriate roles
4. Configure Dremio to use Keycloak OIDC:
   - **Issuer URL**: `http://keycloak-service.operators.svc.cluster.local:8080/realms/dremio`
   - **Client ID**: `dremio-app`
   - **Client Secret**: (from Keycloak client credentials)

### For Vault Integration (OIDC)

1. Create a realm: `vault`
2. Create a client: `vault`
   - Client authentication: ON
   - Valid redirect URIs: `http://localhost:8200/ui/vault/auth/oidc/oidc/callback`
3. Get client credentials for Vault configuration

## Port Forward Command

The port-forward is currently running. If it stops, restart with:

```bash
kubectl port-forward -n operators svc/keycloak-service 8080:8080 --address=0.0.0.0
```

## Namespace Information

- **Keycloak Operator**: `operators` namespace
- **Keycloak Instance**: `operators` namespace
- **PostgreSQL Database**: `operators` namespace

## Troubleshooting

### Can't access Keycloak UI
- Ensure port-forward is running
- Check pod status: `kubectl get pods -n operators`
- Check logs: `kubectl logs keycloak-0 -n operators`

### Forgot admin password
```bash
kubectl get secret keycloak-initial-admin -n operators -o jsonpath='{.data.password}' | base64 -d
```

### Reset Keycloak
```bash
kubectl delete pod keycloak-0 -n operators
```

## Next Steps

1. ✅ Create a realm for your application
2. ✅ Create a client for your application
3. ✅ Create test users
4. ✅ Configure your application to use Keycloak OIDC
5. ✅ Test authentication flow
