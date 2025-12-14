#!/usr/bin/env bash
# loki-down.sh - Uninstall Loki + Promtail (idempotent)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOKI_DIR="${REPO_ROOT}/observability/loki"
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
            echo "Uninstall Loki + Promtail from the cluster."
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

# Delete datasource
delete_datasource() {
    log_info "Deleting Loki datasource..."
    kubectl delete -f "${LOKI_DIR}/resources/grafana-datasource.yaml" --ignore-not-found=true 2>/dev/null || true
}

# Uninstall Promtail
uninstall_promtail() {
    if release_exists "promtail"; then
        log_info "Uninstalling Promtail..."
        helm uninstall promtail -n "${NAMESPACE}" --wait
    else
        log_info "promtail not found (nothing to uninstall)"
    fi
}

# Uninstall Loki
uninstall_loki() {
    if release_exists "loki"; then
        log_info "Uninstalling Loki..."
        helm uninstall loki -n "${NAMESPACE}" --wait
    else
        log_info "loki not found (nothing to uninstall)"
    fi
}

main() {
    log_info "Starting Loki + Promtail uninstallation..."

    setup_kubeconfig
    check_prerequisites

    # Check if cluster is accessible
    if ! kubectl cluster-info >/dev/null 2>&1; then
        log_warn "Cannot connect to Kubernetes cluster. Nothing to uninstall."
        exit 0
    fi

    if [[ "${FORCE}" != "true" ]]; then
        echo ""
        log_warn "This will uninstall Loki + Promtail from the cluster."
        log_warn "All log data will be lost."
        echo ""
        read -p "Continue? [y/N] " -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Aborted."
            exit 0
        fi
    fi

    # Uninstall in reverse order
    delete_datasource
    uninstall_promtail
    uninstall_loki

    echo ""
    log_info "=========================================="
    log_info "Loki + Promtail uninstallation complete!"
    log_info "=========================================="
}

main "$@"
