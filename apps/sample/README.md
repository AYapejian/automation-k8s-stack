# Sample Applications

This directory contains sample applications for testing the platform infrastructure.

## httpbin

A lightweight HTTP request/response service for testing ingress, TLS, and service mesh functionality.

### Overview

[go-httpbin](https://github.com/mccutchen/go-httpbin) is a Go implementation of the classic httpbin service. It provides endpoints that return information about the incoming request, useful for debugging and testing.

### Prerequisites

- Running k3d cluster (`make cluster-up`)
- Istio service mesh (`make istio-up`)
- cert-manager (`make cert-manager-up`)
- Gateway configuration (`make ingress-up`)

### Installation

```bash
# Deploy httpbin (idempotent)
make sample-app-up

# Check status
make sample-app-status

# Remove
make sample-app-down
```

### Testing

```bash
# Test HTTPS endpoint
curl -sk https://localhost:8443/get -H 'Host: httpbin.localhost'

# Test HTTP redirect
curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/get -H 'Host: httpbin.localhost'
# Expected: 301

# Test specific endpoints
curl -sk https://localhost:8443/headers -H 'Host: httpbin.localhost'
curl -sk https://localhost:8443/status/200 -H 'Host: httpbin.localhost'
curl -sk https://localhost:8443/ip -H 'Host: httpbin.localhost'
```

### Useful Endpoints

| Endpoint | Description |
|----------|-------------|
| `/get` | Returns GET data including headers and args |
| `/post` | Returns POST data including body |
| `/headers` | Returns request headers |
| `/ip` | Returns origin IP |
| `/status/:code` | Returns the specified HTTP status code |
| `/delay/:n` | Delays response by n seconds |

### Architecture

```
Client Request
    │
    ▼
https://httpbin.localhost:8443
    │
    │  k3d port mapping (8443 -> 443)
    ▼
Istio Gateway (TLS termination)
    │
    │  VirtualService routing
    ▼
httpbin Service (ClusterIP)
    │
    ▼
httpbin Pod (with istio-proxy sidecar)
```

### Istio Integration

The httpbin deployment demonstrates:
- **Automatic sidecar injection**: Namespace labeled with `istio-injection=enabled`
- **mTLS**: All traffic to/from httpbin is encrypted
- **VirtualService routing**: Host-based routing from Gateway

### Files

```
apps/sample/httpbin/
├── namespace.yaml       # Namespace with istio-injection label
├── deployment.yaml      # go-httpbin deployment
├── service.yaml         # ClusterIP service
└── virtual-service.yaml # Routing from Gateway
```

### Troubleshooting

#### Pod Not Starting

```bash
# Check pod status
kubectl get pods -n ingress-sample
kubectl describe pod -l app=httpbin -n ingress-sample

# Check events
kubectl get events -n ingress-sample --sort-by='.lastTimestamp'
```

#### Sidecar Not Injected

```bash
# Verify namespace label
kubectl get namespace ingress-sample --show-labels

# Check Istio webhook
kubectl get mutatingwebhookconfiguration istio-sidecar-injector
```

#### Cannot Access via Ingress

```bash
# Check VirtualService
kubectl describe virtualservice httpbin -n ingress-sample

# Check Gateway
kubectl describe gateway main-gateway -n istio-ingress

# Check Gateway pod logs
kubectl logs -n istio-ingress deployment/istio-ingress
```
