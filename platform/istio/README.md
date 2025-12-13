# Istio Service Mesh

This directory contains the Istio service mesh configuration for the automation-k8s-stack.

## Overview

Istio provides:
- **mTLS**: Automatic mutual TLS encryption for all service-to-service communication
- **Traffic Management**: Load balancing, routing, and traffic policies
- **Observability**: Metrics, logs, and distributed tracing integration
- **Security**: Authorization policies and access control

## Prerequisites

- Running k3d cluster (`make cluster-up`)
- Helm 3.x installed
- kubectl configured to access the cluster

## Installation

```bash
# Install Istio (idempotent)
make istio-up

# Check status
make istio-status

# Uninstall
make istio-down
```

## Directory Structure

```
platform/istio/
├── README.md                     # This file
├── base/values.yaml              # istio/base chart (CRDs)
├── istiod/values.yaml            # istio/istiod chart (control plane)
├── gateway/values.yaml           # istio/gateway chart (ingress)
└── resources/
    ├── peer-authentication.yaml  # Mesh-wide STRICT mTLS
    ├── authorization-policy.yaml # Prometheus scrape policy
    └── telemetry.yaml            # Access logging and metrics
```

## Helm Charts

| Chart | Namespace | Description |
|-------|-----------|-------------|
| istio/base | istio-system | CRDs and cluster-wide resources |
| istio/istiod | istio-system | Control plane (Pilot) |
| istio/gateway | istio-ingress | Ingress gateway |

## Enabling Sidecar Injection

To enable automatic sidecar injection for a namespace:

```bash
kubectl label namespace <namespace> istio-injection=enabled
```

To disable:

```bash
kubectl label namespace <namespace> istio-injection-
```

To check which namespaces have injection enabled:

```bash
kubectl get namespaces -l istio-injection=enabled
```

## Security Configuration

### mTLS Mode

The mesh is configured with **STRICT** mTLS mode, meaning all service-to-service communication must use mutual TLS. This is enforced by the `PeerAuthentication` resource in `resources/peer-authentication.yaml`.

To verify mTLS is working:

```bash
# Check PeerAuthentication policy
kubectl get peerauthentication -n istio-system

# Check SSL connections on a meshed pod
kubectl exec -n <namespace> <pod> -c istio-proxy -- \
  pilot-agent request GET stats | grep ssl
```

### Authorization Policies

The base `AuthorizationPolicy` allows Prometheus to scrape metrics from all meshed workloads. Application-specific policies should be added in each namespace.

## Telemetry

### Access Logging

Access logs are written to stdout in JSON format. They will be collected by Loki when the observability stack is deployed (Phase 3.2).

### Metrics

Istio exports Prometheus metrics from the sidecar proxies. Metrics are available on port 15020 of each meshed pod.

### Tracing

OpenTelemetry tracing is configured but not active until the OTel Collector is deployed (Phase 3.3). To enable tracing, uncomment the tracing section in `resources/telemetry.yaml`.

## Troubleshooting

### Check Istio Control Plane

```bash
# View istiod logs
kubectl logs -n istio-system deployment/istiod

# Check istiod health
kubectl get deployment istiod -n istio-system
```

### Check Sidecar Injection

```bash
# Verify pod has 2 containers (app + istio-proxy)
kubectl get pods -n <namespace> -o jsonpath='{.items[*].spec.containers[*].name}'

# Check istio-proxy logs
kubectl logs -n <namespace> <pod> -c istio-proxy
```

### Check mTLS Status

```bash
# Verify connection is using TLS
kubectl exec -n <namespace> <pod> -c istio-proxy -- \
  curl -s localhost:15000/config_dump | grep -A5 "transport_socket"
```

### Ingress Gateway

```bash
# Check gateway pods
kubectl get pods -n istio-ingress

# Check gateway service
kubectl get svc -n istio-ingress

# View gateway logs
kubectl logs -n istio-ingress deployment/istio-ingress
```

## Version

Istio version: **1.24.0**

To upgrade, update the `ISTIO_VERSION` variable in `scripts/istio-up.sh` and run `make istio-up`.

## References

- [Istio Documentation](https://istio.io/latest/docs/)
- [Istio Helm Installation](https://istio.io/latest/docs/setup/install/helm/)
- [PeerAuthentication Reference](https://istio.io/latest/docs/reference/config/security/peer_authentication/)
- [Telemetry API Reference](https://istio.io/latest/docs/tasks/observability/telemetry/)
