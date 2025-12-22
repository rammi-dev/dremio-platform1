# Spark Platform

Helm chart for deploying the Kubeflow Spark Operator with automated RBAC configuration.

## Quick Start

```bash
# Deploy operator and RBAC
./scripts/deploy-spark-operator.sh

# Deploy example SparkConnect server
kubectl apply -f helm/spark/examples/spark-connect-server.yaml
```

## Components

- **Spark Operator**: Manages Spark applications in Kubernetes (deployed to `operators` namespace)
- **RBAC**: Automated ServiceAccount and permissions for `jupyterhub-users` namespace
- **Examples**: Validated SparkConnect server configuration

## Important Notes

⚠️ **GKE Node Workaround**: Due to filesystem issues on current GKE nodes, the example configuration uses **requests-only** (no limits) to avoid `no space left on device` errors. See [README-detail.md](README-detail.md) for full technical explanation.

## Documentation

- [README-detail.md](README-detail.md) - Architecture, RBAC logic, and troubleshooting
- [examples/](examples/) - Validated application manifests
