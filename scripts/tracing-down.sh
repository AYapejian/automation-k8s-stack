#!/usr/bin/env bash
# tracing-down.sh - Uninstall distributed tracing stack (idempotent)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
NAMESPACE="observability"
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
            echo "Uninstall distributed tracing stack from the cluster."
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
    helm status "${release_name}" -n "${NAMESPACE}" >/dev/null 2>&1
}

# Disable Istio tracing
disable_istio_tracing() {
    log_info "Disabling Istio tracing..."
    # Remove tracing configuration from Istio
    kubectl patch telemetry default -n istio-system --type=json \
        -p='[{"op": "remove", "path": "/spec/tracing"}]' 2>/dev/null || true
}

# Delete resources
delete_resources() {
    log_info "Deleting tracing resources..."
    kubectl delete -f "${REPO_ROOT}/observability/jaeger/resources/" --ignore-not-found=true 2>/dev/null || true
    kubectl delete -f "${REPO_ROOT}/observability/tempo/resources/" --ignore-not-found=true 2>/dev/null || true
}

# Uninstall OTel Collector
uninstall_otel_collector() {
    if release_exists "otel-collector"; then
        log_info "Uninstalling OTel Collector..."
        helm uninstall otel-collector -n "${NAMESPACE}" --wait
    else
        log_info "otel-collector not found (nothing to uninstall)"
    fi
}

# Uninstall Jaeger
uninstall_jaeger() {
    if release_exists "jaeger"; then
        log_info "Uninstalling Jaeger..."
        helm uninstall jaeger -n "${NAMESPACE}" --wait
    else
        log_info "jaeger not found (nothing to uninstall)"
    fi
}

# Uninstall Tempo
uninstall_tempo() {
    if release_exists "tempo"; then
        log_info "Uninstalling Tempo..."
        helm uninstall tempo -n "${NAMESPACE}" --wait
    else
        log_info "tempo not found (nothing to uninstall)"
    fi
}

main() {
    log_info "Starting tracing stack uninstallation..."

    setup_kubeconfig
    check_prerequisites

    # Check if cluster is accessible
    if ! kubectl cluster-info >/dev/null 2>&1; then
        log_warn "Cannot connect to Kubernetes cluster. Nothing to uninstall."
        exit 0
    fi

    if [[ "${FORCE}" != "true" ]]; then
        echo ""
        log_warn "This will uninstall the distributed tracing stack from the cluster."
        log_warn "Trace data in memory (Jaeger) will be lost."
        echo ""
        read -p "Continue? [y/N] " -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Aborted."
            exit 0
        fi
    fi

    # Uninstall in reverse order
    disable_istio_tracing
    delete_resources
    uninstall_otel_collector
    uninstall_jaeger
    uninstall_tempo

    echo ""
    log_info "=========================================="
    log_info "Tracing stack uninstallation complete!"
    log_info "=========================================="
}

main "$@"
