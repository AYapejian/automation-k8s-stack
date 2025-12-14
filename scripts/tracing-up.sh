#!/usr/bin/env bash
# tracing-up.sh - Install distributed tracing stack (Jaeger, Tempo, OTel Collector)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
NAMESPACE="observability"
CLUSTER_NAME="automation-k8s"

# Chart versions
OTEL_COLLECTOR_VERSION="0.141.1"
JAEGER_VERSION="4.1.4"
TEMPO_VERSION="1.24.1"

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

    # Check if observability namespace exists
    if ! kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1; then
        log_error "Namespace ${NAMESPACE} not found. Run 'make prometheus-grafana-up' first."
        exit 1
    fi

    # Check if Minio is running (required for Tempo storage)
    if ! kubectl get pods -n minio -l app.kubernetes.io/name=minio -o jsonpath='{.items[0].status.phase}' 2>/dev/null | grep -q "Running"; then
        log_error "Minio is not running. Run 'make minio-up' first."
        log_error "Tempo requires Minio for S3-compatible trace storage."
        exit 1
    fi
    log_info "Minio is running - S3 storage available"
}

# Setup Helm repositories
setup_helm_repos() {
    log_info "Setting up Helm repositories..."

    # OpenTelemetry
    if helm repo list 2>/dev/null | grep -qE "^open-telemetry[[:space:]]"; then
        helm repo update open-telemetry >/dev/null
    else
        helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
    fi

    # Jaeger
    if helm repo list 2>/dev/null | grep -qE "^jaegertracing[[:space:]]"; then
        helm repo update jaegertracing >/dev/null
    else
        helm repo add jaegertracing https://jaegertracing.github.io/helm-charts
    fi

    # Grafana (for Tempo)
    if helm repo list 2>/dev/null | grep -qE "^grafana[[:space:]]"; then
        helm repo update grafana >/dev/null
    else
        helm repo add grafana https://grafana.github.io/helm-charts
    fi

    helm repo update >/dev/null
}

# Check if Helm release exists
release_exists() {
    local release_name="$1"
    helm status "${release_name}" -n "${NAMESPACE}" >/dev/null 2>&1
}

# Install Tempo (must be installed first as it receives from OTel Collector)
install_tempo() {
    log_info "Installing Tempo (version ${TEMPO_VERSION})..."

    if release_exists "tempo"; then
        log_info "tempo release exists, upgrading..."
        helm upgrade tempo grafana/tempo \
            -n "${NAMESPACE}" \
            --version "${TEMPO_VERSION}" \
            -f "${REPO_ROOT}/observability/tempo/values.yaml" \
            --wait --timeout 5m
    else
        helm install tempo grafana/tempo \
            -n "${NAMESPACE}" \
            --version "${TEMPO_VERSION}" \
            -f "${REPO_ROOT}/observability/tempo/values.yaml" \
            --wait --timeout 5m
    fi

    # Apply Grafana datasource
    kubectl apply -f "${REPO_ROOT}/observability/tempo/resources/grafana-datasource.yaml"
}

# Install Jaeger (receives from OTel Collector)
install_jaeger() {
    log_info "Installing Jaeger (version ${JAEGER_VERSION})..."

    if release_exists "jaeger"; then
        log_info "jaeger release exists, upgrading..."
        helm upgrade jaeger jaegertracing/jaeger \
            -n "${NAMESPACE}" \
            --version "${JAEGER_VERSION}" \
            -f "${REPO_ROOT}/observability/jaeger/values.yaml" \
            --wait --timeout 5m
    else
        helm install jaeger jaegertracing/jaeger \
            -n "${NAMESPACE}" \
            --version "${JAEGER_VERSION}" \
            -f "${REPO_ROOT}/observability/jaeger/values.yaml" \
            --wait --timeout 5m
    fi

    # Apply VirtualService for UI access
    kubectl apply -f "${REPO_ROOT}/observability/jaeger/resources/virtualservice.yaml"
}

