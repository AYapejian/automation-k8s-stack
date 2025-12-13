#!/usr/bin/env bash
# ingress-up.sh - Configure Istio Gateway and TLS certificates (idempotent)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
INGRESS_DIR="${REPO_ROOT}/platform/ingress"
ISTIO_INGRESS_NAMESPACE="istio-ingress"
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

    command -v kubectl >/dev/null 2>&1 || missing+=("kubectl")

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required tools: ${missing[*]}"
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

    # Check if Istio gateway is installed
    if ! kubectl get deployment istio-ingress -n "${ISTIO_INGRESS_NAMESPACE}" >/dev/null 2>&1; then
        log_error "Istio ingress gateway not found."
        log_error "Run 'make istio-up' first."
        exit 1
    fi

    # Check if cert-manager is installed
    if ! kubectl get deployment cert-manager -n cert-manager >/dev/null 2>&1; then
        log_error "cert-manager not found."
        log_error "Run 'make cert-manager-up' first."
        exit 1
    fi

    # Check if automation-ca-issuer exists
    if ! kubectl get clusterissuer automation-ca-issuer >/dev/null 2>&1; then
        log_error "ClusterIssuer automation-ca-issuer not found."
        log_error "Run 'make cert-manager-up' to create it."
        exit 1
    fi

    # Check if ingress config directory exists
    if [[ ! -d "${INGRESS_DIR}" ]]; then
        log_error "Ingress configuration directory not found: ${INGRESS_DIR}"
        exit 1
    fi
}

# Apply Gateway and Certificate resources
apply_resources() {
    log_info "Applying Gateway and Certificate resources..."

    kubectl apply -f "${INGRESS_DIR}/resources/"
}

# Wait for certificate to be issued
wait_for_certificate() {
    log_info "Waiting for Gateway TLS certificate to be issued..."

    if ! kubectl wait --for=condition=Ready certificate/gateway-tls \
        -n "${ISTIO_INGRESS_NAMESPACE}" --timeout=120s; then
        log_error "Gateway TLS certificate not ready"
        kubectl describe certificate gateway-tls -n "${ISTIO_INGRESS_NAMESPACE}"
        exit 1
    fi

    log_info "Certificate issued successfully!"
}

# Verify TLS secret exists
verify_tls_secret() {
    log_info "Verifying TLS secret..."

    if ! kubectl get secret gateway-tls-secret -n "${ISTIO_INGRESS_NAMESPACE}" >/dev/null 2>&1; then
        log_error "TLS secret gateway-tls-secret not found"
        exit 1
    fi

    log_info "TLS secret verified!"
}

# Verify Gateway is applied
verify_gateway() {
    log_info "Verifying Gateway configuration..."

    if ! kubectl get gateway main-gateway -n "${ISTIO_INGRESS_NAMESPACE}" >/dev/null 2>&1; then
        log_error "Gateway main-gateway not found"
        exit 1
    fi

    log_info "Gateway verified!"
}

# Print status and usage info
print_info() {
    echo ""
    log_info "=========================================="
    log_info "Ingress Gateway configured successfully!"
    log_info "=========================================="
    echo ""
    echo "Gateway:"
    kubectl get gateway -n "${ISTIO_INGRESS_NAMESPACE}"
    echo ""
    echo "Certificate:"
    kubectl get certificate -n "${ISTIO_INGRESS_NAMESPACE}"
    echo ""
    echo "TLS Secret:"
    kubectl get secret gateway-tls-secret -n "${ISTIO_INGRESS_NAMESPACE}" -o jsonpath='{.type}{"\n"}'
    echo ""
    echo "Endpoints:"
    echo "  HTTP  (redirects to HTTPS): http://localhost:8080"
    echo "  HTTPS (TLS termination):    https://localhost:8443"
    echo ""
    echo "To expose an application, create a VirtualService:"
    echo "  apiVersion: networking.istio.io/v1"
    echo "  kind: VirtualService"
    echo "  metadata:"
    echo "    name: my-app"
    echo "    namespace: my-namespace"
    echo "  spec:"
    echo "    hosts:"
    echo "      - my-app.localhost"
    echo "    gateways:"
    echo "      - istio-ingress/main-gateway"
    echo "    http:"
    echo "      - route:"
    echo "          - destination:"
    echo "              host: my-app.my-namespace.svc.cluster.local"
    echo "              port:"
    echo "                number: 8080"
    echo ""
    echo "Useful commands:"
    echo "  make ingress-status  # Check ingress status"
    echo "  make ingress-down    # Remove ingress configuration"
    echo ""
}

main() {
    log_info "Configuring Istio Gateway and TLS certificates..."

    check_prerequisites
    apply_resources
    wait_for_certificate
    verify_tls_secret
    verify_gateway
    print_info

    log_info "Done!"
}

main "$@"
