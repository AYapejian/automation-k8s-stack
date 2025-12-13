#!/usr/bin/env bash
# ingress-down.sh - Remove Gateway and TLS certificates (idempotent)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
INGRESS_DIR="${REPO_ROOT}/platform/ingress"
ISTIO_INGRESS_NAMESPACE="istio-ingress"
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
# This ensures we always use the correct cluster context
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

# Parse arguments
FORCE=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --force|-f)
            FORCE=true
            shift
            ;;
        *)
            log_error "Unknown argument: $1"
            exit 1
            ;;
    esac
done

# Check prerequisites
check_prerequisites() {
    local missing=()

    command -v kubectl >/dev/null 2>&1 || missing+=("kubectl")

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required tools: ${missing[*]}"
        exit 1
    fi

    # Setup k3d kubeconfig
    setup_kubeconfig

    # Check if cluster is accessible (optional for down operations)
    if ! kubectl cluster-info >/dev/null 2>&1; then
        log_warn "Cannot connect to Kubernetes cluster."
        if [[ "${FORCE}" != "true" ]]; then
            log_error "Use --force to skip cluster checks."
            exit 1
        fi
        log_warn "Continuing anyway due to --force flag."
    fi
}

# Delete Gateway and Certificate resources
delete_resources() {
    log_info "Deleting Gateway and Certificate resources..."

    # Delete resources from the resources directory
    if [[ -d "${INGRESS_DIR}/resources" ]]; then
        kubectl delete -f "${INGRESS_DIR}/resources/" --ignore-not-found || true
    fi

    # Clean up the TLS secret (created by cert-manager)
    kubectl delete secret gateway-tls-secret -n "${ISTIO_INGRESS_NAMESPACE}" --ignore-not-found || true

    log_info "Resources deleted."
}

# Clean up any VirtualServices that reference the gateway
cleanup_virtualservices() {
    log_info "Note: VirtualServices referencing main-gateway may need manual cleanup."
    log_info "List VirtualServices:"
    kubectl get virtualservices -A 2>/dev/null || true
}

# Print status
print_info() {
    echo ""
    log_info "=========================================="
    log_info "Ingress configuration removed!"
    log_info "=========================================="
    echo ""
    echo "To reconfigure:"
    echo "  make ingress-up"
    echo ""
}

main() {
    log_info "Removing Gateway and TLS certificates..."

    check_prerequisites
    delete_resources
    cleanup_virtualservices
    print_info

    log_info "Done!"
}

main "$@"
