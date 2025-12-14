# Kubernetes Home Automation Stack

A production-ready Kubernetes platform for self-hosting home automation, media services, and security systems with full observability out of the box.

## Quick Start

```bash
# Deploy everything with a single command
make stack-up

# Check health
make stack-status

# Tear down
make stack-down
```

## What Gets Deployed

The `make stack-up` command deploys the following infrastructure in dependency order:

| Component | Description |
|-----------|-------------|
| k3d Cluster | 1 server + 2 worker nodes |
| Istio | Service mesh with mTLS |
| cert-manager | TLS certificate management |
| Istio Gateway | Ingress with TLS termination |
| Prometheus + Grafana | Metrics collection and visualization |
| Loki + Promtail | Log aggregation |

## Access URLs

| Service | URL | Credentials |
|---------|-----|-------------|
| Grafana | https://grafana.localhost:8443 | admin / admin |
| Prometheus | https://prometheus.localhost:8443 | - |

**Grafana Features:**
- Explore -> Prometheus: Query metrics
- Explore -> Loki: Query logs
- Pre-configured Kubernetes dashboards

## Technology Stack

| Component | Technology | Version |
|-----------|------------|---------|
| Local Kubernetes | k3d (k3s in Docker) | v1.31.2-k3s1 |
| Service Mesh | Istio | 1.24.0 |
| TLS Management | cert-manager | 1.16.2 |
| Metrics | kube-prometheus-stack | 80.4.1 |
| Logs | Loki + Promtail | 2.10.3 |

## Testing

Deploy the sample application to verify the stack is working:

```bash
# Deploy httpbin sample app
make sample-app-up

# Test connectivity through the mesh
curl -k https://httpbin.localhost:8443/get

# Check request metrics in Grafana (Prometheus datasource)
# Query: istio_requests_total{destination_app="httpbin"}

# View request logs in Grafana (Loki datasource)
# Query: {namespace="ingress-sample"}
```

## Prerequisites

```bash
# macOS
brew install k3d kubectl docker jq helm

# Linux
curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
# Install kubectl, docker, jq, helm via package manager
```

Ensure Docker is running before executing `make stack-up`.

## Development with Devcontainer (Recommended)

For the best development experience, especially when using Claude Code AI assistance, use the included devcontainer:

1. Install [VS Code Dev Containers extension](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers)
2. Set `ANTHROPIC_API_KEY` in your shell profile (`~/.zshrc` or `~/.bashrc`)
3. Open project in VS Code → "Reopen in Container"
4. Run Claude Code with full permissions (safe in container isolation):
   ```bash
   claude --dangerously-skip-permissions
   ```

**Benefits:**
- Pre-installed k3d, kubectl, helm, jq, yq
- Persistent kubeconfig and Claude config across rebuilds
- Direct access to k3d cluster via host networking
- Container isolation enables safe AI-assisted development

See [.devcontainer/README.md](.devcontainer/README.md) for full documentation.

## Using kubectl with the Cluster

After the cluster is running, set your kubeconfig context:

```bash
# Option 1: Use the helper target (recommended)
eval $(make kubeconfig)

# Option 2: Set KUBECONFIG manually
export KUBECONFIG=$(k3d kubeconfig write automation-k8s)

# Verify connection
kubectl get nodes
```

The `make stack-up` and `make stack-status` commands will display this export command in their output.

## All Commands

```bash
make help  # Show all available targets
```

### Stack Management
| Command | Description |
|---------|-------------|
| `make stack-up` | Deploy complete infrastructure stack |
| `make stack-down` | Tear down entire stack |
| `make stack-status` | Show overall health status |

### Individual Components
| Command | Description |
|---------|-------------|
| `make cluster-up` | Create k3d cluster |
| `make istio-up` | Install Istio service mesh |
| `make cert-manager-up` | Install cert-manager |
| `make ingress-up` | Configure Gateway + TLS |
| `make prometheus-grafana-up` | Install Prometheus + Grafana |
| `make loki-up` | Install Loki + Promtail |
| `make sample-app-up` | Deploy httpbin sample app |

Each component has corresponding `-down` and `-status` targets.

## Architecture

```
                         localhost:8443 (HTTPS)
                                │
┌───────────────────────────────┼───────────────────────────────┐
│                         k3d Cluster                           │
│                               │                               │
│  ┌────────────────────────────┼────────────────────────────┐  │
│  │                    Istio Gateway                        │  │
│  │              (TLS termination, routing)                 │  │
│  └────────────────────────────┼────────────────────────────┘  │
│                               │                               │
│  ┌────────────────────────────┼────────────────────────────┐  │
│  │                     Istio Mesh                          │  │
│  │                    (mTLS, telemetry)                    │  │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐              │  │
│  │  │ Apps     │  │ Apps     │  │ Apps     │              │  │
│  │  │ (future) │  │ (future) │  │ (future) │              │  │
│  │  └──────────┘  └──────────┘  └──────────┘              │  │
│  └─────────────────────────────────────────────────────────┘  │
│                                                               │
│  ┌─────────────────────────────────────────────────────────┐  │
│  │                  Observability Stack                    │  │
│  │  Prometheus │ Grafana │ Loki │ Promtail                │  │
│  └─────────────────────────────────────────────────────────┘  │
│                                                               │
│  ┌───────────────┐  ┌───────────────┐  ┌───────────────┐     │
│  │    Server     │  │    Agent 1    │  │    Agent 2    │     │
│  │  (control)    │  │   (worker)    │  │   (worker)    │     │
│  └───────────────┘  └───────────────┘  └───────────────┘     │
└───────────────────────────────────────────────────────────────┘
```

## Planned Application Stacks

### Home Automation
- HomeAssistant - Central home automation hub
- Mosquitto - MQTT broker
- Zigbee2MQTT - Zigbee device integration
- Homebridge - HomeKit compatibility

### Media Center
- Sonarr - TV show management
- Radarr - Movie management
- nzbget - Usenet downloader

### Security
- Frigate - NVR with object detection

## Development

See [CLAUDE.md](CLAUDE.md) for development workflow and [specs/roadmap.md](specs/roadmap.md) for implementation phases.

## License

MIT
