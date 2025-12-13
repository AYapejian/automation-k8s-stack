#!/usr/bin/env bash
# cert-manager-down.sh - Uninstall cert-manager (idempotent)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CERT_MANAGER_DIR="${REPO_ROOT}/platform/cert-manager"
CERT_MANAGER_NAMESPACE="cert-manager"
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

    command -v helm >/dev/null 2>&1 || missing+=("helm")
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

# Check if Helm release exists
release_exists() {
    local release_name="$1"
    local namespace="$2"
    helm status "${release_name}" -n "${namespace}" >/dev/null 2>&1
}

# Delete ClusterIssuer and CA resources
delete_resources() {
    log_info "Deleting cert-manager ClusterIssuer and CA resources..."

    if [[ -d "${CERT_MANAGER_DIR}/resources" ]]; then
        kubectl delete -f "${CERT_MANAGER_DIR}/resources/" --ignore-not-found || true
    fi

    # Also clean up any certificates that may be using our issuers
    log_info "Cleaning up certificates issued by automation-ca-issuer..."
    kubectl delete certificates --all-namespaces \
        -l cert-manager.io/issuer-kind=ClusterIssuer \
        --ignore-not-found 2>/dev/null || true
}

# Uninstall cert-manager
uninstall_cert_manager() {
    log_info "Uninstalling cert-manager..."

    if release_exists "cert-manager" "${CERT_MANAGER_NAMESPACE}"; then
        helm uninstall cert-manager -n "${CERT_MANAGER_NAMESPACE}" --wait
        log_info "cert-manager uninstalled."
    else
        log_info "cert-manager not installed, skipping."
    fi
}

# Clean up namespace
cleanup_namespace() {
    log_info "Cleaning up cert-manager namespace..."

    if kubectl get namespace "${CERT_MANAGER_NAMESPACE}" >/dev/null 2>&1; then
        kubectl delete namespace "${CERT_MANAGER_NAMESPACE}" --ignore-not-found
        log_info "Namespace ${CERT_MANAGER_NAMESPACE} deleted."
    else
        log_info "Namespace ${CERT_MANAGER_NAMESPACE} not found, skipping."
    fi
}

# Clean up CRDs (if they weren't removed by Helm)
cleanup_crds() {
    log_info "Cleaning up cert-manager CRDs..."

    local crds=(
        "certificaterequests.cert-manager.io"
        "certificates.cert-manager.io"
        "challenges.acme.cert-manager.io"
        "clusterissuers.cert-manager.io"
        "issuers.cert-manager.io"
        "orders.acme.cert-manager.io"
    )

    for crd in "${crds[@]}"; do
        if kubectl get crd "${crd}" >/dev/null 2>&1; then
            kubectl delete crd "${crd}" --ignore-not-found
        fi
    done

    log_info "CRDs cleaned up."
}

# Print status
print_info() {
    echo ""
    log_info "=========================================="
    log_info "cert-manager uninstalled successfully!"
    log_info "=========================================="
    echo ""
    echo "To reinstall:"
    echo "  make cert-manager-up"
    echo ""
}

main() {
    log_info "Starting cert-manager uninstallation..."

    check_prerequisites
    delete_resources
    uninstall_cert_manager
    cleanup_namespace
    cleanup_crds
    print_info

    log_info "Done!"
}

main "$@"
