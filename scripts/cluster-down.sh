#!/usr/bin/env bash
# cluster-down.sh - Destroy k3d cluster and registry (idempotent)
set -euo pipefail

CLUSTER_NAME="automation-k8s"
REGISTRY_NAME="registry.localhost"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# Parse arguments
KEEP_REGISTRY=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --keep-registry)
            KEEP_REGISTRY=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [--keep-registry]"
            echo ""
            echo "Options:"
            echo "  --keep-registry  Keep the local registry for faster re-creation"
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Check prerequisites
check_prerequisites() {
    if ! command -v k3d >/dev/null 2>&1; then
        log_error "k3d is not installed"
        exit 1
    fi

    if ! command -v docker >/dev/null 2>&1; then
        log_error "docker is not installed"
        exit 1
    fi
}

# Check if cluster exists
cluster_exists() {
    k3d cluster list -o json 2>/dev/null | grep -q "\"name\":\"${CLUSTER_NAME}\""
}

# Delete k3d cluster
delete_cluster() {
    if cluster_exists; then
        log_info "Deleting k3d cluster '${CLUSTER_NAME}'..."
        k3d cluster delete "${CLUSTER_NAME}"
    else
        log_info "Cluster '${CLUSTER_NAME}' does not exist (nothing to delete)"
    fi
}

# Delete registry
delete_registry() {
    if [[ "${KEEP_REGISTRY}" == "true" ]]; then
        log_info "Keeping registry (--keep-registry flag set)"
        return 0
    fi

    # Check if registry exists (created by k3d)
    if k3d registry list 2>/dev/null | grep -q "${REGISTRY_NAME}"; then
        log_info "Deleting registry '${REGISTRY_NAME}'..."
        k3d registry delete "${REGISTRY_NAME}" 2>/dev/null || true
    fi

    # Also clean up any orphaned registry containers
    if docker ps -a --format '{{.Names}}' | grep -q "k3d-${REGISTRY_NAME}"; then
        log_info "Removing orphaned registry container..."
        docker rm -f "k3d-${REGISTRY_NAME}" 2>/dev/null || true
    fi
}

# Clean up kubeconfig context
cleanup_kubeconfig() {
    local context="k3d-${CLUSTER_NAME}"

    if kubectl config get-contexts -o name 2>/dev/null | grep -q "^${context}$"; then
        log_info "Removing kubeconfig context '${context}'..."
        kubectl config delete-context "${context}" 2>/dev/null || true
        kubectl config delete-cluster "${context}" 2>/dev/null || true
    fi
}

# Clean up docker network if orphaned
cleanup_network() {
    local network="k3d-${CLUSTER_NAME}"

    if docker network ls --format '{{.Name}}' | grep -q "^${network}$"; then
        # Only remove if no containers are using it
        local containers
        containers=$(docker network inspect "${network}" --format '{{len .Containers}}' 2>/dev/null || echo "0")
        if [[ "${containers}" == "0" ]]; then
            log_info "Removing orphaned network '${network}'..."
            docker network rm "${network}" 2>/dev/null || true
        fi
    fi
}

main() {
    log_info "Starting k3d cluster teardown..."

    check_prerequisites
    delete_cluster
    delete_registry
    cleanup_kubeconfig
    cleanup_network

    echo ""
    log_info "=========================================="
    log_info "Cleanup complete!"
    log_info "=========================================="
}

main "$@"
