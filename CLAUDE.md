# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A Kubernetes-deployable home automation stack with full observability, designed for local development (KIND), self-hosted (k3s), and cloud deployment. The system uses Istio service mesh for inter-service communication with distributed tracing.

## Key Technology Decisions

| Component | Choice | Notes |
|-----------|--------|-------|
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
│   ├── kind/                # KIND cluster configs
│   └── k3s/                 # k3s overlays (future)
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

### Commands (to be implemented)
```bash
make help           # Show available targets
make cluster-up     # Create KIND cluster (idempotent)
make cluster-down   # Destroy KIND cluster (idempotent)
make test           # Run all tests
```

### Testing Strategy
- KIND cluster for local dev and CI (multi-node: 1 control-plane, 2 workers)
- GHA runs tests on every PR
- KIND limitations: Cannot test USB passthrough, GPU scheduling, real NAS - these require k3s

### Branch Naming
```
feature/<phase>-<component>
```
Examples: `feature/1.2-kind-cluster`, `feature/2.1-istio`, `feature/5.1-home-automation`

### Implementation Phases
See `specs/roadmap.md` for detailed roadmap with acceptance criteria.

1. **Foundation**: Repo structure, KIND cluster, test harness, Sealed Secrets
2. **Platform**: Istio, Ingress, Storage provisioner
3. **Observability**: Prometheus/Grafana, Loki, Jaeger+Tempo, Dashboards
4. **Backup**: Minio, Velero
5. **Apps**: Home Automation, Media, Security stacks
6. **Production**: ArgoCD, k3s overlays, hardware affinity

## Hardware Affinity (k3s only)

Node labels used for scheduling:
- `hardware/usb=true` - USB devices (HomeAssistant)
- `hardware/zigbee=true` - Zigbee coordinator (Zigbee2MQTT)
- `hardware/nvidia=true` - GPU (Frigate)
- `storage/nas=true` - NAS access (Media, Frigate)

## Security Requirements

- No secrets in commits - use Sealed Secrets
- All inter-service communication through Istio mTLS
- Sealed Secrets testable offline with CI keypair
