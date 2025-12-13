#!/usr/bin/env bash
# storage-test-down.sh - Clean up storage test resources
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_DIR="${REPO_ROOT}/tests/storage"
CLUSTER_NAME="automation-k8s"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# Setup kubeconfig for k3d cluster
setup_kubeconfig() {
    if command -v k3d >/dev/null 2>&1; then
        local kubeconfig
        kubeconfig=$(k3d kubeconfig write "${CLUSTER_NAME}" 2>/dev/null) || true
        if [[ -n "${kubeconfig}" && -f "${kubeconfig}" ]]; then
            export KUBECONFIG="${kubeconfig}"
            log_info "Using k3d cluster context: ${CLUSTER_NAME}"
        fi
    fi
}

# Check if kubectl is available
check_kubectl() {
    if ! command -v kubectl >/dev/null 2>&1; then
        log_warn "kubectl not found, skipping cleanup"
        exit 0
    fi

    setup_kubeconfig

    if ! kubectl cluster-info >/dev/null 2>&1; then
        log_warn "Cluster not accessible, nothing to clean up"
        exit 0
    fi
}

# Delete test resources
cleanup_resources() {
    log_info "Removing storage test resources..."

    # Delete pod first
    if kubectl get pod storage-test -n default >/dev/null 2>&1; then
        log_info "Deleting test pod..."
        kubectl delete pod storage-test -n default --ignore-not-found=true
    else
        log_info "Test pod not found (already cleaned up)"
    fi

    # Wait for pod deletion before deleting PVC
    local attempts=0
    while kubectl get pod storage-test -n default >/dev/null 2>&1; do
        if [[ $attempts -ge 30 ]]; then
            log_warn "Timeout waiting for pod deletion, forcing PVC deletion..."
            break
        fi
        sleep 1
        ((attempts++))
    done

    # Delete PVC
    if kubectl get pvc storage-test -n default >/dev/null 2>&1; then
        log_info "Deleting test PVC..."
        kubectl delete pvc storage-test -n default --ignore-not-found=true
    else
        log_info "Test PVC not found (already cleaned up)"
    fi

    # Wait for PVC deletion
    attempts=0
    while kubectl get pvc storage-test -n default >/dev/null 2>&1; do
        if [[ $attempts -ge 30 ]]; then
            log_warn "Timeout waiting for PVC deletion"
            break
        fi
        sleep 1
        ((attempts++))
    done
}

# Print status
print_status() {
    echo ""
    log_info "Cleanup complete!"
    echo ""
    echo "Remaining PVCs in default namespace:"
    kubectl get pvc -n default 2>/dev/null || echo "  (none)"
    echo ""
}

main() {
    log_info "Cleaning up storage test resources..."

    check_kubectl
    cleanup_resources
    print_status

    log_info "Done!"
}

main "$@"
