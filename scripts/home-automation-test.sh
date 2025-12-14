#!/usr/bin/env bash
# home-automation-test.sh - Integration tests for Home Automation stack
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="home-automation"
CLUSTER_NAME="automation-k8s"
FAILED_TESTS=0

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_pass() { echo -e "${GREEN}[PASS]${NC} $*"; }
log_fail() { echo -e "${RED}[FAIL]${NC} $*"; FAILED_TESTS=$((FAILED_TESTS + 1)); }

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

# Test: Namespace exists
test_namespace() {
    log_info "Testing: Namespace exists..."
    if kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1; then
        log_pass "Namespace ${NAMESPACE} exists"
    else
        log_fail "Namespace ${NAMESPACE} not found"
    fi
}

# Test: All pods are running
test_pods_running() {
    log_info "Testing: All pods are running..."

    local components=("mosquitto" "homeassistant" "zigbee2mqtt" "homebridge")

    for component in "${components[@]}"; do
        local status
        status=$(kubectl get pods -n "${NAMESPACE}" -l "app.kubernetes.io/name=${component}" \
            -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "NotFound")

        if [[ "${status}" == "Running" ]]; then
            log_pass "${component} pod is Running"
        else
            log_fail "${component} pod status: ${status}"
        fi
    done
}

# Test: Istio sidecar injection
test_sidecar_injection() {
    log_info "Testing: Istio sidecar injection..."

    local components=("mosquitto" "homeassistant" "zigbee2mqtt" "homebridge")

    for component in "${components[@]}"; do
        local container_count
        container_count=$(kubectl get pods -n "${NAMESPACE}" -l "app.kubernetes.io/name=${component}" \
            -o jsonpath='{.items[0].spec.containers[*].name}' 2>/dev/null | wc -w || echo "0")

        if [[ "${container_count}" -ge 2 ]]; then
            log_pass "${component} has Istio sidecar (${container_count} containers)"
        else
            log_warn "${component} may not have Istio sidecar (${container_count} containers)"
        fi
    done
}

# Test: MQTT broker connectivity
test_mqtt_connectivity() {
    log_info "Testing: MQTT broker connectivity..."

    # Check if mosquitto service is accessible
    local mqtt_endpoint="mosquitto.${NAMESPACE}.svc.cluster.local"

    # Run a test pod to verify MQTT connectivity
    kubectl run mqtt-test \
        --image=eclipse-mosquitto:2.0.18 \
        --restart=Never \
        --rm \
        -i \
        --quiet \
        --namespace "${NAMESPACE}" \
        --command -- \
        mosquitto_pub -h mosquitto -p 1883 -t "test/connectivity" -m "test" -q 1 2>/dev/null && \
        log_pass "MQTT broker accepts connections" || \
        log_fail "MQTT broker not responding"
}

