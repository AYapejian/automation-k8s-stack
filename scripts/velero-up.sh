#!/usr/bin/env bash
# velero-up.sh - Install Velero backup system via Helm (idempotent)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VELERO_DIR="${REPO_ROOT}/platform/velero"
CHART_VERSION="7.2.1"
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
        log_error "Cannot connect to Kubernetes cluster. Is the cluster running?"
        log_error "Run 'make cluster-up' first."
        exit 1
    fi

    # Check if Minio is installed (required for backup storage)
    if ! kubectl get namespace minio >/dev/null 2>&1; then
        log_error "Minio namespace not found. Run 'make minio-up' first."
        exit 1
    fi

    if ! kubectl get pods -n minio -l release=minio -o name 2>/dev/null | head -1 | grep -q pod; then
        log_error "Minio pod not found. Run 'make minio-up' first."
        exit 1
    fi

    # Check if config directory exists
    if [[ ! -d "${VELERO_DIR}" ]]; then
        log_error "Velero configuration directory not found: ${VELERO_DIR}"
        exit 1
    fi
}

# Add vmware-tanzu Helm repository
setup_helm_repo() {
    log_info "Setting up vmware-tanzu Helm repository..."
    if helm repo list 2>/dev/null | grep -qE "^vmware-tanzu[[:space:]]"; then
        helm repo update vmware-tanzu >/dev/null
    else
        helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts
        helm repo update >/dev/null
    fi
}

# Create namespace and apply resources
create_namespace() {
    log_info "Creating namespace ${NAMESPACE}..."
    kubectl apply -f "${VELERO_DIR}/resources/namespace.yaml"
}

# Apply credentials secret
apply_secret() {
    log_info "Applying Minio credentials secret..."
    kubectl apply -f "${VELERO_DIR}/resources/secret.yaml"
}

# Check if Helm release exists
release_exists() {
    helm status "${RELEASE_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1
}

# Install or upgrade Velero
install_velero() {
    log_info "Installing Velero (version ${CHART_VERSION})..."

    if release_exists; then
        log_info "${RELEASE_NAME} release exists, upgrading..."
        helm upgrade "${RELEASE_NAME}" vmware-tanzu/velero \
            -n "${NAMESPACE}" \
            --version "${CHART_VERSION}" \
            -f "${VELERO_DIR}/values.yaml" \
            --wait --timeout 10m
    else
        helm install "${RELEASE_NAME}" vmware-tanzu/velero \
            -n "${NAMESPACE}" \
            --version "${CHART_VERSION}" \
            -f "${VELERO_DIR}/values.yaml" \
            --wait --timeout 10m
    fi
}

# Apply backup schedule and storage location
apply_backup_config() {
    log_info "Waiting for Velero CRDs to be ready..."
    sleep 5

    # Wait for Velero deployment to be ready first
    kubectl wait --for=condition=Available deployment/velero -n "${NAMESPACE}" --timeout=180s || {
        log_warn "Velero deployment not ready, continuing anyway..."
    }

    log_info "Applying backup storage location and schedule..."
    kubectl apply -f "${VELERO_DIR}/resources/backup-schedule.yaml"
}

# Verify installation
verify_installation() {
    log_info "Verifying installation..."

    # Wait for Velero deployment
    if ! kubectl wait --for=condition=Available deployment/velero -n "${NAMESPACE}" --timeout=180s; then
        log_error "Velero deployment not ready"
        kubectl get pods -n "${NAMESPACE}"
        exit 1
    fi

    # Check node agent (restic) daemonset
    log_info "Checking node agent pods..."
    kubectl get daemonset -n "${NAMESPACE}" || true

    log_info "Installation verified successfully!"
}

# Print status and usage info
print_info() {
    echo ""
    log_info "=========================================="
    log_info "Velero installed successfully!"
    log_info "=========================================="
    echo ""
    echo "Helm release:"
    helm list -n "${NAMESPACE}"
    echo ""
    echo "Pods:"
    kubectl get pods -n "${NAMESPACE}"
    echo ""
    echo "Backup storage location:"
    kubectl get backupstoragelocation -n "${NAMESPACE}" || echo "  (not yet ready)"
    echo ""
    echo "Scheduled backups:"
    kubectl get schedules.velero.io -n "${NAMESPACE}" || echo "  (none)"
    echo ""
    echo "Useful commands:"
    echo "  # Create a manual backup"
    echo "  kubectl exec -n velero deploy/velero -- velero backup create my-backup"
    echo ""
    echo "  # List backups"
    echo "  kubectl exec -n velero deploy/velero -- velero backup get"
    echo ""
    echo "  # Restore from backup"
    echo "  kubectl exec -n velero deploy/velero -- velero restore create --from-backup my-backup"
    echo ""
    echo "  # Check status"
    echo "  make velero-status"
    echo ""
}

main() {
    log_info "Starting Velero installation..."

    setup_kubeconfig
    check_prerequisites
    setup_helm_repo
    create_namespace
    apply_secret
    install_velero
    apply_backup_config
    verify_installation
    print_info

    log_info "Done!"
}

main "$@"
