# Kubernetes Home Automation Stack

A full-stack Kubernetes cluster for self-hosting home automation, media services, and storage with easy setup/teardown scripts and full observability out of the box.

## Overview

This project provides Kubernetes-deployable services that make up a complete home automation system, intended to be used as:
- A playground and test environment for Kubernetes development
- A production-ready deployment for self-hosted or cloud environments

**Key Features:**
- Idempotent setup/teardown scripts (run multiple times without errors)
- Full ingress support with Istio service mesh
- mTLS security for all inter-service communication
- Hardware affinity support for USB, Zigbee, and GPU devices
- Complete observability stack (Prometheus, Grafana, Loki, Jaeger, Tempo)

## Quick Start

### Prerequisites

```bash
# macOS
brew install k3d kubectl docker

# Linux
curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
```

### Create Cluster

```bash
# Create k3d cluster with local registry
make cluster-up

# Check status
make cluster-status

# Destroy cluster
make cluster-down
```

### Cluster Endpoints

| Service | URL |
|---------|-----|
| HTTP Ingress | http://localhost:8080 |
| HTTPS Ingress | https://localhost:8443 |
| Local Registry | registry.localhost:5111 |

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                        k3d Cluster                          │
│  ┌───────────────┐  ┌───────────────┐  ┌───────────────┐   │
│  │    Server     │  │    Agent 1    │  │    Agent 2    │   │
│  │ (control)     │  │   (worker)    │  │   (worker)    │   │
│  └───────────────┘  └───────────────┘  └───────────────┘   │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │                   Istio Mesh                         │   │
│  │  ┌──────────┐ ┌──────────┐ ┌──────────┐            │   │
│  │  │ Home     │ │ Media    │ │ Security │            │   │
│  │  │ Auto     │ │ Stack    │ │ Stack    │            │   │
│  │  └──────────┘ └──────────┘ └──────────┘            │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │              Observability Stack                     │   │
│  │  Prometheus │ Grafana │ Loki │ Jaeger │ Tempo       │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

## Application Stacks

### Home Automation
- **HomeAssistant** - Central home automation hub
- **Mosquitto** - MQTT broker
- **Zigbee2MQTT** - Zigbee device integration
- **Homebridge** - HomeKit compatibility

### Media Center
- **Sonarr** - TV show management
- **Radarr** - Movie management
- **nzbget** - Usenet downloader

### Security
- **Frigate** - NVR with object detection

## Development

See [CLAUDE.md](CLAUDE.md) for detailed development workflow and [specs/roadmap.md](specs/roadmap.md) for implementation phases.

```bash
make help  # Show all available commands
```

## License

MIT
