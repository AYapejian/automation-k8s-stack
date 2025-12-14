#!/usr/bin/env bash
# loki-up.sh - Install Loki + Promtail for log aggregation (idempotent)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOKI_DIR="${REPO_ROOT}/observability/loki"
LOKI_STACK_VERSION="2.10.3"
NAMESPACE="observability"
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

    # Check if observability namespace exists (created by prometheus-grafana)
    if ! kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1; then
        log_error "Namespace ${NAMESPACE} not found. Run 'make prometheus-grafana-up' first."
        exit 1
    fi

    # Check if Minio is running (required for S3 storage)
    if ! kubectl get pods -n minio -l release=minio -o jsonpath='{.items[0].status.phase}' 2>/dev/null | grep -q "Running"; then
        log_error "Minio is not running. Run 'make minio-up' first."
        log_error "Loki requires Minio for S3-compatible log storage."
        exit 1
    fi
    log_info "Minio is running - S3 storage available"
}

# Add Grafana Helm repository
setup_helm_repo() {
    log_info "Setting up Grafana Helm repository..."
    if helm repo list 2>/dev/null | grep -qE "^grafana[[:space:]]"; then
        helm repo update grafana >/dev/null
    else
        helm repo add grafana https://grafana.github.io/helm-charts
        helm repo update >/dev/null
    fi
}

# Check if Helm release exists
release_exists() {
    local release_name="$1"
    helm status "${release_name}" -n "${NAMESPACE}" >/dev/null 2>&1
}

# Install or upgrade Loki Stack (Loki + Promtail bundled)
install_loki_stack() {
    log_info "Installing Loki Stack (version ${LOKI_STACK_VERSION})..."

    if release_exists "loki"; then
        log_info "loki release exists, upgrading..."
        helm upgrade loki grafana/loki-stack \
            -n "${NAMESPACE}" \
            --version "${LOKI_STACK_VERSION}" \
            -f "${LOKI_DIR}/values.yaml" \
            --wait --timeout 10m
    else
        helm install loki grafana/loki-stack \
            -n "${NAMESPACE}" \
            --version "${LOKI_STACK_VERSION}" \
            -f "${LOKI_DIR}/values.yaml" \
            --wait --timeout 10m
    fi
}

# Apply Minio credentials secret for S3 access
apply_minio_credentials() {
    log_info "Applying Minio credentials for Loki..."
    kubectl apply -f "${LOKI_DIR}/resources/minio-credentials.yaml"
}

# Apply Grafana datasource
apply_datasource() {
    log_info "Applying Loki datasource for Grafana..."
    kubectl apply -f "${LOKI_DIR}/resources/grafana-datasource.yaml"

    # Restart Grafana to pick up new datasource
    log_info "Restarting Grafana to load new datasource..."
    kubectl rollout restart deployment/prometheus-grafana -n "${NAMESPACE}" 2>/dev/null || true
}

# Verify installation
verify_installation() {
    log_info "Verifying installation..."

    # Wait for Loki
    log_info "Waiting for Loki pod..."
    if ! kubectl wait --for=condition=Ready pod -l app=loki,release=loki \
        -n "${NAMESPACE}" --timeout=120s; then
        log_error "Loki pod not ready"
        kubectl get pods -n "${NAMESPACE}" -l app=loki
        exit 1
    fi

    # Wait for Promtail (loki-stack uses app.kubernetes.io/name=promtail)
    log_info "Waiting for Promtail pods..."
    if ! kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=promtail \
        -n "${NAMESPACE}" --timeout=120s; then
        log_error "Promtail pods not ready"
        kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/name=promtail
        exit 1
    fi

    # Wait for Grafana to restart
    kubectl rollout status deployment/prometheus-grafana -n "${NAMESPACE}" --timeout=60s 2>/dev/null || true

    log_info "Installation verified successfully!"
}

# Print status and usage info
print_info() {
    echo ""
    log_info "=========================================="
    log_info "Loki + Promtail installed successfully!"
    log_info "=========================================="
    echo ""
    echo "Storage: Minio S3 (bucket: loki-chunks)"
    echo ""
    echo "Helm release:"
    helm list -n "${NAMESPACE}" | grep loki
    echo ""
    echo "Pods:"
    kubectl get pods -n "${NAMESPACE}" -l "app in (loki, promtail)"
    echo ""
    echo "Loki is now available as a datasource in Grafana."
    echo ""
    echo "To query logs in Grafana:"
    echo "  1. Open https://grafana.localhost:8443"
    echo "  2. Go to Explore (compass icon)"
    echo "  3. Select 'Loki' datasource"
    echo "  4. Try: {namespace=\"kube-system\"}"
    echo "  5. For Istio proxy logs: {container=\"istio-proxy\"}"
    echo ""
    echo "Useful commands:"
    echo "  make loki-status  # Check status"
    echo "  make loki-down    # Uninstall"
    echo ""
}

main() {
    log_info "Starting Loki + Promtail installation..."

    setup_kubeconfig
    check_prerequisites
    setup_helm_repo
    apply_minio_credentials
    install_loki_stack
    apply_datasource
    verify_installation
    print_info

    log_info "Done!"
}

main "$@"
