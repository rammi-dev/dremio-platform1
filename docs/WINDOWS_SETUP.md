# Windows-Specific Setup for Vault OIDC

When accessing Vault from a Windows browser, you need to configure your hosts file so that Windows can resolve the Keycloak service DNS name.

---

## Why This Is Needed

During OIDC authentication, Vault redirects your browser to:
```
http://keycloak-service.operators.svc.cluster.local:8080/realms/vault/...
```

This is the internal Kubernetes DNS name. Your Windows machine doesn't know how to resolve this, so you need to map it to `localhost` (where the port-forward is running).

---

## Step-by-Step Instructions

### 1. Open Notepad as Administrator

- Press `Windows + S` to open search
- Type `notepad`
- **Right-click** on Notepad
- Select **"Run as administrator"**
- Click **Yes** when prompted

### 2. Open the Hosts File

In Notepad:
- Click **File** → **Open**
- Navigate to: `C:\Windows\System32\drivers\etc`
- Change file filter from "Text Documents (*.txt)" to **"All Files (*.*)"**
- Select the file named `hosts`
- Click **Open**

### 3. Add the Entry

At the end of the file, add this line:

```
127.0.0.1 keycloak-service.operators.svc.cluster.local
```

### 4. Save the File

- Click **File** → **Save**
- Close Notepad

### 5. Verify the Change

Open Command Prompt and run:

```cmd
ping keycloak-service.operators.svc.cluster.local
```

You should see responses from `127.0.0.1`.

---

## Complete Hosts File Example

Your hosts file should look something like this:

```
# Copyright (c) 1993-2009 Microsoft Corp.
#
# This is a sample HOSTS file used by Microsoft TCP/IP for Windows.
#
# This file contains the mappings of IP addresses to host names. Each
# entry should be kept on an individual line. The IP address should
# be placed in the first column followed by the corresponding host name.
# The IP address and the host name should be separated by at least one
# space.
#
# Additionally, comments (such as these) may be inserted on individual
# lines or following the machine name denoted by a '#' symbol.
#
# For example:
#
#      102.54.94.97     rhino.acme.com          # source server
#       38.25.63.10     x.acme.com              # x client host

# localhost name resolution is handled within DNS itself.
#	127.0.0.1       localhost
#	::1             localhost

# Keycloak for Vault OIDC
127.0.0.1 keycloak-service.operators.svc.cluster.local
```

---

## Now Try Vault Login Again

1. Ensure port-forwards are running:
   ```bash
   kubectl port-forward -n operators svc/keycloak-service 8080:8080 --address=0.0.0.0 &
   kubectl port-forward -n vault svc/vault-ui 8200:8200 --address=0.0.0.0 &
   ```

2. Open browser: http://localhost:8200

3. Select Method: **OIDC**

4. Click **"Sign in with OIDC Provider"**

5. You should now be redirected to Keycloak successfully!

6. Login with:
   - Username: `admin`
   - Password: `admin`

7. You'll be redirected back to Vault with admin access

---

## Troubleshooting

### Still Getting DNS Error?

1. **Flush DNS cache**:
   ```cmd
   ipconfig /flushdns
   ```

2. **Restart browser** completely (close all windows)

3. **Check hosts file was saved correctly**:
   ```cmd
   type C:\Windows\System32\drivers\etc\hosts
   ```

### Alternative: Use 127.0.0.1 Instead

If you don't want to modify the hosts file, you can access Keycloak directly:

1. Open http://127.0.0.1:8080 in your browser
2. This confirms Keycloak is accessible
3. But OIDC login from Vault will still require the hosts file entry

---

## Removing the Entry Later

When you're done, you can remove the line from the hosts file:

1. Open Notepad as Administrator again
2. Open `C:\Windows\System32\drivers\etc\hosts`
3. Delete the line with `keycloak-service.operators.svc.cluster.local`
4. Save the file
