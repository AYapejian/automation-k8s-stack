#!/usr/bin/env bash
# argocd-down.sh - Uninstall ArgoCD (idempotent)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ARGOCD_NAMESPACE="argocd"
RELEASE_NAME="argocd"
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
            log_info "Using k3d cluster context: ${CLUSTER_NAME}"
        fi
    fi
}

# Check if Helm release exists
release_exists() {
    local release_name="$1"
    local namespace="$2"
    helm status "${release_name}" -n "${namespace}" >/dev/null 2>&1
}

# Delete all ArgoCD Applications first (to prevent finalizer issues)
delete_applications() {
    log_info "Deleting ArgoCD Applications..."

    # Remove finalizers from all applications to allow deletion
    local apps
    apps=$(kubectl get applications -n "${ARGOCD_NAMESPACE}" -o name 2>/dev/null || true)

    if [[ -n "${apps}" ]]; then
        for app in ${apps}; do
            log_info "Removing finalizers from ${app}..."
            kubectl patch "${app}" -n "${ARGOCD_NAMESPACE}" \
                --type json \
                -p='[{"op": "remove", "path": "/metadata/finalizers"}]' 2>/dev/null || true
        done

        # Delete all applications
        kubectl delete applications --all -n "${ARGOCD_NAMESPACE}" --timeout=60s 2>/dev/null || true
    fi
}

# Delete AppProjects
delete_projects() {
    log_info "Deleting ArgoCD AppProjects..."

    # Remove finalizers from all projects
    local projects
    projects=$(kubectl get appprojects -n "${ARGOCD_NAMESPACE}" -o name 2>/dev/null || true)

    if [[ -n "${projects}" ]]; then
        for project in ${projects}; do
            # Skip default project
            if [[ "${project}" == "appproject.argoproj.io/default" ]]; then
                continue
            fi
            log_info "Removing finalizers from ${project}..."
            kubectl patch "${project}" -n "${ARGOCD_NAMESPACE}" \
                --type json \
                -p='[{"op": "remove", "path": "/metadata/finalizers"}]' 2>/dev/null || true
        done

        # Delete all projects except default
        kubectl delete appprojects -n "${ARGOCD_NAMESPACE}" \
            --field-selector metadata.name!=default --timeout=60s 2>/dev/null || true
    fi
}

# Delete VirtualService if it exists
delete_virtualservice() {
    if kubectl get crd virtualservices.networking.istio.io >/dev/null 2>&1; then
        log_info "Deleting ArgoCD VirtualService..."
        kubectl delete virtualservice argocd -n "${ARGOCD_NAMESPACE}" 2>/dev/null || true
    fi
}

# Uninstall ArgoCD Helm release
uninstall_argocd() {
    if release_exists "${RELEASE_NAME}" "${ARGOCD_NAMESPACE}"; then
        log_info "Uninstalling ArgoCD Helm release..."
        helm uninstall "${RELEASE_NAME}" -n "${ARGOCD_NAMESPACE}" --wait --timeout 5m
    else
        log_info "ArgoCD Helm release not found, skipping..."
    fi
}

# Delete namespace
delete_namespace() {
    if kubectl get namespace "${ARGOCD_NAMESPACE}" >/dev/null 2>&1; then
        log_info "Deleting ArgoCD namespace..."
        kubectl delete namespace "${ARGOCD_NAMESPACE}" --timeout=120s
    else
        log_info "ArgoCD namespace not found, skipping..."
    fi
}

# Print completion message
print_info() {
    echo ""
    log_info "=========================================="
    log_info "ArgoCD uninstalled successfully!"
    log_info "=========================================="
    echo ""
    echo "To reinstall: make argocd-up"
    echo ""
}

main() {
    log_info "Starting ArgoCD uninstallation..."

    # Setup kubeconfig (best effort - kubectl may not be available)
    setup_kubeconfig 2>/dev/null || true

    # Check if kubectl is available and cluster is accessible
    if ! command -v kubectl >/dev/null 2>&1; then
        log_warn "kubectl not found, skipping Kubernetes cleanup"
        return 0
    fi

    if ! kubectl cluster-info >/dev/null 2>&1; then
        log_warn "Cannot connect to cluster, skipping cleanup"
        return 0
    fi

    delete_applications
    delete_projects
    delete_virtualservice
    uninstall_argocd
    delete_namespace
    print_info

    log_info "Done!"
}

main "$@"
