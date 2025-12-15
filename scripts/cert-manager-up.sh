#!/usr/bin/env bash
# cert-manager-up.sh - Install cert-manager via Helm (idempotent)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CERT_MANAGER_DIR="${REPO_ROOT}/platform/cert-manager"
CERT_MANAGER_VERSION="v1.16.2"
CERT_MANAGER_NAMESPACE="cert-manager"
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

    # Check if cert-manager values files exist
    if [[ ! -d "${CERT_MANAGER_DIR}" ]]; then
        log_error "cert-manager configuration directory not found: ${CERT_MANAGER_DIR}"
        exit 1
    fi
}

# Add Jetstack Helm repository
setup_helm_repo() {
    log_info "Setting up Jetstack Helm repository..."
    if helm repo list 2>/dev/null | grep -qE "^jetstack[[:space:]]"; then
        helm repo update jetstack >/dev/null
    else
        helm repo add jetstack https://charts.jetstack.io
        helm repo update >/dev/null
    fi
}

# Check if Helm release exists
release_exists() {
    local release_name="$1"
    local namespace="$2"
    helm status "${release_name}" -n "${namespace}" >/dev/null 2>&1
}

# Install or upgrade cert-manager
install_cert_manager() {
    log_info "Installing cert-manager (version ${CERT_MANAGER_VERSION})..."

    if release_exists "cert-manager" "${CERT_MANAGER_NAMESPACE}"; then
        log_info "cert-manager already installed, upgrading..."
        helm upgrade cert-manager jetstack/cert-manager \
            -n "${CERT_MANAGER_NAMESPACE}" \
            --version "${CERT_MANAGER_VERSION}" \
            -f "${CERT_MANAGER_DIR}/values.yaml" \
            --wait --timeout 5m
    else
        helm install cert-manager jetstack/cert-manager \
            -n "${CERT_MANAGER_NAMESPACE}" \
            --create-namespace \
            --version "${CERT_MANAGER_VERSION}" \
            -f "${CERT_MANAGER_DIR}/values.yaml" \
            --wait --timeout 5m
    fi
}

# Wait for webhook to be ready before applying resources
wait_for_webhook() {
    log_info "Waiting for cert-manager webhook to be ready..."

    # Wait for webhook deployment
    if ! kubectl wait --for=condition=Available deployment/cert-manager-webhook \
        -n "${CERT_MANAGER_NAMESPACE}" --timeout=120s; then
        log_error "cert-manager webhook not ready"
        kubectl get pods -n "${CERT_MANAGER_NAMESPACE}"
        exit 1
    fi

    # Give webhook a moment to start accepting requests
    # This prevents "webhook not ready" errors when applying ClusterIssuers
    sleep 5
}

# Apply ClusterIssuer and CA resources
apply_resources() {
    log_info "Applying cert-manager ClusterIssuer and CA resources..."

    # Apply resources with retry logic for webhook availability
    local max_attempts=5
    local attempt=1

    while [[ ${attempt} -le ${max_attempts} ]]; do
        if kubectl apply -k "${CERT_MANAGER_DIR}/resources/"; then
            log_info "Resources applied successfully"
            break
        else
            if [[ ${attempt} -eq ${max_attempts} ]]; then
                log_error "Failed to apply resources after ${max_attempts} attempts"
                exit 1
            fi
            log_warn "Attempt ${attempt}/${max_attempts} failed, retrying in 10s..."
            sleep 10
            ((attempt++))
        fi
    done
}

# Wait for ClusterIssuers to be ready
wait_for_issuers() {
    log_info "Waiting for ClusterIssuers to be ready..."

    # Wait for selfsigned-issuer
    if ! kubectl wait --for=condition=Ready clusterissuer/selfsigned-issuer --timeout=60s; then
        log_error "selfsigned-issuer not ready"
        kubectl describe clusterissuer selfsigned-issuer
        exit 1
    fi

    # Wait for CA certificate to be issued
    log_info "Waiting for CA certificate to be issued..."
    if ! kubectl wait --for=condition=Ready certificate/selfsigned-ca \
        -n "${CERT_MANAGER_NAMESPACE}" --timeout=60s; then
        log_error "CA certificate not ready"
        kubectl describe certificate selfsigned-ca -n "${CERT_MANAGER_NAMESPACE}"
        exit 1
    fi

    # Wait for automation-ca-issuer (depends on CA certificate)
    if ! kubectl wait --for=condition=Ready clusterissuer/automation-ca-issuer --timeout=60s; then
        log_error "automation-ca-issuer not ready"
        kubectl describe clusterissuer automation-ca-issuer
        exit 1
    fi

    log_info "All ClusterIssuers are ready!"
}

# Verify installation
verify_installation() {
    log_info "Verifying cert-manager installation..."

    # Check all cert-manager pods are running
    if ! kubectl wait --for=condition=Ready pods --all -n "${CERT_MANAGER_NAMESPACE}" --timeout=120s; then
        log_error "cert-manager pods not ready"
        kubectl get pods -n "${CERT_MANAGER_NAMESPACE}"
        exit 1
    fi

    log_info "cert-manager installation verified successfully!"
}

# Print status and usage info
print_info() {
    echo ""
    log_info "=========================================="
    log_info "cert-manager installed successfully!"
    log_info "=========================================="
    echo ""
    echo "Helm release:"
    helm list -n "${CERT_MANAGER_NAMESPACE}"
    echo ""
    echo "cert-manager pods:"
    kubectl get pods -n "${CERT_MANAGER_NAMESPACE}"
    echo ""
    echo "ClusterIssuers:"
    kubectl get clusterissuers
    echo ""
    echo "CA Certificate:"
    kubectl get certificate -n "${CERT_MANAGER_NAMESPACE}"
    echo ""
    echo "To request a certificate, create a Certificate resource:"
    echo "  apiVersion: cert-manager.io/v1"
    echo "  kind: Certificate"
    echo "  metadata:"
    echo "    name: my-cert"
    echo "    namespace: my-namespace"
    echo "  spec:"
    echo "    secretName: my-cert-secret"
    echo "    issuerRef:"
    echo "      name: automation-ca-issuer"
    echo "      kind: ClusterIssuer"
    echo "    dnsNames:"
    echo "      - my-app.localhost"
    echo ""
    echo "Useful commands:"
    echo "  make cert-manager-status  # Check cert-manager status"
    echo "  make cert-manager-down    # Uninstall cert-manager"
    echo ""
}

main() {
    log_info "Starting cert-manager installation..."

    check_prerequisites
    setup_helm_repo
    install_cert_manager
    wait_for_webhook
    apply_resources
    wait_for_issuers
    verify_installation
    print_info

    log_info "Done!"
}

main "$@"
