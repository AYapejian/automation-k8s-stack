#!/usr/bin/env bash
# minio-up.sh - Install Minio object storage (idempotent)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
MINIO_DIR="${REPO_ROOT}/platform/minio"
MINIO_CHART_VERSION="5.2.0"
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
            log_info "Using k3d kubeconfig: ${kubeconfig}"
        fi
    fi
}

# Check prerequisites
check_prerequisites() {
    local missing=()

    command -v helm >/dev/null 2>&1 || missing+=("helm")
    command -v kubectl >/dev/null 2>&1 || missing+=("kubectl")

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required tools: ${missing[*]}"
        exit 1
    fi

    # Check if cluster is accessible
    if ! kubectl cluster-info >/dev/null 2>&1; then
        log_error "Cannot connect to Kubernetes cluster."
        exit 1
    fi
}

# Add Minio Helm repository
setup_helm_repo() {
    log_info "Setting up Minio Helm repository..."
    if helm repo list 2>/dev/null | grep -qE "^minio[[:space:]]"; then
        helm repo update minio >/dev/null
    else
        helm repo add minio https://charts.min.io/
        helm repo update >/dev/null
    fi
}

# Create namespace if it doesn't exist
create_namespace() {
    log_info "Creating namespace ${NAMESPACE}..."
    kubectl apply -f "${MINIO_DIR}/resources/namespace.yaml"
}

# Apply secrets
apply_secrets() {
    log_info "Applying Minio credentials secret..."
    kubectl apply -f "${MINIO_DIR}/resources/secret.yaml"
}

# Check if Helm release exists
release_exists() {
    local release_name="$1"
    helm status "${release_name}" -n "${NAMESPACE}" >/dev/null 2>&1
}

# Install or upgrade Minio
install_minio() {
    log_info "Installing Minio (version ${MINIO_CHART_VERSION})..."

    if release_exists "minio"; then
        log_info "minio release exists, upgrading..."
        helm upgrade minio minio/minio \
            -n "${NAMESPACE}" \
            --version "${MINIO_CHART_VERSION}" \
            -f "${MINIO_DIR}/values.yaml" \
            --wait --timeout 5m
    else
        helm install minio minio/minio \
            -n "${NAMESPACE}" \
            --version "${MINIO_CHART_VERSION}" \
            -f "${MINIO_DIR}/values.yaml" \
            --wait --timeout 5m
    fi
}

# Apply VirtualService for console access
apply_virtualservice() {
    log_info "Applying VirtualService for Minio console..."
    kubectl apply -f "${MINIO_DIR}/resources/virtualservice.yaml"
}

# Verify installation
verify_installation() {
    log_info "Verifying installation..."

    # Wait for Minio pod
    log_info "Waiting for Minio pod..."
    if ! kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=minio \
        -n "${NAMESPACE}" --timeout=180s; then
        log_error "Minio pod not ready"
        kubectl get pods -n "${NAMESPACE}"
        kubectl describe pod -l app.kubernetes.io/name=minio -n "${NAMESPACE}"
        exit 1
    fi

    # Verify buckets were created (job should have completed)
    log_info "Checking bucket creation job..."
    local job_status
    job_status=$(kubectl get job -n "${NAMESPACE}" -l app.kubernetes.io/name=minio-make-bucket-job -o jsonpath='{.items[0].status.succeeded}' 2>/dev/null || echo "0")
    if [[ "${job_status}" == "1" ]]; then
        log_info "Bucket creation job completed successfully"
    else
        log_warn "Bucket creation job may still be running or not yet started"
        kubectl get jobs -n "${NAMESPACE}" 2>/dev/null || true
    fi

    log_info "Installation verified successfully!"
}

# Print status and usage info
print_info() {
    echo ""
    log_info "=========================================="
    log_info "Minio installed successfully!"
    log_info "=========================================="
    echo ""
    echo "Helm release:"
    helm list -n "${NAMESPACE}" | grep minio
    echo ""
    echo "Pods:"
    kubectl get pods -n "${NAMESPACE}"
    echo ""
    echo "Services:"
    kubectl get svc -n "${NAMESPACE}"
    echo ""
    echo "Buckets created:"
    echo "  - loki-chunks   (for Loki log storage)"
    echo "  - tempo-traces  (for Tempo trace storage)"
    echo "  - velero        (for Velero backups)"
    echo ""
    echo "Internal endpoints:"
    echo "  API:     http://minio.minio.svc.cluster.local:9000"
    echo "  Console: http://minio-console.minio.svc.cluster.local:9001"
    echo ""
    echo "To access the Minio console:"
    echo "  1. Open https://minio.localhost:8443"
    echo "  2. Login with minioadmin / minioadmin123"
    echo ""
    echo "Useful commands:"
    echo "  make minio-status  # Check status"
    echo "  make minio-down    # Uninstall"
    echo ""
}

main() {
    log_info "Starting Minio installation..."

    setup_kubeconfig
    check_prerequisites
    setup_helm_repo
    create_namespace
    apply_secrets
    install_minio
    apply_virtualservice
    verify_installation
    print_info

    log_info "Done!"
}

main "$@"