# Test: HomeAssistant API
test_homeassistant_api() {
    log_info "Testing: HomeAssistant API..."

    local ha_pod
    ha_pod=$(kubectl get pods -n "${NAMESPACE}" -l "app.kubernetes.io/name=homeassistant" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

    if [[ -z "${ha_pod}" ]]; then
        log_fail "HomeAssistant pod not found"
        return
    fi

    # Test API endpoint via kubectl exec
    local response
    response=$(kubectl exec -n "${NAMESPACE}" "${ha_pod}" -c homeassistant -- \
        wget -q -O - http://localhost:8123/api/ 2>/dev/null || echo "failed")

    if [[ "${response}" != "failed" ]]; then
        log_pass "HomeAssistant API responds"
    else
        log_warn "HomeAssistant API not responding (may need initial setup)"
    fi
}

# Test: HomeAssistant Prometheus metrics (if configured)
test_homeassistant_metrics() {
    log_info "Testing: HomeAssistant Prometheus metrics..."

    local ha_pod
    ha_pod=$(kubectl get pods -n "${NAMESPACE}" -l "app.kubernetes.io/name=homeassistant" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

    if [[ -z "${ha_pod}" ]]; then
        log_fail "HomeAssistant pod not found"
        return
    fi

    # Test Prometheus endpoint
    local response
    response=$(kubectl exec -n "${NAMESPACE}" "${ha_pod}" -c homeassistant -- \
        wget -q -O - http://localhost:8123/api/prometheus 2>/dev/null || echo "failed")

    if [[ "${response}" != "failed" && "${response}" != *"401"* ]]; then
        log_pass "HomeAssistant Prometheus metrics accessible"
    else
        log_warn "Prometheus metrics not configured (requires HA setup with prometheus: enabled)"
    fi
}

# Test: Zigbee2MQTT frontend
test_zigbee2mqtt_frontend() {
    log_info "Testing: Zigbee2MQTT frontend..."

    local z2m_pod
    z2m_pod=$(kubectl get pods -n "${NAMESPACE}" -l "app.kubernetes.io/name=zigbee2mqtt" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

    if [[ -z "${z2m_pod}" ]]; then
        log_fail "Zigbee2MQTT pod not found"
        return
    fi

    # Test frontend endpoint
    local response
    response=$(kubectl exec -n "${NAMESPACE}" "${z2m_pod}" -c zigbee2mqtt -- \
        wget -q -O - http://localhost:8080/ 2>/dev/null || echo "failed")

    if [[ "${response}" != "failed" ]]; then
        log_pass "Zigbee2MQTT frontend responds"
    else
        log_warn "Zigbee2MQTT frontend not responding"
    fi
}

# Test: Homebridge UI
test_homebridge_ui() {
    log_info "Testing: Homebridge UI..."

    local hb_pod
    hb_pod=$(kubectl get pods -n "${NAMESPACE}" -l "app.kubernetes.io/name=homebridge" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

    if [[ -z "${hb_pod}" ]]; then
        log_fail "Homebridge pod not found"
        return
    fi

    # Test UI endpoint
    local response
    response=$(kubectl exec -n "${NAMESPACE}" "${hb_pod}" -c homebridge -- \
        wget -q -O - http://localhost:8581/ 2>/dev/null || echo "failed")

    if [[ "${response}" != "failed" ]]; then
        log_pass "Homebridge UI responds"
    else
        log_warn "Homebridge UI not responding (may still be starting)"
    fi
}

# Test: VirtualServices (if Istio installed)
test_virtualservices() {
    log_info "Testing: Istio VirtualServices..."

    if ! kubectl get crd virtualservices.networking.istio.io >/dev/null 2>&1; then
        log_warn "Istio not installed, skipping VirtualService tests"
        return
    fi

    local services=("homeassistant" "zigbee2mqtt" "homebridge")

    for svc in "${services[@]}"; do
        if kubectl get virtualservice "${svc}" -n "${NAMESPACE}" >/dev/null 2>&1; then
            log_pass "VirtualService ${svc} exists"
        else
            log_fail "VirtualService ${svc} not found"
        fi
    done
}

# Print summary
print_summary() {
    echo ""
    log_info "=========================================="
    if [[ ${FAILED_TESTS} -eq 0 ]]; then
        log_info "All tests passed!"
    else
        log_error "${FAILED_TESTS} test(s) failed"
    fi
    log_info "=========================================="
}

main() {
    log_info "Running Home Automation integration tests..."
    echo ""

    setup_kubeconfig

    test_namespace
    echo ""
    test_pods_running
    echo ""
    test_sidecar_injection
    echo ""
    test_mqtt_connectivity
    echo ""
    test_homeassistant_api
    test_homeassistant_metrics
    echo ""
    test_zigbee2mqtt_frontend
    echo ""
    test_homebridge_ui
    echo ""
    test_virtualservices

    print_summary

    exit ${FAILED_TESTS}
}

main "$@"
