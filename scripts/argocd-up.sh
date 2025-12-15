#!/usr/bin/env bash
# argocd-up.sh - Bootstrap ArgoCD installation (idempotent)
#
# This script installs ArgoCD via Helm. ArgoCD then manages itself and
# all other cluster resources via GitOps.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ARGOCD_DIR="${REPO_ROOT}/argocd/bootstrap"
ARGOCD_CHART_VERSION="9.1.7"
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

# Check prerequisites
check_prerequisites() {
    local missing=()

    command -v helm >/dev/null 2>&1 || missing+=("helm")
    command -v kubectl >/dev/null 2>&1 || missing+=("kubectl")

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required tools: ${missing[*]}"
        log_error "Install helm: brew install helm (macOS) or follow https://helm.sh/docs/intro/install/"
        exit 1
    fi

    # Check helm version (requires 3.x)
    local helm_version
    helm_version=$(helm version --short 2>/dev/null | grep -oE 'v[0-9]+' | head -1 | cut -c2-)
    if [[ -n "${helm_version}" ]] && [[ "${helm_version}" -lt 3 ]]; then
        log_error "Helm 3.x is required (found v${helm_version})"
        exit 1
    fi

    # Setup k3d kubeconfig
    setup_kubeconfig

    # Check if cluster is accessible
    if ! kubectl cluster-info >/dev/null 2>&1; then
        log_error "Cannot connect to Kubernetes cluster. Is the cluster running?"
        log_error "Run 'make cluster-up' first."
        exit 1
    fi

    # Verify we're connected to the right cluster
    local current_context
    current_context=$(kubectl config current-context 2>/dev/null || echo "unknown")
    log_info "Connected to cluster context: ${current_context}"

    # Check if ArgoCD bootstrap config exists
    if [[ ! -d "${ARGOCD_DIR}" ]]; then
        log_error "ArgoCD configuration directory not found: ${ARGOCD_DIR}"
        exit 1
    fi
}

# Add Argo Helm repository
setup_helm_repo() {
    log_info "Setting up Argo Helm repository..."
    if helm repo list 2>/dev/null | grep -qE "^argo[[:space:]]"; then
        helm repo update argo >/dev/null
    else
        helm repo add argo https://argoproj.github.io/argo-helm
        helm repo update >/dev/null
    fi
}

# Check if Helm release exists
release_exists() {
    local release_name="$1"
    local namespace="$2"
    helm status "${release_name}" -n "${namespace}" >/dev/null 2>&1
}

# Install or upgrade ArgoCD
install_argocd() {
    log_info "Installing ArgoCD (chart version ${ARGOCD_CHART_VERSION})..."

    # Create namespace if it doesn't exist
    kubectl apply -f "${ARGOCD_DIR}/namespace.yaml"

    if release_exists "${RELEASE_NAME}" "${ARGOCD_NAMESPACE}"; then
        log_info "ArgoCD already installed, upgrading..."
        helm upgrade "${RELEASE_NAME}" argo/argo-cd \
            -n "${ARGOCD_NAMESPACE}" \
            --version "${ARGOCD_CHART_VERSION}" \
            -f "${ARGOCD_DIR}/values.yaml" \
            --wait --timeout 10m
    else
        helm install "${RELEASE_NAME}" argo/argo-cd \
            -n "${ARGOCD_NAMESPACE}" \
            --version "${ARGOCD_CHART_VERSION}" \
            -f "${ARGOCD_DIR}/values.yaml" \
            --wait --timeout 10m
    fi
}

# Wait for ArgoCD to be ready
wait_for_argocd() {
    log_info "Waiting for ArgoCD to be ready..."

    # Wait for server deployment
    if ! kubectl wait --for=condition=Available deployment/argocd-server \
        -n "${ARGOCD_NAMESPACE}" --timeout=300s; then
        log_error "ArgoCD server not ready"
        kubectl get pods -n "${ARGOCD_NAMESPACE}"
        kubectl describe deployment/argocd-server -n "${ARGOCD_NAMESPACE}"
        exit 1
    fi

    # Wait for application controller
    if ! kubectl wait --for=condition=Available deployment/argocd-application-controller \
        -n "${ARGOCD_NAMESPACE}" --timeout=300s 2>/dev/null; then
        # Older versions use StatefulSet, check for that
        if ! kubectl rollout status statefulset/argocd-application-controller \
            -n "${ARGOCD_NAMESPACE}" --timeout=300s 2>/dev/null; then
            log_warn "Could not verify application controller status"
        fi
    fi

    # Wait for repo server
    if ! kubectl wait --for=condition=Available deployment/argocd-repo-server \
        -n "${ARGOCD_NAMESPACE}" --timeout=300s; then
        log_error "ArgoCD repo server not ready"
        kubectl get pods -n "${ARGOCD_NAMESPACE}"
        exit 1
    fi

    log_info "ArgoCD is ready!"
}

