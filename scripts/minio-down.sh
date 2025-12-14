#!/usr/bin/env bash
# minio-down.sh - Uninstall Minio (idempotent)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
MINIO_DIR="${REPO_ROOT}/platform/minio"
NAMESPACE="minio"
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
DELETE_PVC=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --force|-f)
            FORCE=true
            shift
            ;;
        --delete-pvc)
            DELETE_PVC=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [--force] [--delete-pvc]"
            echo ""
            echo "Uninstall Minio from the cluster."
            echo ""
            echo "Options:"
            echo "  --force, -f   Skip confirmation prompt"
            echo "  --delete-pvc  Also delete PVCs (data will be lost)"
            echo "  -h, --help    Show this help message"
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

# Delete VirtualService
delete_virtualservice() {
    log_info "Deleting Minio VirtualService..."
    kubectl delete -f "${MINIO_DIR}/resources/virtualservice.yaml" --ignore-not-found=true 2>/dev/null || true
}

# Uninstall Minio
uninstall_minio() {
    if release_exists "minio"; then
        log_info "Uninstalling Minio..."
        helm uninstall minio -n "${NAMESPACE}" --wait
    else
        log_info "minio release not found (nothing to uninstall)"
    fi
}

# Delete secrets
delete_secrets() {
    log_info "Deleting Minio secrets..."
    kubectl delete -f "${MINIO_DIR}/resources/secret.yaml" --ignore-not-found=true 2>/dev/null || true
}

# Delete PVCs if requested
delete_pvcs() {
    if [[ "${DELETE_PVC}" == "true" ]]; then
        log_warn "Deleting PVCs..."
        kubectl delete pvc -n "${NAMESPACE}" -l app.kubernetes.io/name=minio --ignore-not-found=true 2>/dev/null || true
    fi
}

# Delete namespace
delete_namespace() {
    log_info "Deleting namespace ${NAMESPACE}..."
    kubectl delete namespace "${NAMESPACE}" --ignore-not-found=true 2>/dev/null || true
}

main() {
    log_info "Starting Minio uninstallation..."

    setup_kubeconfig
    check_prerequisites

    # Check if cluster is accessible
    if ! kubectl cluster-info >/dev/null 2>&1; then
        log_warn "Cannot connect to Kubernetes cluster. Nothing to uninstall."
        exit 0
    fi

    if [[ "${FORCE}" != "true" ]]; then
        echo ""
        log_warn "This will uninstall Minio from the cluster."
        if [[ "${DELETE_PVC}" == "true" ]]; then
            log_warn "All data in PVCs will also be deleted!"
        fi
        echo ""
        read -p "Continue? [y/N] " -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Aborted."
            exit 0
        fi
    fi

    # Uninstall in reverse order
    delete_virtualservice
    uninstall_minio
    delete_secrets
    delete_pvcs
    delete_namespace

    echo ""
    log_info "=========================================="
    log_info "Minio uninstallation complete!"
    log_info "=========================================="
}

main "$@"
