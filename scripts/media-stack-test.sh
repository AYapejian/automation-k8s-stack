#!/usr/bin/env bash
# media-stack-test.sh - Integration tests for Media stack
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="media"
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

    local components=("nzbget" "sonarr" "radarr")

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

    local components=("nzbget" "sonarr" "radarr")

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

# Test: Shared storage PVC
test_shared_storage() {
    log_info "Testing: Shared storage PVC..."

    local status
    status=$(kubectl get pvc media-downloads -n "${NAMESPACE}" \
        -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")

    if [[ "${status}" == "Bound" ]]; then
        log_pass "Shared downloads PVC is Bound"
    else
        log_fail "Shared downloads PVC status: ${status}"
    fi
}

# Test: nzbget web interface
test_nzbget_web() {
    log_info "Testing: nzbget web interface..."

    local pod
    pod=$(kubectl get pods -n "${NAMESPACE}" -l "app.kubernetes.io/name=nzbget" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

    if [[ -z "${pod}" ]]; then
        log_fail "nzbget pod not found"
        return
    fi

    # Test web interface
    local response
    response=$(kubectl exec -n "${NAMESPACE}" "${pod}" -c nzbget -- \
        wget -q -O - --timeout=5 http://localhost:6789/ 2>/dev/null || echo "failed")

    if [[ "${response}" != "failed" && -n "${response}" ]]; then
        log_pass "nzbget web interface responds"
    else
        log_warn "nzbget web interface not responding"
    fi
}

# Test: Sonarr API
test_sonarr_api() {
    log_info "Testing: Sonarr API..."

    local pod
    pod=$(kubectl get pods -n "${NAMESPACE}" -l "app.kubernetes.io/name=sonarr" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

    if [[ -z "${pod}" ]]; then
        log_fail "Sonarr pod not found"
        return
    fi

    # Test ping endpoint
    local response
    response=$(kubectl exec -n "${NAMESPACE}" "${pod}" -c sonarr -- \
        wget -q -O - --timeout=5 http://localhost:8989/ping 2>/dev/null || echo "failed")

    if [[ "${response}" != "failed" ]]; then
        log_pass "Sonarr API responds"
    else
        log_warn "Sonarr API not responding (may still be starting)"
    fi
}

# Test: Radarr API
test_radarr_api() {
    log_info "Testing: Radarr API..."

    local pod
    pod=$(kubectl get pods -n "${NAMESPACE}" -l "app.kubernetes.io/name=radarr" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

    if [[ -z "${pod}" ]]; then
        log_fail "Radarr pod not found"
        return
    fi

    # Test ping endpoint
    local response
    response=$(kubectl exec -n "${NAMESPACE}" "${pod}" -c radarr -- \
        wget -q -O - --timeout=5 http://localhost:7878/ping 2>/dev/null || echo "failed")

    if [[ "${response}" != "failed" ]]; then
        log_pass "Radarr API responds"
    else
        log_warn "Radarr API not responding (may still be starting)"
    fi
}

# Test: VirtualServices (if Istio installed)
test_virtualservices() {
    log_info "Testing: Istio VirtualServices..."

    if ! kubectl get crd virtualservices.networking.istio.io >/dev/null 2>&1; then
        log_warn "Istio not installed, skipping VirtualService tests"
        return
    fi

    local services=("nzbget" "sonarr" "radarr")

    for svc in "${services[@]}"; do
        if kubectl get virtualservice "${svc}" -n "${NAMESPACE}" >/dev/null 2>&1; then
            log_pass "VirtualService ${svc} exists"
        else
            log_fail "VirtualService ${svc} not found"
        fi
    done
}

# Test: ServiceMonitors (if Prometheus installed)
test_servicemonitors() {
    log_info "Testing: Prometheus ServiceMonitors..."

    if ! kubectl get crd servicemonitors.monitoring.coreos.com >/dev/null 2>&1; then
        log_warn "Prometheus Operator not installed, skipping ServiceMonitor tests"
        return
    fi

    local services=("sonarr" "radarr")

    for svc in "${services[@]}"; do
        if kubectl get servicemonitor "${svc}" -n "${NAMESPACE}" >/dev/null 2>&1; then
            log_pass "ServiceMonitor ${svc} exists"
        else
            log_fail "ServiceMonitor ${svc} not found"
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
    log_info "Running Media stack integration tests..."
    echo ""

    setup_kubeconfig

    test_namespace
    echo ""
    test_pods_running
    echo ""
    test_sidecar_injection
    echo ""
    test_shared_storage
    echo ""
    test_nzbget_web
    echo ""
    test_sonarr_api
    echo ""
    test_radarr_api
    echo ""
    test_virtualservices
    echo ""
    test_servicemonitors

    print_summary

    exit ${FAILED_TESTS}
}

main "$@"
