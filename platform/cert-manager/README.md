# cert-manager

This directory contains the cert-manager configuration for TLS certificate management in the automation-k8s-stack.

## Overview

cert-manager automates the management and issuance of TLS certificates. For the k3d development environment, we use a self-signed CA chain that allows issuing certificates for local testing.

## Architecture

```
selfsigned-issuer (ClusterIssuer)
    │
    │ signs
    ▼
selfsigned-ca (Certificate)
    │
    │ provides CA to
    ▼
automation-ca-issuer (ClusterIssuer)
    │
    │ signs
    ▼
Application Certificates
```

## Prerequisites

- Running k3d cluster (`make cluster-up`)
- Helm 3.x installed
- kubectl configured to access the cluster

## Installation

```bash
# Install cert-manager (idempotent)
make cert-manager-up

# Check status
make cert-manager-status

# Uninstall
make cert-manager-down
```

## Directory Structure

```
platform/cert-manager/
├── README.md                      # This file
├── values.yaml                    # Helm values for cert-manager
└── resources/
    └── cluster-issuer.yaml        # Self-signed CA chain
```

## ClusterIssuers

| Issuer | Type | Purpose |
|--------|------|---------|
| selfsigned-issuer | SelfSigned | Bootstrap issuer for creating CA |
| automation-ca-issuer | CA | Signs application certificates |

## Requesting Certificates

To request a TLS certificate for your application:

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: my-app-tls
  namespace: my-namespace
spec:
  secretName: my-app-tls-secret
  duration: 2160h  # 90 days
  renewBefore: 360h  # 15 days
  privateKey:
    algorithm: ECDSA
    size: 256
  usages:
    - server auth
    - digital signature
    - key encipherment
  dnsNames:
    - my-app.localhost
    - "*.my-app.localhost"
  issuerRef:
    name: automation-ca-issuer
    kind: ClusterIssuer
    group: cert-manager.io
```

The certificate will be stored in a Kubernetes Secret (`my-app-tls-secret`) containing:
- `tls.crt` - The certificate chain
- `tls.key` - The private key
- `ca.crt` - The CA certificate

## Integration with Istio Gateway

The Istio Gateway uses cert-manager to obtain TLS certificates. See `platform/ingress/` for Gateway configuration.

## Troubleshooting

### Check cert-manager Pods

```bash
kubectl get pods -n cert-manager
kubectl logs -n cert-manager deployment/cert-manager
```

### Check ClusterIssuers

```bash
kubectl get clusterissuers
kubectl describe clusterissuer automation-ca-issuer
```

### Check Certificate Status

```bash
kubectl get certificates -A
kubectl describe certificate <name> -n <namespace>
```

### Webhook Issues

If certificates fail to issue with webhook errors, the webhook may not be ready:

```bash
kubectl wait --for=condition=Available deployment/cert-manager-webhook -n cert-manager --timeout=60s
kubectl logs -n cert-manager deployment/cert-manager-webhook
```

## Production Considerations

For production (k3s), replace the self-signed CA with:
- **Let's Encrypt**: Free, automated certificates for public domains
- **Vault PKI**: Enterprise-grade certificate management
- **AWS ACM**: If running on AWS

Example Let's Encrypt ClusterIssuer:

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: admin@example.com
    privateKeySecretRef:
      name: letsencrypt-prod-account-key
    solvers:
      - http01:
          ingress:
            class: istio
```

## Version

cert-manager version: **v1.16.2**

To upgrade, update the `CERT_MANAGER_VERSION` variable in `scripts/cert-manager-up.sh`.

## References

- [cert-manager Documentation](https://cert-manager.io/docs/)
- [Helm Chart Values](https://artifacthub.io/packages/helm/cert-manager/cert-manager)
- [Certificate Resource](https://cert-manager.io/docs/usage/certificate/)
- [ClusterIssuer Reference](https://cert-manager.io/docs/configuration/)
