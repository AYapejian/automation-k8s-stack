# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A Kubernetes-deployable home automation stack with full observability, designed for local development (k3d), self-hosted (k3s), and cloud deployment. The system uses Istio service mesh for inter-service communication with distributed tracing.

## Key Technology Decisions

| Component | Choice | Notes |
|-----------|--------|-------|
| Local K8s | k3d | k3s in Docker - fast, cross-platform, CI-friendly |
| Service Mesh | Istio | mTLS, traffic management, telemetry |
| Tracing | Jaeger + Tempo | OTel Collector fans out to both |
| Metrics | Prometheus + Grafana | HomeAssistant uses Prometheus integration (no InfluxDB) |
| Logs | Loki | Via Promtail or Grafana Alloy |
| GitOps | ArgoCD | App-of-apps pattern |
| Secrets | Sealed Secrets | Offline-sealable, testable in CI |
| Ingress | Istio Gateway | Leverage mesh, not separate NGINX |

## Directory Structure

```
/
├── .github/workflows/       # GHA workflows
├── clusters/
│   ├── k3d/                 # k3d cluster configs (local dev & CI)
│   └── k3s/                 # k3s overlays (production)
├── platform/                # Istio, ingress, cert-manager, sealed-secrets
├── observability/           # Prometheus, Grafana, Loki, Jaeger, Tempo
├── apps/
│   ├── home-automation/     # HomeAssistant, MQTT, Zigbee2MQTT, Homebridge
│   ├── media/               # sonarr, radarr, nzbget
│   └── security/            # Frigate NVR
├── scripts/                 # Setup/teardown scripts
├── specs/                   # Project specs and roadmap
└── tests/                   # Test definitions
```

## Application Stacks

- **Home Automation**: HomeAssistant (USB affinity), Mosquitto MQTT, Zigbee2MQTT (Zigbee affinity), Homebridge
- **Security**: Frigate NVR (NAS + NVIDIA GPU affinity)
- **Media Center**: nzbget, sonarr, radarr (shared NAS storage)
- **Supporting**: Minio (object storage), Velero (backups)

## Development Workflow

### Prerequisites
```bash
# Required tools
brew install k3d kubectl docker  # macOS
# or
curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash  # Linux
```

### Commands
```bash
make help           # Show available targets
make cluster-up     # Create k3d cluster with registry (idempotent)
make cluster-down   # Destroy k3d cluster (idempotent)
make cluster-status # Show cluster and registry status
make test           # Run all tests
```

### Cluster Details
- **Nodes**: 1 server + 2 agents (workers)
- **Registry**: `registry.localhost:5111`
- **Ingress**: `localhost:8080` (HTTP), `localhost:8443` (HTTPS)
- **NodePorts**: 30000-30100

### Testing Strategy
- k3d cluster for local dev and CI (multi-node: 1 server, 2 agents)
- GHA runs tests on every PR
- k3d uses k3s, providing near-identical environment to production
- Limitations: Cannot test USB passthrough, GPU scheduling, real NAS - these require real k3s

### Branch Naming
```
feature/<phase>-<component>
```
Examples: `feature/1.2-k3d-cluster`, `feature/2.1-istio`, `feature/5.1-home-automation`

### Implementation Phases
See `specs/roadmap.md` for detailed roadmap with acceptance criteria.

1. **Foundation**: Repo structure, k3d cluster, test harness, Sealed Secrets
2. **Platform**: Istio, Ingress, Storage provisioner
3. **Observability**: Prometheus/Grafana, Loki, Jaeger+Tempo, Dashboards
4. **Backup**: Minio, Velero
5. **Apps**: Home Automation, Media, Security stacks
6. **Production**: ArgoCD, k3s overlays, hardware affinity

## Hardware Affinity (k3s production only)

Node labels used for scheduling:
- `hardware/usb=true` - USB devices (HomeAssistant)
- `hardware/zigbee=true` - Zigbee coordinator (Zigbee2MQTT)
- `hardware/nvidia=true` - GPU (Frigate)
- `storage/nas=true` - NAS access (Media, Frigate)

Note: In k3d, simulated labels are applied to agent nodes for testing affinity rules.

## Security Requirements

- No secrets in commits - use Sealed Secrets
- All inter-service communication through Istio mTLS
- Sealed Secrets testable offline with CI keypair
