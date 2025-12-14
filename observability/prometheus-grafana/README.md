# Prometheus + Grafana

This directory contains the Prometheus and Grafana configuration for monitoring the automation-k8s-stack.

## Overview

The kube-prometheus-stack Helm chart provides a complete monitoring solution including:

- **Prometheus** - Metrics collection and storage
- **Grafana** - Visualization and dashboards
- **kube-state-metrics** - Kubernetes state metrics
- **node-exporter** - Node-level metrics
- **Prometheus Operator** - Kubernetes-native Prometheus management

## Architecture

```
                                   ┌─────────────────┐
                                   │     Grafana     │
                                   │  (Dashboards)   │
                                   └────────┬────────┘
                                            │
                                            ▼
┌──────────────┐    ┌───────────────┐    ┌─────────────────┐
│   Istiod     │───▶│   Prometheus  │◀───│ kube-state-     │
│  (metrics)   │    │   (storage)   │    │   metrics       │
└──────────────┘    └───────┬───────┘    └─────────────────┘
                            │
        ┌───────────────────┼───────────────────┐
        │                   │                   │
        ▼                   ▼                   ▼
┌──────────────┐    ┌──────────────┐    ┌──────────────┐
│    Envoy     │    │ node-exporter│    │  Kubernetes  │
│   Sidecars   │    │  (per node)  │    │     API      │
└──────────────┘    └──────────────┘    └──────────────┘
```

## Prerequisites

- Running k3d cluster (`make cluster-up`)
- Istio service mesh (`make istio-up`)
- cert-manager for TLS (`make cert-manager-up`)
- Ingress gateway configured (`make ingress-up`)
- Helm 3.x installed

## Installation

```bash
# Install Prometheus + Grafana (idempotent)
make prometheus-grafana-up

# Check status
make prometheus-grafana-status

# Uninstall
make prometheus-grafana-down
```

## Access URLs

| Service | URL | Credentials |
|---------|-----|-------------|
| Grafana | https://grafana.localhost:8443 | admin / admin |
| Prometheus | https://prometheus.localhost:8443 | (none) |

## Directory Structure

```
observability/prometheus-grafana/
├── README.md                              # This file
├── values.yaml                            # kube-prometheus-stack Helm values
└── resources/
    ├── namespace.yaml                     # observability namespace
    ├── servicemonitor-istio.yaml          # ServiceMonitor for Istiod
    ├── podmonitor-envoy.yaml              # PodMonitor for Envoy sidecars
    ├── virtualservice-grafana.yaml        # Ingress for Grafana
    └── virtualservice-prometheus.yaml     # Ingress for Prometheus
```

## Configuration

### k3d Optimizations

The configuration is optimized for local k3d development:

| Setting | Value | Reason |
|---------|-------|--------|
| Prometheus retention | 24h | Short retention for local dev |
| Prometheus storage | Ephemeral | No persistent volume needed |
| Grafana anonymous access | Enabled (Viewer) | Easy local access |
| Alertmanager | Disabled | Enabled in Phase 3.4 |
| etcd monitoring | Disabled | k3d/k3s uses SQLite |
| Resource requests | Minimal | Suitable for local dev |

### Namespace

The `observability` namespace does NOT have Istio sidecar injection enabled. This allows Prometheus to scrape metrics from meshed workloads without mTLS complexity.

### ServiceMonitor Discovery

Prometheus is configured to discover ServiceMonitors and PodMonitors across ALL namespaces:

```yaml
serviceMonitorSelectorNilUsesHelmValues: false
podMonitorSelectorNilUsesHelmValues: false
```

## Istio Metrics

The stack includes:

1. **ServiceMonitor for Istiod** - Scrapes control plane metrics from port 15014
2. **PodMonitor for Envoy** - Scrapes sidecar proxy metrics from all meshed pods

### Available Istio Metrics

| Metric | Description |
|--------|-------------|
| `istio_requests_total` | Total number of requests |
| `istio_request_duration_milliseconds` | Request latency |
| `istio_tcp_connections_opened_total` | TCP connections opened |
| `istio_tcp_connections_closed_total` | TCP connections closed |

## Adding Custom ServiceMonitors

To monitor additional services, create a ServiceMonitor:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: my-app-monitor
  namespace: my-namespace
  labels:
    app.kubernetes.io/part-of: kube-prometheus-stack
spec:
  selector:
    matchLabels:
      app: my-app
  endpoints:
    - port: metrics
      interval: 30s
```

## Troubleshooting

### Check Prometheus Status

```bash
# Check pods
kubectl get pods -n observability

# Check Prometheus targets
kubectl port-forward svc/prometheus-kube-prometheus-prometheus 9090:9090 -n observability
# Then open http://localhost:9090/targets
```

### Check Grafana

```bash
# Check Grafana pod
kubectl logs -n observability -l app.kubernetes.io/name=grafana

# Verify VirtualService
kubectl get virtualservice grafana -n observability
```

### No Metrics from Istio

1. Verify Istiod is running:
   ```bash
   kubectl get pods -n istio-system
   ```

2. Check ServiceMonitor:
   ```bash
   kubectl get servicemonitor -n observability
   ```

3. Verify Prometheus can reach Istiod:
   ```bash
   kubectl port-forward svc/prometheus-kube-prometheus-prometheus 9090:9090 -n observability
   # Check targets at http://localhost:9090/targets
   ```

### Grafana Not Accessible

1. Check Gateway certificate:
   ```bash
   kubectl get certificate -n istio-ingress
   ```

2. Check VirtualService:
   ```bash
   kubectl describe virtualservice grafana -n observability
   ```

3. Check ingress gateway:
   ```bash
   kubectl get pods -n istio-ingress
   ```

## Production Considerations

For production (k3s), consider:

- **Persistent Storage**: Enable persistent volumes for Prometheus data
- **Retention**: Increase retention (e.g., 15d or 30d)
- **Alertmanager**: Enable and configure alerting rules
- **Resources**: Increase CPU/memory limits
- **High Availability**: Enable Prometheus replicas
- **Remote Write**: Configure remote storage (e.g., Thanos, Cortex)

Example production values:

```yaml
prometheus:
  prometheusSpec:
    retention: 15d
    retentionSize: 50GB
    storageSpec:
      volumeClaimTemplate:
        spec:
          storageClassName: nas
          resources:
            requests:
              storage: 50Gi
    replicas: 2
```

## Version

kube-prometheus-stack version: **80.4.1**

To upgrade, update the `CHART_VERSION` variable in `scripts/prometheus-grafana-up.sh`.

## References

- [kube-prometheus-stack Chart](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack)
- [Prometheus Documentation](https://prometheus.io/docs/)
- [Grafana Documentation](https://grafana.com/docs/)
- [Istio Prometheus Integration](https://istio.io/latest/docs/ops/integrations/prometheus/)
- [ServiceMonitor Reference](https://prometheus-operator.dev/docs/operator/api/#monitoring.coreos.com/v1.ServiceMonitor)
