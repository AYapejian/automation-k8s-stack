#!/usr/bin/env bash
# media-stack-down.sh - Remove Media stack (idempotent)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="media"
CLUSTER_NAME="automation-k8s"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

FORCE=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --force|-f)
            FORCE=true
            shift
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Setup kubeconfig for k3d cluster
setup_kubeconfig() {
    if command -v k3d >/dev/null 2>&1; then
        local kubeconfig
        kubeconfig=$(k3d kubeconfig write "${CLUSTER_NAME}" 2>/dev/null) || true
        if [[ -n "${kubeconfig}" && -f "${kubeconfig}" ]]; then
            export KUBECONFIG="${kubeconfig}"
        fi
    fi
}

# Check if cluster is accessible
check_cluster() {
    if ! kubectl cluster-info >/dev/null 2>&1; then
        log_warn "Cannot connect to Kubernetes cluster. Nothing to clean up."
        exit 0
    fi
}

# Delete namespace and all resources
delete_namespace() {
    if kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1; then
        log_info "Deleting namespace ${NAMESPACE} and all resources..."
        kubectl delete namespace "${NAMESPACE}" --timeout=120s || true
        log_info "Namespace deleted"
    else
        log_info "Namespace ${NAMESPACE} does not exist"
    fi
}

# Wait for namespace to be fully deleted
wait_for_deletion() {
    log_info "Waiting for namespace deletion to complete..."
    local timeout=60
    local count=0
    while kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1; do
        sleep 2
        count=$((count + 2))
        if [[ ${count} -ge ${timeout} ]]; then
            log_warn "Namespace deletion taking longer than expected"
            break
        fi
    done
}

main() {
    log_info "Removing Media stack..."

    setup_kubeconfig
    check_cluster
    delete_namespace
    wait_for_deletion

    log_info "Media stack removed successfully!"
}

main "$@"
