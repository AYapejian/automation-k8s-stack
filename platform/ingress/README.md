# Istio Ingress Gateway Configuration

This directory contains the Istio Gateway and TLS certificate configuration for ingress traffic.

## Overview

The ingress configuration provides:
- **HTTPS Ingress**: TLS termination at the Gateway
- **HTTP Redirect**: Automatic redirect from HTTP to HTTPS
- **Shared Gateway**: Single Gateway for all applications
- **Automatic Certificates**: TLS certificates managed by cert-manager

## Architecture

```
External Request
    │
    ▼
localhost:8080 (HTTP) ──────────────────┐
    │                                    │
    │  k3d port mapping                  │
    ▼                                    │
Istio Gateway (port 80)                  │
    │                                    │
    │  httpsRedirect: true               │
    ▼                                    │
301 Redirect to HTTPS ◄──────────────────┘
    │
    ▼
localhost:8443 (HTTPS)
    │
    │  k3d port mapping
    ▼
Istio Gateway (port 443)
    │
    │  TLS termination (gateway-tls-secret)
    ▼
VirtualService routing
    │
    │  Host-based routing
    ▼
Application Service
```

## Prerequisites

- Running k3d cluster (`make cluster-up`)
- Istio service mesh (`make istio-up`)
- cert-manager with ClusterIssuer (`make cert-manager-up`)

## Installation

```bash
# Configure Gateway and TLS (idempotent)
make ingress-up

# Check status
make ingress-status

# Remove configuration
make ingress-down
```

## Directory Structure

```
platform/ingress/
├── README.md                    # This file
└── resources/
    ├── gateway.yaml             # Istio Gateway (HTTP redirect + HTTPS)
    └── certificate.yaml         # TLS certificate for *.localhost
```

## Gateway Configuration

The `main-gateway` handles all ingress traffic:

| Port | Protocol | Behavior |
|------|----------|----------|
| 80 | HTTP | Redirects to HTTPS (301) |
| 443 | HTTPS | TLS termination |

Hosts: `localhost`, `*.localhost`

## TLS Certificate

The Gateway uses a cert-manager Certificate for TLS:

- **Secret**: `gateway-tls-secret` in `istio-ingress` namespace
- **Issuer**: `automation-ca-issuer` (ClusterIssuer)
- **Validity**: 90 days
- **Renewal**: 15 days before expiry

Covered DNS names:
- `localhost`
- `*.localhost`
- Application-specific: `httpbin.localhost`, `grafana.localhost`, etc.

## Exposing Applications

To expose an application via the Gateway, create a VirtualService:

```yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: my-app
  namespace: my-namespace
spec:
  hosts:
    - "my-app.localhost"
  gateways:
    - istio-ingress/main-gateway
  http:
    - match:
        - uri:
            prefix: /
      route:
        - destination:
            host: my-app.my-namespace.svc.cluster.local
            port:
              number: 8080
```

The application will be accessible at:
- `http://my-app.localhost:8080` (redirects to HTTPS)
- `https://my-app.localhost:8443`

## Testing

```bash
# Test HTTP redirect
curl -s -o /dev/null -w "%{http_code}" http://localhost:8080 -H "Host: httpbin.localhost"
# Expected: 301

# Test HTTPS (use -k for self-signed cert)
curl -sk https://localhost:8443 -H "Host: httpbin.localhost"
```

## Troubleshooting

### Certificate Not Issued

```bash
# Check certificate status
kubectl describe certificate gateway-tls -n istio-ingress

# Check cert-manager logs
kubectl logs -n cert-manager deployment/cert-manager

# Check if ClusterIssuer is ready
kubectl get clusterissuer automation-ca-issuer
```

### Gateway Not Accepting Connections

```bash
# Check Gateway pods
kubectl get pods -n istio-ingress

# Check Gateway configuration
kubectl describe gateway main-gateway -n istio-ingress

# Check Gateway logs
kubectl logs -n istio-ingress deployment/istio-ingress
```

### TLS Errors

```bash
# Verify TLS secret exists
kubectl get secret gateway-tls-secret -n istio-ingress

# Check secret contents
kubectl get secret gateway-tls-secret -n istio-ingress -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -text -noout
```

## Production Considerations

For production (k3s):
1. Use Let's Encrypt ClusterIssuer instead of self-signed
2. Configure real DNS entries (not `.localhost`)
3. Set up proper certificate renewal monitoring
4. Consider using multiple Gateways for different security zones

## References

- [Istio Gateway](https://istio.io/latest/docs/reference/config/networking/gateway/)
- [Istio VirtualService](https://istio.io/latest/docs/reference/config/networking/virtual-service/)
- [cert-manager with Istio](https://cert-manager.io/docs/usage/istio/)
