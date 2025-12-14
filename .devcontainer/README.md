# Claude Code Development Container

This devcontainer provides a secure, isolated environment for using Claude Code with `--dangerously-skip-permissions` mode when developing the automation-k8s-stack project.

## Quick Start

1. **Prerequisites**
   - [Docker Desktop](https://www.docker.com/products/docker-desktop/) running
   - [VS Code](https://code.visualstudio.com/) with [Dev Containers extension](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers)
   - Claude Code authenticated on your host (`claude login` if not already)

2. **Open in Container**
   - Open this project in VS Code
   - When prompted, click "Reopen in Container"
   - Or use Command Palette: `Cmd+Shift+P` → "Dev Containers: Reopen in Container"

3. **Start Developing**
   ```bash
   # Create k3d cluster and deploy stack
   make cluster-up
   make stack-up

   # Use Claude Code with full permissions (safe in container)
   claude --dangerously-skip-permissions
   ```

**Claude Max users:** Your OAuth credentials are automatically shared from your host's `~/.claude` directory - no re-authentication needed!

## What's Included

| Tool | Version | Purpose |
|------|---------|---------|
| kubectl | v1.31 | Kubernetes CLI (matches k3s version) |
| k3d | latest | Kubernetes-in-Docker for local clusters |
| Helm | v3.x | Kubernetes package manager |
| jq / yq | latest | JSON/YAML processing |
| Node.js | v20 | Required for Claude Code |
| Claude Code | latest | AI coding assistant |
| GitHub CLI | latest | PR/issue workflows |

**Pre-configured Helm Repos:**
- istio, jetstack (cert-manager), grafana, prometheus-community

## Security Model

The devcontainer uses **container isolation** as the security boundary:

- **Docker Socket Mounting**: k3d containers run on your host Docker daemon
- **No Network Firewall**: Container isolation is sufficient; no domain restrictions
- **Non-root User**: Runs as `vscode` user, not root
- **Host Networking**: Direct access to k3d ports (8080, 8443, 5111)

This design allows safe use of `--dangerously-skip-permissions` because:
1. All changes are contained within the project directory
2. The container cannot access host files outside mounted volumes
3. Any malicious code is isolated from your host system

## Persistent Data

The following data persists across container rebuilds:

| Mount | Path | Type | Contents |
|-------|------|------|----------|
| `automation-k8s-kube` | `~/.kube` | Volume | Kubernetes configs |
| Host `~/.claude` | `~/.claude` | Bind | Claude OAuth credentials (shared with host) |
| `automation-k8s-history` | `~/.bash_history_dir` | Volume | Shell history |

## Authentication

### Claude Max / Claude Pro (OAuth - Recommended)

Your Claude credentials are **automatically shared** from your host machine:

```bash
# On host (one-time setup)
claude login
```

The devcontainer bind-mounts `~/.claude` from your host, so your OAuth session persists across container rebuilds. No re-authentication needed!

### API Key Users

If using an API key instead of Claude Max:

```bash
# Inside container
export ANTHROPIC_API_KEY="sk-ant-api03-..."
```

Or add to `.bashrc` inside the container for persistence.

### GitHub Token

Two options:

1. **Interactive login** (recommended):
   ```bash
   gh auth login
   ```

2. **Environment variable** (set on host, auto-injected):
   ```bash
   export GITHUB_TOKEN="ghp_..."
   ```

### Kubeconfig

Automatically managed by k3d:
- Generated when cluster is created
- Merged on container start if cluster exists
- Stored in persistent Docker volume

## Common Commands

```bash
# Cluster Management
make cluster-up          # Create k3d cluster (idempotent)
make cluster-down        # Destroy cluster
make cluster-status      # Show cluster info

# Stack Deployment
make stack-up            # Deploy full stack (Istio, observability, etc.)
make stack-down          # Tear down stack
make stack-status        # Health check all components

# kubectl shortcuts (added to .bashrc)
k get pods -A            # Alias for kubectl
kgp                      # kubectl get pods
kga                      # kubectl get all
kgn                      # kubectl get nodes

# Claude Code
claude --dangerously-skip-permissions
```

## Access Points (after stack-up)

| Service | URL | Credentials |
|---------|-----|-------------|
| Grafana | https://grafana.localhost:8443 | admin/admin |
| Prometheus | https://prometheus.localhost:8443 | - |
| Local Registry | registry.localhost:5111 | - |

**Note**: Use browser exception or `curl -k` for self-signed certificates.

## Troubleshooting

### Docker socket permission denied

```bash
# Inside container
sudo chmod 666 /var/run/docker.sock
```

### k3d cluster not accessible after container restart

```bash
k3d kubeconfig merge automation-k8s --kubeconfig-switch-context
```

### ANTHROPIC_API_KEY not set

Set it on your host and rebuild the container:
```bash
# On host
echo 'export ANTHROPIC_API_KEY="sk-ant-..."' >> ~/.zshrc
source ~/.zshrc

# Then rebuild devcontainer in VS Code
```

### Container build fails

Try rebuilding without cache:
- Command Palette: `Dev Containers: Rebuild Container Without Cache`

### Slow performance on macOS

Ensure Docker Desktop has sufficient resources:
- Settings → Resources → Memory: 8GB+ recommended
- Settings → Resources → CPUs: 4+ recommended

## Customization

### Adding VS Code Extensions

Edit `.devcontainer/devcontainer.json`:

```json
"customizations": {
  "vscode": {
    "extensions": [
      "your.extension-id"
    ]
  }
}
```

### Adding Tools

Edit `.devcontainer/Dockerfile` and add installation commands.

### Adding Environment Variables

Edit `.devcontainer/devcontainer.json`:

```json
"containerEnv": {
  "MY_VAR": "${localEnv:MY_VAR}"
}
```

## Architecture Notes

This devcontainer uses the **Docker Outside of Docker** (DooD) pattern:

```
┌─────────────────────────────────────────┐
│  Host Machine                           │
│  ┌───────────────────────────────────┐  │
│  │  Docker Desktop                   │  │
│  │  ┌─────────────────────────────┐  │  │
│  │  │  Devcontainer               │  │  │
│  │  │  - Claude Code              │  │  │
│  │  │  - kubectl, helm, k3d CLI   │  │  │
│  │  │  - /var/run/docker.sock ────┼──┼──┤ (mounted)
│  │  └─────────────────────────────┘  │  │
│  │  ┌─────────────────────────────┐  │  │
│  │  │  k3d Cluster Containers     │  │  │
│  │  │  - k3d-automation-k8s-*     │  │  │
│  │  └─────────────────────────────┘  │  │
│  └───────────────────────────────────┘  │
└─────────────────────────────────────────┘
```

The devcontainer CLI tools communicate with the host Docker daemon, which runs the k3d cluster containers as siblings (not nested).
