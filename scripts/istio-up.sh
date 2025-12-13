#!/usr/bin/env bash
# istio-up.sh - Install Istio service mesh via Helm (idempotent)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ISTIO_DIR="${REPO_ROOT}/platform/istio"
ISTIO_VERSION="1.24.0"
ISTIO_NAMESPACE="istio-system"
ISTIO_INGRESS_NAMESPACE="istio-ingress"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

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

    # Check if cluster is accessible
    if ! kubectl cluster-info >/dev/null 2>&1; then
        log_error "Cannot connect to Kubernetes cluster. Is the cluster running?"
        log_error "Run 'make cluster-up' first."
        exit 1
    fi

    # Check if Istio values files exist
    if [[ ! -d "${ISTIO_DIR}" ]]; then
        log_error "Istio configuration directory not found: ${ISTIO_DIR}"
        exit 1
    fi
}

# Add Istio Helm repository
setup_helm_repo() {
    log_info "Setting up Istio Helm repository..."
    if helm repo list 2>/dev/null | grep -q "^istio"; then
        helm repo update istio >/dev/null
    else
        helm repo add istio https://istio-release.storage.googleapis.com/charts
        helm repo update >/dev/null
    fi
}

# Check if Helm release exists
release_exists() {
    local release_name="$1"
    local namespace="$2"
    helm status "${release_name}" -n "${namespace}" >/dev/null 2>&1
}

# Install or upgrade istio-base (CRDs)
install_base() {
    log_info "Installing Istio base (CRDs)..."

    if release_exists "istio-base" "${ISTIO_NAMESPACE}"; then
        log_info "istio-base already installed, upgrading..."
        helm upgrade istio-base istio/base \
            -n "${ISTIO_NAMESPACE}" \
            --version "${ISTIO_VERSION}" \
            -f "${ISTIO_DIR}/base/values.yaml" \
            --wait
    else
        helm install istio-base istio/base \
            -n "${ISTIO_NAMESPACE}" \
            --create-namespace \
            --version "${ISTIO_VERSION}" \
            -f "${ISTIO_DIR}/base/values.yaml" \
            --wait
    fi
}

# Install or upgrade istiod (control plane)
install_istiod() {
    log_info "Installing Istiod (control plane)..."

    if release_exists "istiod" "${ISTIO_NAMESPACE}"; then
        log_info "istiod already installed, upgrading..."
        helm upgrade istiod istio/istiod \
            -n "${ISTIO_NAMESPACE}" \
            --version "${ISTIO_VERSION}" \
            -f "${ISTIO_DIR}/istiod/values.yaml" \
            --wait --timeout 5m
    else
        helm install istiod istio/istiod \
            -n "${ISTIO_NAMESPACE}" \
            --version "${ISTIO_VERSION}" \
            -f "${ISTIO_DIR}/istiod/values.yaml" \
            --wait --timeout 5m
    fi
}

# Install or upgrade istio-ingress gateway
install_gateway() {
    log_info "Installing Istio Ingress Gateway..."

    # Create namespace if it doesn't exist
    kubectl create namespace "${ISTIO_INGRESS_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

    # Label namespace for sidecar injection
    kubectl label namespace "${ISTIO_INGRESS_NAMESPACE}" istio-injection=enabled --overwrite

    if release_exists "istio-ingress" "${ISTIO_INGRESS_NAMESPACE}"; then
        log_info "istio-ingress already installed, upgrading..."
        helm upgrade istio-ingress istio/gateway \
            -n "${ISTIO_INGRESS_NAMESPACE}" \
            --version "${ISTIO_VERSION}" \
            -f "${ISTIO_DIR}/gateway/values.yaml" \
            --wait --timeout 5m
    else
        helm install istio-ingress istio/gateway \
            -n "${ISTIO_INGRESS_NAMESPACE}" \
            --version "${ISTIO_VERSION}" \
            -f "${ISTIO_DIR}/gateway/values.yaml" \
            --wait --timeout 5m
    fi
}

# Apply security and telemetry resources
apply_resources() {
    log_info "Applying Istio security and telemetry resources..."
    kubectl apply -f "${ISTIO_DIR}/resources/"
}

# Verify installation
verify_installation() {
    log_info "Verifying Istio installation..."

    # Check istiod is running
    if ! kubectl wait --for=condition=Available deployment/istiod -n "${ISTIO_NAMESPACE}" --timeout=120s; then
        log_error "Istiod deployment not ready"
        kubectl get pods -n "${ISTIO_NAMESPACE}"
        exit 1
    fi

    # Check gateway is running
    if ! kubectl wait --for=condition=Available deployment/istio-ingress -n "${ISTIO_INGRESS_NAMESPACE}" --timeout=120s; then
        log_error "Istio ingress gateway not ready"
        kubectl get pods -n "${ISTIO_INGRESS_NAMESPACE}"
        exit 1
    fi

    log_info "Istio installation verified successfully!"
}

# Print status and usage info
print_info() {
    echo ""
    log_info "=========================================="
    log_info "Istio Service Mesh installed successfully!"
    log_info "=========================================="
    echo ""
    echo "Helm releases:"
    helm list -n "${ISTIO_NAMESPACE}"
    helm list -n "${ISTIO_INGRESS_NAMESPACE}"
    echo ""
    echo "Istio pods:"
    kubectl get pods -n "${ISTIO_NAMESPACE}"
    kubectl get pods -n "${ISTIO_INGRESS_NAMESPACE}"
    echo ""
    echo "To enable sidecar injection in a namespace:"
    echo "  kubectl label namespace <namespace> istio-injection=enabled"
    echo ""
    echo "To verify mTLS is enforced:"
    echo "  kubectl get peerauthentication -n istio-system"
    echo ""
    echo "Useful commands:"
    echo "  make istio-status   # Check Istio status"
    echo "  make istio-down     # Uninstall Istio"
    echo ""
}

main() {
    log_info "Starting Istio installation (version ${ISTIO_VERSION})..."

    check_prerequisites
    setup_helm_repo
    install_base
    install_istiod
    install_gateway
    apply_resources
    verify_installation
    print_info

    log_info "Done!"
}

main "$@"
