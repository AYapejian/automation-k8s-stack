#!/usr/bin/env bash
# cluster-up.sh - Create k3d cluster with local registry (idempotent)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CLUSTER_NAME="automation-k8s"
CLUSTER_CONFIG="${REPO_ROOT}/clusters/k3d/cluster-config.yaml"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# Check prerequisites
check_prerequisites() {
    local missing=()

    command -v k3d >/dev/null 2>&1 || missing+=("k3d")
    command -v kubectl >/dev/null 2>&1 || missing+=("kubectl")
    command -v docker >/dev/null 2>&1 || missing+=("docker")

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required tools: ${missing[*]}"
        log_error "Install k3d: curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash"
        exit 1
    fi

    # Check if Docker is running
    if ! docker info >/dev/null 2>&1; then
        log_error "Docker is not running. Please start Docker first."
        exit 1
    fi

    # Check config file exists
    if [[ ! -f "${CLUSTER_CONFIG}" ]]; then
        log_error "Cluster config not found: ${CLUSTER_CONFIG}"
        exit 1
    fi
}

# Check if cluster already exists
cluster_exists() {
    k3d cluster list -o json 2>/dev/null | grep -q "\"name\":\"${CLUSTER_NAME}\""
}

# Create k3d cluster
create_cluster() {
    if cluster_exists; then
        log_info "Cluster '${CLUSTER_NAME}' already exists"

        # Ensure cluster is running
        local status
        status=$(k3d cluster list -o json | grep -A5 "\"name\":\"${CLUSTER_NAME}\"" | grep -o '"serversRunning":[0-9]*' | cut -d: -f2)

        if [[ "${status}" == "0" ]]; then
            log_info "Starting stopped cluster..."
            k3d cluster start "${CLUSTER_NAME}"
        fi

        # Update kubeconfig
        k3d kubeconfig merge "${CLUSTER_NAME}" --kubeconfig-switch-context
        return 0
    fi

    log_info "Creating k3d cluster '${CLUSTER_NAME}'..."
    k3d cluster create --config "${CLUSTER_CONFIG}"
}

# Get kubectl command with proper kubeconfig
# This handles environments with complex KUBECONFIG env vars
get_kubectl() {
    local kubeconfig
    kubeconfig=$(k3d kubeconfig write "${CLUSTER_NAME}" 2>/dev/null)
    echo "kubectl --kubeconfig=${kubeconfig}"
}

# Apply node labels for affinity testing
apply_node_labels() {
    log_info "Applying node labels for affinity testing..."

    local kubectl_cmd
    kubectl_cmd=$(get_kubectl)

    # Wait for nodes to be ready
    ${kubectl_cmd} wait --for=condition=Ready nodes --all --timeout=120s

    # Get agent (worker) nodes
    local agents
    agents=$(${kubectl_cmd} get nodes -o name | grep -E "agent" || true)

    if [[ -n "${agents}" ]]; then
        local i=0
        for node in ${agents}; do
            # Apply simulated hardware labels
            # In real k3s deployment, these would be on actual hardware nodes
            ${kubectl_cmd} label "${node}" node-role.kubernetes.io/worker=true --overwrite
            ${kubectl_cmd} label "${node}" hardware/usb=false --overwrite
            ${kubectl_cmd} label "${node}" hardware/zigbee=false --overwrite

            # Mark first worker as having USB (for HomeAssistant affinity testing)
            if [[ ${i} -eq 0 ]]; then
                ${kubectl_cmd} label "${node}" hardware/usb=true --overwrite
            fi
            ((i++)) || true
        done
        log_info "Applied labels to ${i} worker nodes"
    else
        log_warn "No agent nodes found - running single-node configuration"
    fi
}

# Wait for cluster to be ready
wait_for_cluster() {
    log_info "Waiting for cluster to be ready..."

    local kubectl_cmd
    kubectl_cmd=$(get_kubectl)

    # Wait for nodes
    ${kubectl_cmd} wait --for=condition=Ready nodes --all --timeout=120s

    # Wait for core system pods
    log_info "Waiting for system pods..."
    ${kubectl_cmd} wait --for=condition=Ready pods --all -n kube-system --timeout=180s
}

# Print cluster info
print_info() {
    local kubectl_cmd
    kubectl_cmd=$(get_kubectl)

    local registry_port
    registry_port=$(k3d registry list -o json 2>/dev/null | grep -o '"portMappings":"[^"]*"' | head -1 | sed 's/.*:\([0-9]*\)-.*/\1/' || echo "5111")

    echo ""
    log_info "=========================================="
    log_info "Cluster '${CLUSTER_NAME}' is ready!"
    log_info "=========================================="
    echo ""
    echo "Cluster nodes:"
    ${kubectl_cmd} get nodes -o wide
    echo ""
    echo "Endpoints:"
    echo "  HTTP Ingress:  http://localhost:8080"
    echo "  HTTPS Ingress: https://localhost:8443"
    echo "  Local Registry: registry.localhost:${registry_port}"
    echo ""
    echo "To use the registry in your deployments:"
    echo "  image: registry.localhost:${registry_port}/my-image:tag"
    echo ""
    echo "Useful commands:"
    echo "  kubectl get nodes         # List nodes"
    echo "  kubectl get pods -A       # List all pods"
    echo "  make cluster-status       # Check cluster status"
    echo "  make cluster-down         # Destroy cluster"
    echo ""
}

main() {
    log_info "Starting k3d cluster setup..."

    check_prerequisites
    create_cluster
    wait_for_cluster
    apply_node_labels
    print_info

    log_info "Done!"
}

main "$@"
