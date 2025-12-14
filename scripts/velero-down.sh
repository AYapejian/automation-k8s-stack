#!/usr/bin/env bash
# velero-down.sh - Uninstall Velero (idempotent)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
NAMESPACE="velero"
RELEASE_NAME="velero"
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
            echo "Uninstall Velero from the cluster."
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
}

# Check if Helm release exists
release_exists() {
    helm status "${RELEASE_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1
}

# Delete backup resources
delete_backup_resources() {
    log_info "Deleting backup resources..."
    kubectl delete schedules.velero.io --all -n "${NAMESPACE}" --ignore-not-found=true 2>/dev/null || true
    kubectl delete backups.velero.io --all -n "${NAMESPACE}" --ignore-not-found=true 2>/dev/null || true
    kubectl delete restores.velero.io --all -n "${NAMESPACE}" --ignore-not-found=true 2>/dev/null || true
    kubectl delete backupstoragelocation --all -n "${NAMESPACE}" --ignore-not-found=true 2>/dev/null || true
}

# Uninstall Velero
uninstall_velero() {
    if release_exists; then
        log_info "Uninstalling Velero..."
        helm uninstall "${RELEASE_NAME}" -n "${NAMESPACE}" --wait
    else
        log_info "Velero not found (nothing to uninstall)"
    fi
}

# Delete namespace
delete_namespace() {
    if kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1; then
        log_info "Deleting namespace ${NAMESPACE}..."
        kubectl delete namespace "${NAMESPACE}" --wait --timeout=120s || {
            log_warn "Namespace deletion timed out, forcing..."
            kubectl delete namespace "${NAMESPACE}" --force --grace-period=0 2>/dev/null || true
        }
    else
        log_info "Namespace ${NAMESPACE} not found"
    fi
}

main() {
    log_info "Starting Velero uninstallation..."

    setup_kubeconfig
    check_prerequisites

    # Check if cluster is accessible
    if ! kubectl cluster-info >/dev/null 2>&1; then
        log_warn "Cannot connect to Kubernetes cluster. Nothing to uninstall."
        exit 0
    fi

    if [[ "${FORCE}" != "true" ]]; then
        echo ""
        log_warn "This will uninstall Velero and delete all backup configurations."
        log_warn "Backups stored in Minio will NOT be deleted."
        echo ""
        read -p "Continue? [y/N] " -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Aborted."
            exit 0
        fi
    fi

    delete_backup_resources
    uninstall_velero
    delete_namespace

    echo ""
    log_info "=========================================="
    log_info "Velero uninstallation complete!"
    log_info "=========================================="
}

main "$@"
