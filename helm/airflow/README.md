# Apache Airflow

Apache Airflow deployment for workflow orchestration integrated with Keycloak authentication.

## Overview

This deployment provides:
- **Standalone Airflow** with LocalExecutor (suitable for testing/development)
- **PostgreSQL** backend for metadata
- **Keycloak Auth Manager** for SSO authentication
- **Role-based access** mapped to Keycloak groups

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Airflow Namespace                        │
├─────────────────────────────────────────────────────────────┤
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐  │
│  │  Webserver   │    │  Scheduler   │    │  Triggerer   │  │
│  │   (UI/API)   │    │              │    │              │  │
│  └──────┬───────┘    └──────┬───────┘    └──────────────┘  │
│         │                    │                              │
│         └────────┬───────────┘                              │
│                  ▼                                          │
│         ┌──────────────┐                                    │
│         │  PostgreSQL  │                                    │
│         │   (Metadata) │                                    │
│         └──────────────┘                                    │
└─────────────────────────────────────────────────────────────┘
          │
          │ OIDC
          ▼
┌─────────────────────┐
│      Keycloak       │
│  (Auth Provider)    │
└─────────────────────┘
```

## Prerequisites

Before deploying Airflow, ensure the following are running:

1. **Keycloak** - Identity provider (`./scripts/deploy-gke.sh`)
2. Port-forward to Keycloak active on `localhost:8080`

## Deployment

### Quick Start

```bash
# Deploy Airflow with Keycloak integration
./scripts/deploy-airflow-gke.sh
```

### Manual Deployment

```bash
# 1. Add Helm repo
helm repo add apache-airflow https://airflow.apache.org
helm repo update

# 2. Create namespace
kubectl create namespace airflow

# 3. Create Keycloak client secret
kubectl create secret generic airflow-keycloak-secret \
  --from-literal=client-secret="airflow-secret" \
  -n airflow

# 4. Deploy Airflow
helm install airflow apache-airflow/airflow \
  -n airflow \
  -f helm/airflow/values.yaml \
  --timeout 10m
```

## Access

| Service | URL | Port-Forward Command |
|---------|-----|---------------------|
| Airflow UI | http://localhost:8085 | `kubectl port-forward svc/airflow-webserver -n airflow 8085:8080` |

## Authentication

### Keycloak Auth Manager

Airflow uses the [Keycloak Auth Manager](https://airflow.apache.org/docs/apache-airflow-providers-keycloak/stable/auth-manager/index.html) for authentication and authorization.

**Configuration:**
- Auth Manager: `airflow.providers.keycloak.auth_manager.keycloak_auth_manager.KeycloakAuthManager`
- Client ID: `airflow`
- Realm: `vault`
- Server URL: `http://keycloak-service.operators.svc.cluster.local:8080`

### Role Mapping

| Keycloak Group | Airflow Role | Permissions |
|----------------|--------------|-------------|
| `airflow-admin` | Admin | Full access to all features |
| `data-engineers` | Editor | Create, edit, execute DAGs; view logs |
| `data-scientists` | Viewer | Read-only access to DAGs and logs |

### User Assignments

| User | Keycloak Group | Airflow Role |
|------|----------------|--------------|
| `admin` | airflow-admin | Admin |
| `jupyter-admin` | data-engineers | Editor |
| `jupyter-ds` | data-scientists | Viewer |

### Initializing Keycloak Permissions

After Airflow is running, initialize the Keycloak permissions:

```bash
kubectl exec -it deploy/airflow-webserver -n airflow -- \
  airflow keycloak-auth-manager create-all \
    --username admin \
    --password admin \
    --user-realm vault
```

This command creates:
- Scopes for permission types
- Resources for Airflow entities
- Permissions mapping groups to access levels

## Configuration

### Helm Values

Key configuration options in `helm/airflow/values.yaml`:

| Setting | Value | Description |
|---------|-------|-------------|
| `executor` | LocalExecutor | Single-node execution |
| `postgresql.enabled` | true | Use embedded PostgreSQL |
| `workers.enabled` | false | No Celery workers |
| `triggerer.enabled` | true | Enable async triggers |

### Environment Variables

The Keycloak Auth Manager is configured via environment variables:

```yaml
env:
  - name: AIRFLOW__CORE__AUTH_MANAGER
    value: "airflow.providers.keycloak.auth_manager.keycloak_auth_manager.KeycloakAuthManager"
  - name: AIRFLOW__KEYCLOAK_AUTH_MANAGER__CLIENT_ID
    value: "airflow"
  - name: AIRFLOW__KEYCLOAK_AUTH_MANAGER__REALM
    value: "vault"
  - name: AIRFLOW__KEYCLOAK_AUTH_MANAGER__SERVER_URL
    value: "http://keycloak-service.operators.svc.cluster.local:8080"
```

## DAGs

### DAG Storage

DAGs are stored in a persistent volume mounted at `/opt/airflow/dags`.

### Adding DAGs

1. **Copy to pod:**
   ```bash
   kubectl cp my_dag.py airflow/airflow-webserver-xxx:/opt/airflow/dags/
   ```

2. **Via ConfigMap:**
   ```bash
   kubectl create configmap airflow-dags --from-file=dags/ -n airflow
   ```

3. **Git-sync** (optional):
   Enable in `values.yaml`:
   ```yaml
   gitSync:
     enabled: true
     repo: "https://github.com/your-org/airflow-dags.git"
   ```

## Troubleshooting

### Check Pod Status

```bash
kubectl get pods -n airflow
```

### View Logs

```bash
# Webserver logs
kubectl logs -f deploy/airflow-webserver -n airflow

# Scheduler logs
kubectl logs -f deploy/airflow-scheduler -n airflow
```

### Keycloak Connection Issues

1. Verify Keycloak is accessible from Airflow:
   ```bash
   kubectl exec -it deploy/airflow-webserver -n airflow -- \
     curl -s http://keycloak-service.operators.svc.cluster.local:8080/realms/vault
   ```

2. Check client secret:
   ```bash
   kubectl get secret airflow-keycloak-secret -n airflow -o yaml
   ```

### Database Issues

```bash
# Connect to PostgreSQL
kubectl exec -it airflow-postgresql-0 -n airflow -- psql -U airflow -d airflow

# Check Airflow database
\dt  # List tables
```

## Scaling

For production workloads, consider:

1. **Switch to CeleryExecutor:**
   ```yaml
   executor: "CeleryExecutor"
   workers:
     enabled: true
     replicas: 3
   redis:
     enabled: true
   ```

2. **Use external PostgreSQL:**
   ```yaml
   postgresql:
     enabled: false
   data:
     metadataConnection:
       host: external-postgres.example.com
   ```

## Cleanup

```bash
# Uninstall Airflow
helm uninstall airflow -n airflow

# Delete namespace
kubectl delete namespace airflow

# Clean up Keycloak client (optional)
# Done via Keycloak admin console
```

## References

- [Apache Airflow Documentation](https://airflow.apache.org/docs/)
- [Airflow Helm Chart](https://airflow.apache.org/docs/helm-chart/stable/index.html)
- [Keycloak Auth Manager](https://airflow.apache.org/docs/apache-airflow-providers-keycloak/stable/auth-manager/index.html)
- [Keycloak Provider Package](https://pypi.org/project/apache-airflow-providers-keycloak/)
