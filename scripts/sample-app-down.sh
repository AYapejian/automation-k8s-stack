#!/usr/bin/env bash
# sample-app-down.sh - Remove sample httpbin application (idempotent)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SAMPLE_APP_DIR="${REPO_ROOT}/apps/sample/httpbin"
SAMPLE_NAMESPACE="ingress-sample"
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

# Delete application resources
delete_resources() {
    log_info "Deleting httpbin application resources..."

    # Delete resources from the app directory
    if [[ -d "${SAMPLE_APP_DIR}" ]]; then
        kubectl delete -f "${SAMPLE_APP_DIR}/virtual-service.yaml" --ignore-not-found || true
        kubectl delete -f "${SAMPLE_APP_DIR}/service.yaml" --ignore-not-found || true
        kubectl delete -f "${SAMPLE_APP_DIR}/deployment.yaml" --ignore-not-found || true
    fi

    log_info "Application resources deleted."
}

# Delete namespace
delete_namespace() {
    log_info "Deleting namespace ${SAMPLE_NAMESPACE}..."

    if kubectl get namespace "${SAMPLE_NAMESPACE}" >/dev/null 2>&1; then
        kubectl delete namespace "${SAMPLE_NAMESPACE}" --ignore-not-found
        log_info "Namespace deleted."
    else
        log_info "Namespace not found, skipping."
    fi
}

# Print status
print_info() {
    echo ""
    log_info "=========================================="
    log_info "Sample httpbin app removed!"
    log_info "=========================================="
    echo ""
    echo "To redeploy:"
    echo "  make sample-app-up"
    echo ""
}

main() {
    log_info "Removing sample httpbin application..."

    check_prerequisites
    delete_resources
    delete_namespace
    print_info

    log_info "Done!"
}

main "$@"
