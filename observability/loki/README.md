# Loki + Promtail

This directory contains the Loki and Promtail configuration for log aggregation in the automation-k8s-stack.

## Overview

- **Loki** - Log aggregation system (like Prometheus but for logs)
- **Promtail** - Agent that ships logs to Loki (DaemonSet on all nodes)

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                         Nodes                                │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐          │
│  │  Promtail   │  │  Promtail   │  │  Promtail   │          │
│  │  (agent)    │  │  (agent)    │  │  (agent)    │          │
│  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘          │
│         │                │                │                  │
│         └────────────────┼────────────────┘                  │
│                          │                                   │
│                          ▼                                   │
│                    ┌───────────┐      ┌───────────┐         │
│                    │   Loki    │──────│   Minio   │         │
│                    │ (query)   │      │  (S3 API) │         │
│                    └─────┬─────┘      └───────────┘         │
│                          │                                   │
└──────────────────────────┼───────────────────────────────────┘
                           │
                           ▼
                    ┌───────────┐
                    │  Grafana  │
                    │  (query)  │
                    └───────────┘
```

## Prerequisites

- Running k3d cluster (`make cluster-up`)
- Minio object storage (`make minio-up`)
- Prometheus + Grafana installed (`make prometheus-grafana-up`)

## Installation

```bash
# Install Loki + Promtail (idempotent)
make loki-up

# Check status
make loki-status

# Uninstall
make loki-down
```

## Directory Structure

```
observability/loki/
├── README.md                       # This file
├── values.yaml                     # Loki-stack Helm values (Loki + Promtail)
└── resources/
    ├── grafana-datasource.yaml     # Loki datasource for Grafana
    └── minio-credentials.yaml      # Minio credentials for S3 storage
```

## Configuration

### k3d Configuration

| Setting | Value | Reason |
|---------|-------|--------|
| Deployment mode | SingleBinary | Simple for local dev |
| Retention | 24h | Short retention for local dev |
| Storage | Minio S3 | Full integration testing |
| Bucket | loki-chunks | S3-compatible storage |
| Auth | Disabled | Local dev only |

### Log Collection

Promtail collects logs from:
- All pod containers via `/var/log/pods`
- Adds Kubernetes metadata labels (namespace, pod, container)
- Adds Istio labels when present (app, version)

## Querying Logs

### In Grafana

1. Open https://grafana.localhost:8443
2. Click **Explore** (compass icon)
3. Select **Loki** datasource
4. Use LogQL queries

### Example Queries

```logql
# All logs from kube-system namespace
{namespace="kube-system"}

# Istio proxy logs
{container="istio-proxy"}

# Logs from a specific pod
{pod="my-pod-abc123"}

# Filter by content
{namespace="default"} |= "error"

# JSON parsing (for Istio access logs)
{container="istio-proxy"} | json | response_code >= 400
```

## Istio Access Logs

Istio is configured to output access logs to stdout in JSON format. These are collected by Promtail and queryable in Loki.

Example Istio access log query:
```logql
{container="istio-proxy"}
  | json
  | upstream_cluster != ""
  | line_format "{{.method}} {{.path}} {{.response_code}}"
```

## Troubleshooting

### Check Loki Status

```bash
# Pods
kubectl get pods -n observability -l app.kubernetes.io/name=loki

# Logs
kubectl logs -n observability -l app.kubernetes.io/name=loki

# Ready endpoint
kubectl port-forward svc/loki 3100:3100 -n observability
curl http://localhost:3100/ready
```

### Check Promtail Status

```bash
# Pods (should be one per node)
kubectl get pods -n observability -l app.kubernetes.io/name=promtail

# Logs
kubectl logs -n observability -l app.kubernetes.io/name=promtail

# Targets
kubectl port-forward svc/promtail 3101:3101 -n observability
curl http://localhost:3101/targets
```

### Loki Datasource Not Showing in Grafana

1. Check the ConfigMap exists:
   ```bash
   kubectl get configmap grafana-datasource-loki -n observability
   ```

2. Restart Grafana:
   ```bash
   kubectl rollout restart deployment/prometheus-grafana -n observability
   ```

3. Check Grafana sidecar logs:
   ```bash
   kubectl logs -n observability -l app.kubernetes.io/name=grafana -c grafana-sc-datasources
   ```

## Minio Storage

Loki is configured to use Minio for S3-compatible storage:

- **Bucket**: `loki-chunks`
- **Endpoint**: `minio.minio.svc.cluster.local:9000`
- **Credentials**: Stored in `loki-minio-credentials` secret

To verify storage is working:
```bash
# Check if objects exist in the bucket
kubectl run minio-ls --rm -i --image=minio/mc:latest \
  --env="MC_HOST_myminio=http://minioadmin:minioadmin123@minio.minio.svc.cluster.local:9000" \
  -- mc ls myminio/loki-chunks/
```

## Production Considerations

For production (k3s), consider:

- **Distributed Mode**: Use read/write/backend separation
- **Retention**: Increase to 7-30 days
- **Resources**: Increase CPU/memory limits
- **Compaction**: Enable chunk compaction
- **Sealed Secrets**: Convert credentials to SealedSecrets

## Versions

- Loki Stack: **2.10.3** (bundled Loki + Promtail)

## References

- [Loki Documentation](https://grafana.com/docs/loki/latest/)
- [Promtail Documentation](https://grafana.com/docs/loki/latest/send-data/promtail/)
- [LogQL Reference](https://grafana.com/docs/loki/latest/query/)
- [Loki Helm Chart](https://github.com/grafana/loki/tree/main/production/helm/loki)
