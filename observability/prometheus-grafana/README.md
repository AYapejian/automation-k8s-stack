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
    ├── virtualservice-prometheus.yaml     # Ingress for Prometheus
    ├── prometheus-rules.yaml              # PrometheusRules for alerting
    └── dashboards/
        ├── cluster-overview.yaml          # Cluster health dashboard
        ├── istio-mesh.yaml                # Istio RED metrics dashboard
        └── namespace-resources.yaml       # Per-namespace resource dashboard
```

## Configuration

### k3d Optimizations

The configuration is optimized for local k3d development:

| Setting | Value | Reason |
|---------|-------|--------|
| Prometheus retention | 24h | Short retention for local dev |
| Prometheus storage | Ephemeral | No persistent volume needed |
| Grafana anonymous access | Enabled (Viewer) | Easy local access |
| Alertmanager | Enabled | For alert evaluation |
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

## Dashboards

The stack includes pre-configured Grafana dashboards deployed as ConfigMaps:

| Dashboard | Description |
|-----------|-------------|
| Cluster Overview | Node status, CPU/memory usage, pod counts |
| Istio Mesh | RED metrics (Rate, Errors, Duration) for service mesh traffic |
| Namespace Resources | Per-namespace CPU, memory, and pod status |

Dashboards are automatically discovered by Grafana's sidecar via the `grafana_dashboard: "1"` label.

### Adding Custom Dashboards

Create a ConfigMap with the dashboard JSON:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-my-app
  namespace: observability
  labels:
    grafana_dashboard: "1"
data:
  my-app.json: |
    {
      "title": "My App Dashboard",
      ...
    }
```

## Alerting

PrometheusRules define alerting conditions that Prometheus evaluates continuously.

### Included Alert Rules

| Alert | Severity | Description |
|-------|----------|-------------|
| PodCrashLooping | warning | Pod has restarted >3 times in 15 minutes |
| PodNotReady | warning | Pod has been pending/unknown for >15 minutes |
| ContainerOOMKilled | warning | Container was terminated due to OOM |
| NodeNotReady | critical | Node has been not ready for >5 minutes |
| NodeHighCPU | warning | Node CPU usage >90% for >15 minutes |
| NodeHighMemory | warning | Node memory usage >90% for >15 minutes |
| PVCNearlyFull | warning | PVC is >85% full |
| PVCFull | critical | PVC is >95% full |
| HighErrorRate | warning | Service has >5% error rate |
| HighLatency | warning | Service P99 latency >1000ms |
| DeploymentReplicasMismatch | warning | Deployment has unavailable replicas |
| CertificateExpiringSoon | warning | Certificate expires in <7 days |

### Viewing Alerts

1. Open Prometheus: https://prometheus.localhost:8443
2. Go to **Alerts** tab to see active and pending alerts
3. Or use Grafana's built-in alerting view

### Adding Custom Alerts

Create a PrometheusRule resource:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: my-app-alerts
  namespace: observability
  labels:
    release: kube-prometheus-stack
spec:
  groups:
    - name: my-app
      rules:
        - alert: MyAppDown
          expr: up{job="my-app"} == 0
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "My App is down"
```

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
