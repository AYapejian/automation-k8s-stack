#!/usr/bin/env bash
# prometheus-grafana-up.sh - Install Prometheus + Grafana stack via Helm (idempotent)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
OBS_DIR="${REPO_ROOT}/observability/prometheus-grafana"
CHART_VERSION="80.4.1"
NAMESPACE="observability"
RELEASE_NAME="prometheus"
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
# This handles environments with complex KUBECONFIG env vars
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

    # Check if cluster is accessible
    if ! kubectl cluster-info >/dev/null 2>&1; then
        log_error "Cannot connect to Kubernetes cluster. Is the cluster running?"
        log_error "Run 'make cluster-up' first."
        exit 1
    fi

    # Check if Istio is installed (required for ingress)
    if ! kubectl get namespace istio-system >/dev/null 2>&1; then
        log_error "Istio is not installed. Run 'make istio-up' first."
        exit 1
    fi

    # Check if Gateway exists (required for VirtualServices)
    if ! kubectl get gateway main-gateway -n istio-ingress >/dev/null 2>&1; then
        log_error "Istio Gateway not found. Run 'make ingress-up' first."
        exit 1
    fi

    # Check if config directory exists
    if [[ ! -d "${OBS_DIR}" ]]; then
        log_error "Observability configuration directory not found: ${OBS_DIR}"
        exit 1
    fi
}

# Add prometheus-community Helm repository
setup_helm_repo() {
    log_info "Setting up prometheus-community Helm repository..."
    if helm repo list 2>/dev/null | grep -qE "^prometheus-community[[:space:]]"; then
        helm repo update prometheus-community >/dev/null
    else
        helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
        helm repo update >/dev/null
    fi
}

# Create namespace
create_namespace() {
    log_info "Creating namespace ${NAMESPACE}..."
    kubectl apply -f "${OBS_DIR}/resources/namespace.yaml"
}

# Check if Helm release exists
release_exists() {
    helm status "${RELEASE_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1
}

# Install or upgrade kube-prometheus-stack
install_prometheus_stack() {
    log_info "Installing kube-prometheus-stack (version ${CHART_VERSION})..."

    if release_exists; then
        log_info "${RELEASE_NAME} release exists, upgrading..."
        helm upgrade "${RELEASE_NAME}" prometheus-community/kube-prometheus-stack \
            -n "${NAMESPACE}" \
            --version "${CHART_VERSION}" \
            -f "${OBS_DIR}/values.yaml" \
            --wait --timeout 10m
    else
        helm install "${RELEASE_NAME}" prometheus-community/kube-prometheus-stack \
            -n "${NAMESPACE}" \
            --version "${CHART_VERSION}" \
            -f "${OBS_DIR}/values.yaml" \
            --wait --timeout 10m
    fi
}

# Apply Istio ServiceMonitor and PodMonitor
apply_istio_monitors() {
    log_info "Applying Istio ServiceMonitor and PodMonitor..."
    kubectl apply -f "${OBS_DIR}/resources/servicemonitor-istio.yaml"
    kubectl apply -f "${OBS_DIR}/resources/podmonitor-envoy.yaml"
}

# Apply VirtualServices for ingress
apply_virtualservices() {
    log_info "Applying VirtualServices for Grafana and Prometheus..."
    kubectl apply -f "${OBS_DIR}/resources/virtualservice-grafana.yaml"
    kubectl apply -f "${OBS_DIR}/resources/virtualservice-prometheus.yaml"
}

# Apply Grafana dashboards
apply_dashboards() {
    local dashboards_dir="${OBS_DIR}/resources/dashboards"
    if [[ -d "${dashboards_dir}" ]]; then
        log_info "Applying Grafana dashboards..."
        kubectl apply -f "${dashboards_dir}/"
    else
        log_warn "Dashboards directory not found: ${dashboards_dir}"
    fi
}

# Apply PrometheusRules for alerting
apply_prometheus_rules() {
    local rules_file="${OBS_DIR}/resources/prometheus-rules.yaml"
    if [[ -f "${rules_file}" ]]; then
        log_info "Applying PrometheusRules..."
        kubectl apply -f "${rules_file}"
    else
        log_warn "PrometheusRules file not found: ${rules_file}"
    fi
}

# Verify installation
verify_installation() {
    log_info "Verifying installation..."

    # Wait for Prometheus Operator
    if ! kubectl wait --for=condition=Available deployment/prometheus-kube-prometheus-operator \
        -n "${NAMESPACE}" --timeout=300s; then
        log_error "Prometheus Operator deployment not ready"
        kubectl get pods -n "${NAMESPACE}"
        exit 1
    fi

    # Wait for Grafana
    if ! kubectl wait --for=condition=Available deployment/prometheus-grafana \
        -n "${NAMESPACE}" --timeout=300s; then
        log_error "Grafana deployment not ready"
        kubectl get pods -n "${NAMESPACE}"
        exit 1
    fi

    # Wait for Prometheus StatefulSet to be ready
    log_info "Waiting for Prometheus pods..."
    kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=prometheus \
        -n "${NAMESPACE}" --timeout=300s || {
        log_warn "Prometheus pods not ready yet, but continuing..."
    }

    log_info "Installation verified successfully!"
}

# Print status and usage info
print_info() {
    echo ""
    log_info "=========================================="
    log_info "Prometheus + Grafana installed successfully!"
    log_info "=========================================="
    echo ""
    echo "Helm release:"
    helm list -n "${NAMESPACE}"
    echo ""
    echo "Pods:"
    kubectl get pods -n "${NAMESPACE}"
    echo ""
    echo "Access URLs:"
    echo "  Grafana:    https://grafana.localhost:8443"
    echo "  Prometheus: https://prometheus.localhost:8443"
    echo ""
    echo "Grafana credentials:"
    echo "  Username: admin"
    echo "  Password: admin"
    echo ""
    echo "Useful commands:"
    echo "  make prometheus-grafana-status  # Check status"
    echo "  make prometheus-grafana-down    # Uninstall"
    echo ""
}

main() {
    log_info "Starting Prometheus + Grafana installation..."

    setup_kubeconfig
    check_prerequisites
    setup_helm_repo
    create_namespace
    install_prometheus_stack
    apply_istio_monitors
    apply_virtualservices
    apply_dashboards
    apply_prometheus_rules
    verify_installation
    print_info

    log_info "Done!"
}

main "$@"
