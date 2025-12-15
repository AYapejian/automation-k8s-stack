#!/usr/bin/env bash
# media-stack-up.sh - Deploy Media stack (idempotent)
# Components: nzbget, Sonarr, Radarr
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
MEDIA_DIR="${REPO_ROOT}/apps/media"
NAMESPACE="media"
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
}

# Create namespace
create_namespace() {
    log_info "Creating namespace ${NAMESPACE}..."
    kubectl apply -f "${MEDIA_DIR}/namespace.yaml"
}

# Deploy shared storage
deploy_shared_storage() {
    log_info "Deploying shared downloads storage..."
    kubectl apply -f "${MEDIA_DIR}/shared-storage/downloads-pvc.yaml"
}

# Deploy nzbget (dependency for sonarr/radarr)
deploy_nzbget() {
    log_info "Deploying nzbget..."

    kubectl apply -f "${MEDIA_DIR}/nzbget/configmap.yaml"
    kubectl apply -f "${MEDIA_DIR}/nzbget/pvc.yaml"
    kubectl apply -f "${MEDIA_DIR}/nzbget/service.yaml"
    kubectl apply -f "${MEDIA_DIR}/nzbget/deployment.yaml"

    log_info "Waiting for nzbget to be ready..."
    if ! kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=nzbget \
        -n "${NAMESPACE}" --timeout=120s; then
        log_error "nzbget pod not ready"
        kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/name=nzbget
        kubectl describe pod -l app.kubernetes.io/name=nzbget -n "${NAMESPACE}" | tail -30
        exit 1
    fi
    log_info "nzbget is ready"
}

# Deploy Sonarr
deploy_sonarr() {
    log_info "Deploying Sonarr..."

    kubectl apply -f "${MEDIA_DIR}/sonarr/pvc.yaml"
    kubectl apply -f "${MEDIA_DIR}/sonarr/service.yaml"
    kubectl apply -f "${MEDIA_DIR}/sonarr/deployment.yaml"

    # Apply ServiceMonitor if Prometheus CRDs exist
    if kubectl get crd servicemonitors.monitoring.coreos.com >/dev/null 2>&1; then
        log_info "Applying Sonarr ServiceMonitor..."
        kubectl apply -f "${MEDIA_DIR}/sonarr/resources/servicemonitor.yaml"
    else
        log_warn "Prometheus Operator CRDs not found, skipping ServiceMonitor"
    fi
}

# Deploy Radarr
deploy_radarr() {
    log_info "Deploying Radarr..."

    kubectl apply -f "${MEDIA_DIR}/radarr/pvc.yaml"
    kubectl apply -f "${MEDIA_DIR}/radarr/service.yaml"
    kubectl apply -f "${MEDIA_DIR}/radarr/deployment.yaml"

    # Apply ServiceMonitor if Prometheus CRDs exist
    if kubectl get crd servicemonitors.monitoring.coreos.com >/dev/null 2>&1; then
        log_info "Applying Radarr ServiceMonitor..."
        kubectl apply -f "${MEDIA_DIR}/radarr/resources/servicemonitor.yaml"
    else
        log_warn "Prometheus Operator CRDs not found, skipping ServiceMonitor"
    fi
}

# Apply VirtualServices for ingress (only if Istio is installed)
apply_virtualservices() {
    if kubectl get crd virtualservices.networking.istio.io >/dev/null 2>&1; then
        log_info "Applying VirtualServices for ingress..."
        kubectl apply -f "${MEDIA_DIR}/nzbget/resources/virtualservice.yaml"
        kubectl apply -f "${MEDIA_DIR}/sonarr/resources/virtualservice.yaml"
        kubectl apply -f "${MEDIA_DIR}/radarr/resources/virtualservice.yaml"
    else
        log_warn "Istio not installed, skipping VirtualServices (access via port-forward only)"
    fi
}

# Verify installation
verify_installation() {
    log_info "Verifying installation..."

    log_info "Waiting for all pods to be ready (this may take a few minutes)..."

    # Wait for each component with appropriate timeouts
    local components=("nzbget" "sonarr" "radarr")
    local timeouts=("120s" "180s" "180s")

    for i in "${!components[@]}"; do
        local component="${components[$i]}"
        local timeout="${timeouts[$i]}"

        log_info "Waiting for ${component}..."
        if ! kubectl wait --for=condition=Ready pod -l "app.kubernetes.io/name=${component}" \
            -n "${NAMESPACE}" --timeout="${timeout}" 2>/dev/null; then
            log_warn "${component} pod not ready within ${timeout}"
            kubectl get pods -n "${NAMESPACE}" -l "app.kubernetes.io/name=${component}"
        fi
    done

    log_info "Installation verification complete"
}

# Print status and usage info
print_info() {
    echo ""
    log_info "=========================================="
    log_info "Media Stack Deployed!"
    log_info "=========================================="
    echo ""
    echo "Pods:"
    kubectl get pods -n "${NAMESPACE}"
    echo ""
    echo "Services:"
    kubectl get svc -n "${NAMESPACE}"
    echo ""
    echo "PVCs:"
    kubectl get pvc -n "${NAMESPACE}"
    echo ""
    echo "Access URLs (requires Istio Gateway):"
    echo "  nzbget:   https://nzbget.localhost:8443"
    echo "  Sonarr:   https://sonarr.localhost:8443"
    echo "  Radarr:   https://radarr.localhost:8443"
    echo ""
    echo "Port-forward access (alternative):"
    echo "  kubectl port-forward svc/nzbget 6789:6789 -n ${NAMESPACE}"
    echo "  kubectl port-forward svc/sonarr 8989:8989 -n ${NAMESPACE}"
    echo "  kubectl port-forward svc/radarr 7878:7878 -n ${NAMESPACE}"
    echo ""
    echo "Default credentials:"
    echo "  nzbget: nzbget / tegbzn6789"
    echo ""
    echo "Useful commands:"
    echo "  make media-stack-status  # Check status"
    echo "  make media-stack-test    # Run tests"
    echo "  make media-stack-down    # Uninstall"
    echo ""
}

main() {
    log_info "Starting Media stack deployment..."

    setup_kubeconfig
    check_prerequisites
    create_namespace
    deploy_shared_storage
    deploy_nzbget
    deploy_sonarr
    deploy_radarr
    apply_virtualservices
    verify_installation
    print_info

    log_info "Done!"
}

main "$@"
