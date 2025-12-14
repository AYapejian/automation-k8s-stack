#!/usr/bin/env bash
# istio-down.sh - Uninstall Istio service mesh (idempotent)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ISTIO_DIR="${REPO_ROOT}/platform/istio"
ISTIO_NAMESPACE="istio-system"
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
# This handles environments with complex KUBECONFIG env vars
setup_kubeconfig() {
    if command -v k3d >/dev/null 2>&1; then
        local kubeconfig
        kubeconfig=$(k3d kubeconfig write "${CLUSTER_NAME}" 2>/dev/null) || true
        if [[ -n "${kubeconfig}" && -f "${kubeconfig}" ]]; then
            export KUBECONFIG="${kubeconfig}"
        fi
    fi
}

# Parse arguments
FORCE=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --force|-f)
            FORCE=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [--force]"
            echo ""
            echo "Uninstall Istio service mesh from the cluster."
            echo ""
            echo "Options:"
            echo "  --force, -f  Skip confirmation prompt"
            echo "  -h, --help   Show this help message"
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
    if ! command -v helm >/dev/null 2>&1; then
        log_error "helm is not installed"
        exit 1
    fi

    if ! command -v kubectl >/dev/null 2>&1; then
        log_error "kubectl is not installed"
        exit 1
    fi
}

# Check if Helm release exists
release_exists() {
    local release_name="$1"
    local namespace="$2"
    helm status "${release_name}" -n "${namespace}" >/dev/null 2>&1
}

# Delete custom resources first
delete_resources() {
    log_info "Deleting Istio custom resources..."
    if [[ -d "${ISTIO_DIR}/resources" ]]; then
        kubectl delete -f "${ISTIO_DIR}/resources/" --ignore-not-found=true 2>/dev/null || true
    fi
}

# Uninstall istio-ingress gateway
uninstall_gateway() {
    if release_exists "istio-ingress" "${ISTIO_INGRESS_NAMESPACE}"; then
        log_info "Uninstalling Istio Ingress Gateway..."
        helm uninstall istio-ingress -n "${ISTIO_INGRESS_NAMESPACE}" --wait
    else
        log_info "istio-ingress not found (nothing to uninstall)"
    fi
}

# Uninstall istiod
uninstall_istiod() {
    if release_exists "istiod" "${ISTIO_NAMESPACE}"; then
        log_info "Uninstalling Istiod..."
        helm uninstall istiod -n "${ISTIO_NAMESPACE}" --wait
    else
        log_info "istiod not found (nothing to uninstall)"
    fi
}

# Uninstall istio-base
uninstall_base() {
    if release_exists "istio-base" "${ISTIO_NAMESPACE}"; then
        log_info "Uninstalling Istio Base..."
        helm uninstall istio-base -n "${ISTIO_NAMESPACE}" --wait
    else
        log_info "istio-base not found (nothing to uninstall)"
    fi
}

# Clean up namespaces and labels
cleanup() {
    log_info "Cleaning up..."

    # Remove istio-injection labels from all namespaces
    for ns in $(kubectl get namespaces -l istio-injection=enabled -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
        log_info "Removing istio-injection label from namespace: ${ns}"
        kubectl label namespace "${ns}" istio-injection- 2>/dev/null || true
    done

    # Delete ingress namespace if it exists and is empty
    if kubectl get namespace "${ISTIO_INGRESS_NAMESPACE}" >/dev/null 2>&1; then
        local pods
        pods=$(kubectl get pods -n "${ISTIO_INGRESS_NAMESPACE}" --no-headers 2>/dev/null | wc -l | tr -d ' ')
        if [[ "${pods}" -eq 0 ]]; then
            log_info "Deleting namespace: ${ISTIO_INGRESS_NAMESPACE}"
            kubectl delete namespace "${ISTIO_INGRESS_NAMESPACE}" --wait=false 2>/dev/null || true
        else
            log_warn "Namespace ${ISTIO_INGRESS_NAMESPACE} still has ${pods} pods, skipping deletion"
        fi
    fi

    # Delete istio-system namespace if it exists and is empty
    if kubectl get namespace "${ISTIO_NAMESPACE}" >/dev/null 2>&1; then
        local pods
        pods=$(kubectl get pods -n "${ISTIO_NAMESPACE}" --no-headers 2>/dev/null | wc -l | tr -d ' ')
        if [[ "${pods}" -eq 0 ]]; then
            log_info "Deleting namespace: ${ISTIO_NAMESPACE}"
            kubectl delete namespace "${ISTIO_NAMESPACE}" --wait=false 2>/dev/null || true
        else
            log_warn "Namespace ${ISTIO_NAMESPACE} still has ${pods} pods, skipping deletion"
        fi
    fi
}

main() {
    log_info "Starting Istio uninstallation..."

    setup_kubeconfig
    check_prerequisites

    # Check if cluster is accessible
    if ! kubectl cluster-info >/dev/null 2>&1; then
        log_warn "Cannot connect to Kubernetes cluster. Nothing to uninstall."
        exit 0
    fi

    if [[ "${FORCE}" != "true" ]]; then
        echo ""
        log_warn "This will uninstall Istio from the cluster."
        log_warn "All meshed workloads will lose sidecar injection."
        echo ""
        read -p "Continue? [y/N] " -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Aborted."
            exit 0
        fi
    fi

    # Uninstall in reverse order
    delete_resources
    uninstall_gateway
    uninstall_istiod
    uninstall_base
    cleanup

    echo ""
    log_info "=========================================="
    log_info "Istio uninstallation complete!"
    log_info "=========================================="
}

main "$@"
