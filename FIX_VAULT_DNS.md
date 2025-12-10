# Fix: Vault OIDC Keycloak DNS Resolution

## Problem
Your Windows browser cannot resolve the Kubernetes internal DNS name:
`keycloak-service.operators.svc.cluster.local`

## Solution: Add to Windows Hosts File

### Step 1: Open Notepad as Administrator

1. Press **Windows key**
2. Type **"Notepad"**
3. **Right-click** on Notepad
4. Select **"Run as administrator"**

### Step 2: Open the Hosts File

1. In Notepad, click **File** → **Open**
2. Navigate to: `C:\Windows\System32\drivers\etc`
3. Change file type filter from "Text Documents (*.txt)" to **"All Files (*.*)"**
4. Select the file named **`hosts`** (no extension)
5. Click **Open**

### Step 3: Add the Entry

At the end of the file, add this line:

```
127.0.0.1 keycloak-service.operators.svc.cluster.local
```

### Step 4: Save and Close

1. Click **File** → **Save**
2. Close Notepad

### Step 5: Test Vault OIDC Login

1. Go to `http://localhost:8200` or `http://127.0.0.1:8200`
2. Select **Method: OIDC**
3. Click **"Sign in with OIDC Provider"**
4. You should now be redirected to Keycloak successfully!
5. Log in with:
   - Username: `admin`
   - Password: `admin`
6. You'll be redirected back to Vault with full admin access

## What This Does

- Maps the Kubernetes internal DNS name to `127.0.0.1` (localhost)
- Your browser can now resolve the name when Vault redirects you to Keycloak
- Since Keycloak is port-forwarded to localhost:8080, it will work correctly

## To Remove Later

If you want to remove this entry later, just delete the line from the hosts file.
