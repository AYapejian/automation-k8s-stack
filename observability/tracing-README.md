# Distributed Tracing

This directory contains the distributed tracing stack configuration for the automation-k8s-stack.

## Components

- **OpenTelemetry Collector** - Receives traces from Istio, fans out to backends
- **Jaeger** - Trace visualization UI with in-memory storage
- **Tempo** - Grafana-native trace storage with Minio S3 backend

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           Istio Mesh                                    │
│                                                                         │
│  ┌────────────┐     ┌────────────┐     ┌────────────┐                  │
│  │   Pod A    │     │   Pod B    │     │   Pod C    │                  │
│  │ ┌────────┐ │     │ ┌────────┐ │     │ ┌────────┐ │                  │
│  │ │ Envoy  │─┼─────┼─│ Envoy  │─┼─────┼─│ Envoy  │ │                  │
│  │ │ Proxy  │ │     │ │ Proxy  │ │     │ │ Proxy  │ │                  │
│  │ └────┬───┘ │     │ └────┬───┘ │     │ └────┬───┘ │                  │
│  └──────┼─────┘     └──────┼─────┘     └──────┼─────┘                  │
│         │                  │                  │                         │
│         └──────────────────┼──────────────────┘                         │
│                            │ OTLP (4317)                                │
│                            ▼                                            │
│                  ┌─────────────────┐                                    │
│                  │ OTel Collector  │                                    │
│                  └────────┬────────┘                                    │
│                           │                                             │
│              ┌────────────┴────────────┐                                │
│              │                         │                                │
│              ▼                         ▼                                │
│     ┌─────────────────┐      ┌─────────────────┐                       │
│     │     Jaeger      │      │     Tempo       │──────► Minio (S3)     │
│     │   (in-memory)   │      │                 │                        │
│     └────────┬────────┘      └────────┬────────┘                       │
│              │                        │                                 │
└──────────────┼────────────────────────┼─────────────────────────────────┘
               │                        │
               ▼                        ▼
        Jaeger UI              Grafana (Tempo datasource)
```

## Prerequisites

- Running k3d cluster (`make cluster-up`)
- Istio service mesh (`make istio-up`)
- Minio object storage (`make minio-up`)
- Prometheus + Grafana (`make prometheus-grafana-up`)

## Installation

```bash
# Install complete tracing stack
make tracing-up

# Check status
make tracing-status

# Uninstall
make tracing-down
```

## Access

| UI | URL | Notes |
|----|-----|-------|
| Jaeger | https://jaeger.localhost:8443 | Direct trace query UI |
| Tempo | https://grafana.localhost:8443 → Explore → Tempo | Grafana-integrated traces |

## Configuration

### OpenTelemetry Collector

| Setting | Value |
|---------|-------|
| Receivers | OTLP gRPC (4317), OTLP HTTP (4318) |
| Exporters | Jaeger (OTLP), Tempo (OTLP) |
| Processors | Batch, Memory Limiter |

### Jaeger

| Setting | Value | Reason |
|---------|-------|--------|
| Mode | All-in-one | Simple for k3d |
| Storage | In-memory | No persistence needed for dev |
| Max Traces | 50,000 | Sufficient for local testing |

### Tempo

| Setting | Value | Reason |
|---------|-------|--------|
| Mode | Single binary | Simple for k3d |
| Storage | Minio S3 | Persistent trace storage |
| Bucket | tempo-traces | S3 bucket in Minio |
| Retention | 24h | Short for dev environment |

## Querying Traces

### In Jaeger UI

1. Open https://jaeger.localhost:8443
2. Select a service from the dropdown
3. Click "Find Traces"
4. Click on a trace to see details

### In Grafana (Tempo)

1. Open https://grafana.localhost:8443
2. Click **Explore** (compass icon)
3. Select **Tempo** datasource
4. Use TraceQL queries or search by service/span

## Generating Test Traces

Generate traffic through the mesh to create traces:

```bash
# Deploy sample app
make sample-app-up

# Generate traffic
for i in {1..10}; do
  curl -sk -H "Host: httpbin.localhost" https://localhost:8443/headers
  sleep 1
done
```

## Troubleshooting

### No traces appearing

1. Check OTel Collector is receiving traces:
   ```bash
   kubectl logs -n observability deployment/otel-collector-opentelemetry-collector
   ```

2. Check Istio telemetry is configured:
   ```bash
   kubectl get telemetry -n istio-system
   kubectl describe telemetry mesh-default -n istio-system
   ```

3. Verify pods have sidecars:
   ```bash
   kubectl get pods -n <namespace> -o jsonpath='{.items[*].spec.containers[*].name}'
   ```

### Jaeger UI shows no services

1. Check Jaeger pod:
   ```bash
   kubectl logs -n observability -l app.kubernetes.io/name=jaeger
   ```

2. Verify OTLP endpoint:
   ```bash
   kubectl get svc -n observability | grep jaeger
   ```

### Tempo not receiving traces

1. Check Tempo logs:
   ```bash
   kubectl logs -n observability -l app.kubernetes.io/name=tempo
   ```

2. Verify Minio connectivity:
   ```bash
   kubectl run tempo-test --rm -i --image=minio/mc \
     --env="MC_HOST_myminio=http://minioadmin:minioadmin123@minio.minio.svc.cluster.local:9000" \
     -- mc ls myminio/tempo-traces/
   ```

## Production Considerations

- **Jaeger**: Replace with distributed deployment with persistent storage
- **Tempo**: Use distributed mode with higher retention
- **Sampling**: Reduce from 100% to 1-10%
- **OTel Collector**: Enable batching and queuing for reliability