# Apply AppProjects
apply_projects() {
    local projects_dir="${REPO_ROOT}/argocd/projects"

    if [[ -d "${projects_dir}" ]] && [[ -n "$(ls -A "${projects_dir}" 2>/dev/null)" ]]; then
        log_info "Applying ArgoCD AppProjects..."
        kubectl apply -f "${projects_dir}/"
    else
        log_info "No AppProjects found, skipping..."
    fi
}

# Apply VirtualService for ingress (if Istio is installed)
apply_virtualservice() {
    local resources_dir="${REPO_ROOT}/argocd/resources"

    # Check if Istio CRDs exist
    if kubectl get crd virtualservices.networking.istio.io >/dev/null 2>&1; then
        if [[ -d "${resources_dir}" ]] && [[ -n "$(ls -A "${resources_dir}" 2>/dev/null)" ]]; then
            log_info "Applying ArgoCD VirtualService for Istio ingress..."
            kubectl apply -f "${resources_dir}/"
        else
            log_info "No VirtualService resources found, skipping..."
        fi
    else
        log_info "Istio CRDs not found, skipping VirtualService..."
    fi
}

# Get initial admin password
get_admin_password() {
    local password
    password=$(kubectl -n "${ARGOCD_NAMESPACE}" get secret argocd-initial-admin-secret \
        -o jsonpath="{.data.password}" 2>/dev/null | base64 -d) || true

    if [[ -n "${password}" ]]; then
        echo "${password}"
    else
        echo "(password secret not found - may have been deleted)"
    fi
}

# Verify installation
verify_installation() {
    log_info "Verifying ArgoCD installation..."

    # Check all pods are running or completed (init jobs complete successfully)
    # Note: grep -v returns exit 1 when no lines match, so we use || true
    local not_ready
    not_ready=$(kubectl get pods -n "${ARGOCD_NAMESPACE}" --no-headers 2>/dev/null | grep -vE "Running|Completed" | wc -l || true)

    if [[ "${not_ready}" -gt 0 ]]; then
        log_warn "Some ArgoCD pods are not ready:"
        kubectl get pods -n "${ARGOCD_NAMESPACE}"
    else
        log_info "All ArgoCD pods are running!"
    fi
}

# Print status and usage info
print_info() {
    echo ""
    log_info "=========================================="
    log_info "ArgoCD installed successfully!"
    log_info "=========================================="
    echo ""
    echo "Helm release:"
    helm list -n "${ARGOCD_NAMESPACE}"
    echo ""
    echo "ArgoCD pods:"
    kubectl get pods -n "${ARGOCD_NAMESPACE}"
    echo ""
    echo "ArgoCD services:"
    kubectl get svc -n "${ARGOCD_NAMESPACE}"
    echo ""
    echo "Access ArgoCD UI:"
    echo "  Port-forward: kubectl port-forward svc/argocd-server -n argocd 8080:443"
    echo "  Then open: https://localhost:8080"
    echo ""
    echo "  Or via Istio Gateway (if installed): https://argocd.localhost:8443"
    echo ""
    echo "Login credentials:"
    echo "  Username: admin"
    echo "  Password: $(get_admin_password)"
    echo ""
    echo "Useful commands:"
    echo "  make argocd-status    # Check ArgoCD status"
    echo "  make argocd-down      # Uninstall ArgoCD"
    echo ""
    echo "ArgoCD CLI (optional):"
    echo "  brew install argocd   # Install CLI"
    echo "  argocd login localhost:8080 --username admin --password <password> --insecure"
    echo ""
}

main() {
    log_info "Starting ArgoCD bootstrap installation..."

    check_prerequisites
    setup_helm_repo
    install_argocd
    wait_for_argocd
    apply_projects
    apply_virtualservice
    verify_installation
    print_info

    log_info "Done!"
}

main "$@"
