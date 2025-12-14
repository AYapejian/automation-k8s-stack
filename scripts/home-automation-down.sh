#!/usr/bin/env bash
# home-automation-down.sh - Remove Home Automation stack (idempotent)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
HOME_AUTOMATION_DIR="${REPO_ROOT}/apps/home-automation"
NAMESPACE="home-automation"
CLUSTER_NAME="automation-k8s"
FORCE=false

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# Parse arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force|-f)
                FORCE=true
                shift
                ;;
            *)
                log_error "Unknown option: $1"
                exit 1
                ;;
        esac
    done
}

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

# Check if namespace exists
namespace_exists() {
    kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1
}

# Delete VirtualServices
delete_virtualservices() {
    if kubectl get crd virtualservices.networking.istio.io >/dev/null 2>&1; then
        log_info "Deleting VirtualServices..."
        kubectl delete -f "${HOME_AUTOMATION_DIR}/homeassistant/resources/virtualservice.yaml" 2>/dev/null || true
        kubectl delete -f "${HOME_AUTOMATION_DIR}/zigbee2mqtt/resources/virtualservice.yaml" 2>/dev/null || true
        kubectl delete -f "${HOME_AUTOMATION_DIR}/homebridge/resources/virtualservice.yaml" 2>/dev/null || true
    fi
}

# Delete ServiceMonitors
delete_servicemonitors() {
    if kubectl get crd servicemonitors.monitoring.coreos.com >/dev/null 2>&1; then
        log_info "Deleting ServiceMonitors..."
        kubectl delete -f "${HOME_AUTOMATION_DIR}/homeassistant/resources/servicemonitor.yaml" 2>/dev/null || true
    fi
}

# Delete deployments
delete_deployments() {
    log_info "Deleting deployments..."
    kubectl delete -f "${HOME_AUTOMATION_DIR}/homebridge/deployment.yaml" 2>/dev/null || true
    kubectl delete -f "${HOME_AUTOMATION_DIR}/zigbee2mqtt/deployment.yaml" 2>/dev/null || true
    kubectl delete -f "${HOME_AUTOMATION_DIR}/homeassistant/deployment.yaml" 2>/dev/null || true
    kubectl delete -f "${HOME_AUTOMATION_DIR}/mosquitto/deployment.yaml" 2>/dev/null || true
}

# Delete services
delete_services() {
    log_info "Deleting services..."
    kubectl delete -f "${HOME_AUTOMATION_DIR}/homebridge/service.yaml" 2>/dev/null || true
    kubectl delete -f "${HOME_AUTOMATION_DIR}/zigbee2mqtt/service.yaml" 2>/dev/null || true
    kubectl delete -f "${HOME_AUTOMATION_DIR}/homeassistant/service.yaml" 2>/dev/null || true
    kubectl delete -f "${HOME_AUTOMATION_DIR}/mosquitto/service.yaml" 2>/dev/null || true
}

# Delete configmaps
delete_configmaps() {
    log_info "Deleting configmaps..."
    kubectl delete -f "${HOME_AUTOMATION_DIR}/zigbee2mqtt/configmap.yaml" 2>/dev/null || true
    kubectl delete -f "${HOME_AUTOMATION_DIR}/homeassistant/configmap.yaml" 2>/dev/null || true
    kubectl delete -f "${HOME_AUTOMATION_DIR}/mosquitto/configmap.yaml" 2>/dev/null || true
}

# Delete PVCs (only with --force)
delete_pvcs() {
    if [[ "${FORCE}" == "true" ]]; then
        log_info "Deleting PVCs (--force specified)..."
        kubectl delete -f "${HOME_AUTOMATION_DIR}/homebridge/pvc.yaml" 2>/dev/null || true
        kubectl delete -f "${HOME_AUTOMATION_DIR}/zigbee2mqtt/pvc.yaml" 2>/dev/null || true
        kubectl delete -f "${HOME_AUTOMATION_DIR}/homeassistant/pvc.yaml" 2>/dev/null || true
        kubectl delete -f "${HOME_AUTOMATION_DIR}/mosquitto/pvc.yaml" 2>/dev/null || true
    else
        log_warn "PVCs preserved (use --force to delete persistent data)"
    fi
}

# Delete namespace (only with --force)
delete_namespace() {
    if [[ "${FORCE}" == "true" ]]; then
        log_info "Deleting namespace ${NAMESPACE}..."
        kubectl delete -f "${HOME_AUTOMATION_DIR}/namespace.yaml" 2>/dev/null || true
    else
        log_warn "Namespace preserved (use --force to delete)"
    fi
}

main() {
    parse_args "$@"

    log_info "Removing Home Automation stack..."

    setup_kubeconfig

    if ! namespace_exists; then
        log_info "Namespace ${NAMESPACE} does not exist, nothing to remove"
        exit 0
    fi

    delete_virtualservices
    delete_servicemonitors
    delete_deployments
    delete_services
    delete_configmaps
    delete_pvcs
    delete_namespace

    echo ""
    log_info "Home Automation stack removed"

    if [[ "${FORCE}" != "true" ]]; then
        echo ""
        log_info "Note: PVCs and namespace preserved. Use --force to fully remove."
    fi
}

main "$@"
