# Vault and Keycloak OIDC Integration Setup

## Important Credentials

**Vault Root Token**: `hvs.qHocdq4yjXI53ehNvjHvxSn0`  
**Vault Unseal Key**: `WrGSi8jFonoRnIzAEKtHehTu/DIR2KTMZVeKGcepiBY=`

> [!IMPORTANT]
> These credentials are saved in `vault-keys.json`. Keep this file secure!

## Step 1: Configure Keycloak (Do this in Keycloak UI)

### 1.1 Create Vault Realm

1. In Keycloak UI (http://localhost:8080), click realm dropdown (top-left)
2. Click **Create Realm**
3. **Realm name**: `vault`
4. Click **Create**

### 1.2 Create OIDC Client for Vault

1. In the `vault` realm, go to **Clients** → **Create client**
2. **General Settings**:
   - **Client type**: `OpenID Connect`
   - **Client ID**: `vault`
   - Click **Next**

3. **Capability config**:
   - **Client authentication**: Toggle **ON**
   - **Authorization**: Toggle **OFF**
   - **Authentication flow**: Check only:
     - ✅ Standard flow
     - ✅ Direct access grants
   - Click **Next**

4. **Login settings**:
   - **Root URL**: `http://localhost:8200`
   - **Valid redirect URIs**: 
     - `http://localhost:8200/ui/vault/auth/oidc/oidc/callback`
     - `http://localhost:8250/oidc/callback`
   - **Valid post logout redirect URIs**: `http://localhost:8200`
   - **Web origins**: `+`
   - Click **Save**

5. Go to **Credentials** tab
6. **Copy the Client Secret** - you'll need this for Vault configuration

### 1.3 Create Vault Admin Group

1. Go to **Groups** → **Create group**
2. **Name**: `vault-admins`
3. Click **Create**

### 1.4 Add Admin User to Group

1. Go to **Users** → Find and click `admin` user
2. Go to **Groups** tab
3. Click **Join Group**
4. Select `vault-admins`
5. Click **Join**

### 1.5 Configure Group Claim in Client Scope

1. Go to **Clients** → `vault` → **Client scopes** tab
2. Click on `vault-dedicated` scope
3. Go to **Mappers** tab → **Add mapper** → **By configuration**
4. Select **Group Membership**
5. Configure:
   - **Name**: `groups`
   - **Token Claim Name**: `groups`
   - **Full group path**: Toggle **OFF**
   - **Add to ID token**: Toggle **ON**
   - **Add to access token**: Toggle **ON**
   - **Add to userinfo**: Toggle **ON**
6. Click **Save**

## Step 2: Get Keycloak OIDC Discovery URL

The OIDC discovery URL is:
```
http://keycloak-service.operators.svc.cluster.local:8080/realms/vault
```

For external access (from Vault pod):
```
http://keycloak-service.operators.svc.cluster.local:8080/realms/vault
```

## Step 3: Configure Vault OIDC (Run these commands)

After completing Keycloak configuration, run the Vault configuration script:

```bash
# Set environment variables
export VAULT_ADDR='http://localhost:8200'
export VAULT_TOKEN='hvs.qHocdq4yjXI53ehNvjHvxSn0'
export KEYCLOAK_CLIENT_SECRET='<paste-client-secret-from-keycloak>'

# The configuration script will be provided next
```

## Next Steps

1. ✅ Complete Keycloak configuration (Steps 1.1 - 1.5)
2. ✅ Copy the client secret from Keycloak
3. ✅ Run the Vault configuration script (will be provided)
4. ✅ Test OIDC login to Vault
