#!/usr/bin/env bash
# =============================================================================
# post-start.sh - Runs on every container start
# =============================================================================
# This script runs each time the devcontainer starts (not just on creation).
# It handles dynamic setup like merging kubeconfig for existing clusters.
#
# TEMPLATING NOTES:
# - Cluster name: Project-specific, parameterize for templates
# - Docker check: Keep as-is (common requirement)
# =============================================================================

set -euo pipefail

echo "[INFO] Running post-start setup..."

# =============================================================================
# Docker Socket Check
# =============================================================================
if [ -S /var/run/docker.sock ]; then
    DOCKER_VERSION=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "unknown")
    echo "[INFO] Docker daemon accessible (v${DOCKER_VERSION})"
else
    echo "[WARN] Docker socket not available at /var/run/docker.sock"
    echo "       k3d commands will not work. Check Docker Desktop is running."
fi

# =============================================================================
# k3d Cluster Detection and Kubeconfig
# =============================================================================
# TEMPLATE: Change cluster name for different projects
CLUSTER_NAME="automation-k8s"

# Fix volume ownership if needed (Docker volumes mount as root)
if [ -d ~/.kube ] && [ "$(stat -c '%U' ~/.kube 2>/dev/null)" = "root" ]; then
    echo "[INFO] Fixing ~/.kube ownership..."
    sudo chown -R vscode:vscode ~/.kube
fi

if k3d cluster list 2>/dev/null | grep -q "${CLUSTER_NAME}"; then
    echo "[INFO] Found existing k3d cluster '${CLUSTER_NAME}', updating kubeconfig..."

    # Merge kubeconfig and switch context
    if k3d kubeconfig merge "${CLUSTER_NAME}" --kubeconfig-switch-context 2>/dev/null; then
        echo "[INFO] Kubeconfig updated, context set to k3d-${CLUSTER_NAME}"

        # Quick cluster health check
        if kubectl cluster-info --request-timeout=5s &>/dev/null; then
            NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
            echo "[INFO] Cluster is healthy (${NODE_COUNT} nodes)"
        else
            echo "[WARN] Cluster exists but API server not responding"
        fi
    else
        echo "[WARN] Failed to merge kubeconfig for cluster '${CLUSTER_NAME}'"
    fi
else
    echo "[INFO] No existing k3d cluster found"
    echo "       Run 'make cluster-up' to create one"
fi

# =============================================================================
# Environment Summary
# =============================================================================
echo ""
echo "[INFO] Post-start setup complete"
echo ""

# Show helpful reminder if no cluster
if ! k3d cluster list 2>/dev/null | grep -q "${CLUSTER_NAME}"; then
    echo "To get started:"
    echo "  make cluster-up    # Create k3d cluster"
    echo "  make stack-up      # Deploy full stack"
    echo ""
fi
