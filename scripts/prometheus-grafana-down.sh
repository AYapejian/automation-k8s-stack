#!/usr/bin/env bash
# prometheus-grafana-down.sh - Uninstall Prometheus + Grafana stack (idempotent)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
OBS_DIR="${REPO_ROOT}/observability/prometheus-grafana"
NAMESPACE="observability"
RELEASE_NAME="prometheus"
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
            echo "Uninstall Prometheus + Grafana stack from the cluster."
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
    helm status "${RELEASE_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1
}

# Delete VirtualServices
delete_virtualservices() {
    log_info "Deleting VirtualServices..."
    if [[ -d "${OBS_DIR}/resources" ]]; then
        kubectl delete -f "${OBS_DIR}/resources/virtualservice-grafana.yaml" --ignore-not-found=true 2>/dev/null || true
        kubectl delete -f "${OBS_DIR}/resources/virtualservice-prometheus.yaml" --ignore-not-found=true 2>/dev/null || true
    fi
}

# Delete Istio monitors
delete_istio_monitors() {
    log_info "Deleting Istio ServiceMonitor and PodMonitor..."
    if [[ -d "${OBS_DIR}/resources" ]]; then
        kubectl delete -f "${OBS_DIR}/resources/servicemonitor-istio.yaml" --ignore-not-found=true 2>/dev/null || true
        kubectl delete -f "${OBS_DIR}/resources/podmonitor-envoy.yaml" --ignore-not-found=true 2>/dev/null || true
    fi
}

# Uninstall kube-prometheus-stack
uninstall_prometheus_stack() {
    if release_exists; then
        log_info "Uninstalling kube-prometheus-stack..."
        helm uninstall "${RELEASE_NAME}" -n "${NAMESPACE}" --wait
    else
        log_info "${RELEASE_NAME} release not found (nothing to uninstall)"
    fi
}

# Clean up CRDs (optional, disabled by default)
cleanup_crds() {
    # CRDs are shared across releases, so we don't delete them by default
    log_info "Note: Prometheus CRDs are retained for potential future use."
    log_info "To manually remove CRDs: kubectl delete crd -l app.kubernetes.io/name=kube-prometheus-stack"
}

# Delete namespace if empty
cleanup_namespace() {
    if kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1; then
        local pods
        pods=$(kubectl get pods -n "${NAMESPACE}" --no-headers 2>/dev/null | wc -l | tr -d ' ')
        if [[ "${pods}" -eq 0 ]]; then
            log_info "Deleting namespace: ${NAMESPACE}"
            kubectl delete namespace "${NAMESPACE}" --wait=false 2>/dev/null || true
        else
            log_warn "Namespace ${NAMESPACE} still has ${pods} pods, skipping deletion"
        fi
    fi
}

main() {
    log_info "Starting Prometheus + Grafana uninstallation..."

    setup_kubeconfig
    check_prerequisites

    # Check if cluster is accessible
    if ! kubectl cluster-info >/dev/null 2>&1; then
        log_warn "Cannot connect to Kubernetes cluster. Nothing to uninstall."
        exit 0
    fi

    if [[ "${FORCE}" != "true" ]]; then
        echo ""
        log_warn "This will uninstall Prometheus + Grafana from the cluster."
        log_warn "All metrics data will be lost."
        echo ""
        read -p "Continue? [y/N] " -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Aborted."
            exit 0
        fi
    fi

    # Uninstall in reverse order
    delete_virtualservices
    delete_istio_monitors
    uninstall_prometheus_stack
    cleanup_crds
    cleanup_namespace

    echo ""
    log_info "=========================================="
    log_info "Prometheus + Grafana uninstallation complete!"
    log_info "=========================================="
}

main "$@"