# Install OpenTelemetry Collector (routes traces to Jaeger and Tempo)
install_otel_collector() {
    log_info "Installing OpenTelemetry Collector (version ${OTEL_COLLECTOR_VERSION})..."

    if release_exists "otel-collector"; then
        log_info "otel-collector release exists, upgrading..."
        helm upgrade otel-collector open-telemetry/opentelemetry-collector \
            -n "${NAMESPACE}" \
            --version "${OTEL_COLLECTOR_VERSION}" \
            -f "${REPO_ROOT}/observability/otel-collector/values.yaml" \
            --wait --timeout 5m
    else
        helm install otel-collector open-telemetry/opentelemetry-collector \
            -n "${NAMESPACE}" \
            --version "${OTEL_COLLECTOR_VERSION}" \
            -f "${REPO_ROOT}/observability/otel-collector/values.yaml" \
            --wait --timeout 5m
    fi
}

# Enable Istio tracing
enable_istio_tracing() {
    log_info "Enabling Istio tracing to OTel Collector..."

    # Check if telemetry resource exists
    if kubectl get telemetry default -n istio-system >/dev/null 2>&1; then
        # Patch to enable tracing
        kubectl patch telemetry default -n istio-system --type=merge -p '
spec:
  tracing:
    - providers:
        - name: otel-tracing
      randomSamplingPercentage: 100
'
    else
        log_warn "Istio Telemetry resource not found - tracing may need manual configuration"
    fi
}

# Verify installation
verify_installation() {
    log_info "Verifying installation..."

    # Wait for Tempo
    log_info "Waiting for Tempo pod..."
    if ! kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=tempo \
        -n "${NAMESPACE}" --timeout=120s; then
        log_error "Tempo pod not ready"
        kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/name=tempo
        exit 1
    fi

    # Wait for Jaeger
    log_info "Waiting for Jaeger pod..."
    if ! kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=jaeger \
        -n "${NAMESPACE}" --timeout=120s; then
        log_warn "Jaeger pod may still be starting"
        kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/name=jaeger
    fi

    # Wait for OTel Collector
    log_info "Waiting for OTel Collector pod..."
    if ! kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=opentelemetry-collector \
        -n "${NAMESPACE}" --timeout=120s; then
        log_error "OTel Collector pod not ready"
        kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/name=opentelemetry-collector
        exit 1
    fi

    # Restart Grafana to pick up new datasource
    log_info "Restarting Grafana to load Tempo datasource..."
    kubectl rollout restart deployment/prometheus-grafana -n "${NAMESPACE}" 2>/dev/null || true
    kubectl rollout status deployment/prometheus-grafana -n "${NAMESPACE}" --timeout=60s 2>/dev/null || true

    log_info "Installation verified successfully!"
}

# Print status and usage info
print_info() {
    echo ""
    log_info "=========================================="
    log_info "Distributed Tracing installed successfully!"
    log_info "=========================================="
    echo ""
    echo "Components:"
    echo "  - OpenTelemetry Collector (receives traces from Istio)"
    echo "  - Jaeger (trace visualization UI)"
    echo "  - Tempo (Grafana-native trace storage)"
    echo ""
    echo "Helm releases:"
    helm list -n "${NAMESPACE}" | grep -E "otel-collector|jaeger|tempo"
    echo ""
    echo "Pods:"
    kubectl get pods -n "${NAMESPACE}" -l "app.kubernetes.io/name in (opentelemetry-collector, jaeger, tempo)"
    echo ""
    echo "Access URLs:"
    echo "  Jaeger UI: https://jaeger.localhost:8443"
    echo "  Tempo (via Grafana): https://grafana.localhost:8443 -> Explore -> Tempo"
    echo ""
    echo "Architecture:"
    echo "  Istio Proxy -> OTel Collector (4317) -> Jaeger"
    echo "                                      -> Tempo -> Minio (S3)"
    echo ""
    echo "Useful commands:"
    echo "  make tracing-status  # Check status"
    echo "  make tracing-down    # Uninstall"
    echo ""
}

main() {
    log_info "Starting distributed tracing installation..."

    setup_kubeconfig
    check_prerequisites
    setup_helm_repos
    install_tempo
    install_jaeger
    install_otel_collector
    enable_istio_tracing
    verify_installation
    print_info

    log_info "Done!"
}

main "$@"
