#!/usr/bin/env bash
# sample-app-up.sh - Deploy sample httpbin application (idempotent)
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

    # Check if Istio is installed
    if ! kubectl get deployment istiod -n istio-system >/dev/null 2>&1; then
        log_error "Istio not found."
        log_error "Run 'make istio-up' first."
        exit 1
    fi

    # Check if Gateway exists
    if ! kubectl get gateway main-gateway -n istio-ingress >/dev/null 2>&1; then
        log_error "Gateway main-gateway not found."
        log_error "Run 'make ingress-up' first."
        exit 1
    fi

    # Check if sample app config directory exists
    if [[ ! -d "${SAMPLE_APP_DIR}" ]]; then
        log_error "Sample app configuration directory not found: ${SAMPLE_APP_DIR}"
        exit 1
    fi
}

# Apply namespace first (needed for other resources)
apply_namespace() {
    log_info "Creating namespace ${SAMPLE_NAMESPACE}..."
    kubectl apply -f "${SAMPLE_APP_DIR}/namespace.yaml"
}

# Apply application resources
apply_resources() {
    log_info "Deploying httpbin application..."
    kubectl apply -f "${SAMPLE_APP_DIR}/deployment.yaml"
    kubectl apply -f "${SAMPLE_APP_DIR}/service.yaml"
    kubectl apply -f "${SAMPLE_APP_DIR}/virtual-service.yaml"
}

# Wait for pod to be ready
wait_for_pod() {
    log_info "Waiting for httpbin pod to be ready..."

    if ! kubectl wait --for=condition=Ready pods -l app=httpbin \
        -n "${SAMPLE_NAMESPACE}" --timeout=120s; then
        log_error "httpbin pod not ready"
        kubectl get pods -n "${SAMPLE_NAMESPACE}"
        kubectl describe pods -l app=httpbin -n "${SAMPLE_NAMESPACE}"
        exit 1
    fi

    log_info "httpbin pod is ready!"
}

# Verify sidecar injection
verify_sidecar() {
    log_info "Verifying Istio sidecar injection..."

    local containers
    containers=$(kubectl get pod -l app=httpbin -n "${SAMPLE_NAMESPACE}" \
        -o jsonpath='{.items[0].spec.containers[*].name}')

    if echo "${containers}" | grep -q "istio-proxy"; then
        log_info "Sidecar injected successfully!"
    else
        log_error "Sidecar not found. Containers: ${containers}"
        log_error "Check namespace has istio-injection=enabled label"
        exit 1
    fi
}

# Print status and usage info
print_info() {
    echo ""
    log_info "=========================================="
    log_info "Sample httpbin app deployed successfully!"
    log_info "=========================================="
    echo ""
    echo "Application:"
    kubectl get pods -n "${SAMPLE_NAMESPACE}"
    echo ""
    echo "Service:"
    kubectl get service -n "${SAMPLE_NAMESPACE}"
    echo ""
    echo "VirtualService:"
    kubectl get virtualservice -n "${SAMPLE_NAMESPACE}"
    echo ""
    echo "Access the application:"
    echo "  HTTP  (redirects): curl -s http://localhost:8080 -H 'Host: httpbin.localhost'"
    echo "  HTTPS (TLS):       curl -sk https://localhost:8443 -H 'Host: httpbin.localhost'"
    echo ""
    echo "Test endpoints:"
    echo "  curl -sk https://localhost:8443/get -H 'Host: httpbin.localhost'"
    echo "  curl -sk https://localhost:8443/headers -H 'Host: httpbin.localhost'"
    echo "  curl -sk https://localhost:8443/status/200 -H 'Host: httpbin.localhost'"
    echo ""
    echo "Useful commands:"
    echo "  make sample-app-status  # Check sample app status"
    echo "  make sample-app-down    # Remove sample app"
    echo ""
}

main() {
    log_info "Deploying sample httpbin application..."

    check_prerequisites
    apply_namespace
    apply_resources
    wait_for_pod
    verify_sidecar
    print_info

    log_info "Done!"
}

main "$@"
