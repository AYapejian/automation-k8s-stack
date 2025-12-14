#!/usr/bin/env bash
# home-automation-up.sh - Deploy Home Automation stack (idempotent)
# Components: Mosquitto MQTT, HomeAssistant, Zigbee2MQTT, Homebridge
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
HOME_AUTOMATION_DIR="${REPO_ROOT}/apps/home-automation"
NAMESPACE="home-automation"
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
    kubectl apply -f "${HOME_AUTOMATION_DIR}/namespace.yaml"
}

# Deploy Mosquitto MQTT broker (dependency for other components)
deploy_mosquitto() {
    log_info "Deploying Mosquitto MQTT broker..."

    kubectl apply -f "${HOME_AUTOMATION_DIR}/mosquitto/configmap.yaml"
    kubectl apply -f "${HOME_AUTOMATION_DIR}/mosquitto/pvc.yaml"
    kubectl apply -f "${HOME_AUTOMATION_DIR}/mosquitto/service.yaml"
    kubectl apply -f "${HOME_AUTOMATION_DIR}/mosquitto/deployment.yaml"

    log_info "Waiting for Mosquitto to be ready..."
    if ! kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=mosquitto \
        -n "${NAMESPACE}" --timeout=120s; then
        log_error "Mosquitto pod not ready"
        kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/name=mosquitto
        kubectl describe pod -l app.kubernetes.io/name=mosquitto -n "${NAMESPACE}" | tail -30
        exit 1
    fi
    log_info "Mosquitto is ready"
}

# Deploy HomeAssistant
deploy_homeassistant() {
    log_info "Deploying HomeAssistant..."

    kubectl apply -f "${HOME_AUTOMATION_DIR}/homeassistant/configmap.yaml"
    kubectl apply -f "${HOME_AUTOMATION_DIR}/homeassistant/pvc.yaml"
    kubectl apply -f "${HOME_AUTOMATION_DIR}/homeassistant/service.yaml"
    kubectl apply -f "${HOME_AUTOMATION_DIR}/homeassistant/deployment.yaml"

    # Apply ServiceMonitor if Prometheus CRDs exist
    if kubectl get crd servicemonitors.monitoring.coreos.com >/dev/null 2>&1; then
        log_info "Applying HomeAssistant ServiceMonitor..."
        kubectl apply -f "${HOME_AUTOMATION_DIR}/homeassistant/resources/servicemonitor.yaml"
    else
        log_warn "Prometheus Operator CRDs not found, skipping ServiceMonitor"
    fi
}

# Deploy Zigbee2MQTT
deploy_zigbee2mqtt() {
    log_info "Deploying Zigbee2MQTT..."

    kubectl apply -f "${HOME_AUTOMATION_DIR}/zigbee2mqtt/configmap.yaml"
    kubectl apply -f "${HOME_AUTOMATION_DIR}/zigbee2mqtt/pvc.yaml"
    kubectl apply -f "${HOME_AUTOMATION_DIR}/zigbee2mqtt/service.yaml"
    kubectl apply -f "${HOME_AUTOMATION_DIR}/zigbee2mqtt/deployment.yaml"
}

# Deploy Homebridge
deploy_homebridge() {
    log_info "Deploying Homebridge..."

    kubectl apply -f "${HOME_AUTOMATION_DIR}/homebridge/pvc.yaml"
    kubectl apply -f "${HOME_AUTOMATION_DIR}/homebridge/service.yaml"
    kubectl apply -f "${HOME_AUTOMATION_DIR}/homebridge/deployment.yaml"
}

# Apply VirtualServices for ingress (only if Istio is installed)
apply_virtualservices() {
    if kubectl get crd virtualservices.networking.istio.io >/dev/null 2>&1; then
        log_info "Applying VirtualServices for ingress..."
        kubectl apply -f "${HOME_AUTOMATION_DIR}/homeassistant/resources/virtualservice.yaml"
        kubectl apply -f "${HOME_AUTOMATION_DIR}/zigbee2mqtt/resources/virtualservice.yaml"
        kubectl apply -f "${HOME_AUTOMATION_DIR}/homebridge/resources/virtualservice.yaml"
    else
        log_warn "Istio not installed, skipping VirtualServices (access via port-forward only)"
    fi
}

# Verify installation
verify_installation() {
    log_info "Verifying installation..."

    log_info "Waiting for all pods to be ready (this may take a few minutes)..."

    # Wait for each component with appropriate timeouts
    local components=("mosquitto" "homeassistant" "zigbee2mqtt" "homebridge")
    local timeouts=("60s" "180s" "120s" "120s")

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
    log_info "Home Automation Stack Deployed!"
    log_info "=========================================="
    echo ""
    echo "Pods:"
    kubectl get pods -n "${NAMESPACE}"
    echo ""
    echo "Services:"
    kubectl get svc -n "${NAMESPACE}"
    echo ""
    echo "Access URLs (requires Istio Gateway):"
    echo "  HomeAssistant:  https://homeassistant.localhost:8443"
    echo "  Zigbee2MQTT:    https://zigbee2mqtt.localhost:8443"
    echo "  Homebridge:     https://homebridge.localhost:8443"
    echo ""
    echo "Port-forward access (alternative):"
    echo "  kubectl port-forward svc/homeassistant 8123:8123 -n ${NAMESPACE}"
    echo "  kubectl port-forward svc/zigbee2mqtt 8080:8080 -n ${NAMESPACE}"
    echo "  kubectl port-forward svc/homebridge 8581:8581 -n ${NAMESPACE}"
    echo ""
    echo "MQTT broker internal endpoint:"
    echo "  mqtt://mosquitto.${NAMESPACE}.svc.cluster.local:1883"
    echo ""
    echo "Useful commands:"
    echo "  make home-automation-status  # Check status"
    echo "  make home-automation-test    # Run tests"
    echo "  make home-automation-down    # Uninstall"
    echo ""
}

main() {
    log_info "Starting Home Automation stack deployment..."

    setup_kubeconfig
    check_prerequisites
    create_namespace
    deploy_mosquitto
    deploy_homeassistant
    deploy_zigbee2mqtt
    deploy_homebridge
    apply_virtualservices
    verify_installation
    print_info

    log_info "Done!"
}

main "$@"
