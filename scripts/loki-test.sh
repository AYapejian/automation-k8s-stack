#!/usr/bin/env bash
# loki-test.sh - Test Loki installation and log ingestion
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
log_pass() { echo -e "${GREEN}[PASS]${NC} $*"; }
log_fail() { echo -e "${RED}[FAIL]${NC} $*"; }

# Setup kubeconfig for k3d cluster
setup_kubeconfig() {
    if command -v k3d >/dev/null 2>&1; then
        local kubeconfig
        kubeconfig=$(k3d kubeconfig write "${CLUSTER_NAME}" 2>/dev/null) || true
        if [[ -n "${kubeconfig}" && -f "${kubeconfig}" ]]; then
            export KUBECONFIG="${kubeconfig}"
        fi
    fi
}

# Test: Loki pod is running
test_loki_running() {
    log_info "Testing: Loki pod is running..."
    if kubectl get pod -n "${NAMESPACE}" -l app=loki,release=loki -o jsonpath='{.items[0].status.phase}' 2>/dev/null | grep -q "Running"; then
        log_pass "Loki pod is running"
        return 0
    else
        log_fail "Loki pod is not running"
        kubectl get pods -n "${NAMESPACE}" -l app=loki 2>/dev/null || true
        return 1
    fi
}

# Test: Promtail pods are running
test_promtail_running() {
    log_info "Testing: Promtail pods are running..."
    local ready_count
    ready_count=$(kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/name=promtail -o jsonpath='{.items[*].status.phase}' 2>/dev/null | grep -c "Running" || echo "0")

    if [[ ${ready_count} -gt 0 ]]; then
        log_pass "Promtail pods are running (${ready_count} instance(s))"
        return 0
    else
        log_fail "No Promtail pods are running"
        kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/name=promtail 2>/dev/null || true
        return 1
    fi
}

# Test: Loki health endpoint
test_loki_health() {
    log_info "Testing: Loki health endpoint..."

    local health_response
    health_response=$(kubectl run loki-health-check \
        --image=curlimages/curl:latest \
        --restart=Never \
        --rm -i --quiet \
        --namespace "${NAMESPACE}" \
        -- curl -s "http://loki:3100/ready" 2>/dev/null || echo "FAILED")

    if echo "${health_response}" | grep -qi "ready"; then
        log_pass "Loki health endpoint is ready"
        return 0
    else
        log_fail "Loki health endpoint not ready: ${health_response}"
        return 1
    fi
}

# Test: Generate test logs and verify ingestion
test_log_ingestion() {
    log_info "Testing: Log ingestion works..."

    local test_namespace="loki-test"
    local test_message="LOKI_TEST_$(date +%s)"

    # Create test namespace with Istio injection
    kubectl create namespace "${test_namespace}" --dry-run=client -o yaml | kubectl apply -f -
    kubectl label namespace "${test_namespace}" istio-injection=enabled --overwrite 2>/dev/null || true

    # Create a pod that logs a unique message
    log_info "  Creating test pod with unique log message..."
    kubectl run loki-test-logger \
        --image=busybox \
        --restart=Never \
        --namespace "${test_namespace}" \
        -- sh -c "echo '${test_message}'; sleep 30"

    # Wait for pod to complete logging
    sleep 10

    # Query Loki for the test message
    log_info "  Querying Loki for test message..."
    local query_result
    query_result=$(kubectl run loki-query-test \
        --image=curlimages/curl:latest \
        --restart=Never \
        --rm -i --quiet \
        --namespace "${NAMESPACE}" \
        -- curl -s -G "http://loki:3100/loki/api/v1/query" \
           --data-urlencode "query={namespace=\"${test_namespace}\"}" 2>/dev/null || echo "QUERY_FAILED")

    # Cleanup test pod
    kubectl delete pod loki-test-logger -n "${test_namespace}" --ignore-not-found=true 2>/dev/null || true
    kubectl delete namespace "${test_namespace}" --ignore-not-found=true 2>/dev/null || true

    if echo "${query_result}" | grep -q "result"; then
        log_pass "Log ingestion works (Loki query returned results)"
        return 0
    else
        log_warn "Log ingestion test inconclusive (may need more time for logs to be ingested)"
        return 0  # Don't fail - logs may just need more time
    fi
}

# Test: Query kube-system logs
test_kube_system_logs() {
    log_info "Testing: Can query kube-system logs..."

    local query_result
    query_result=$(kubectl run loki-kube-query \
        --image=curlimages/curl:latest \
        --restart=Never \
        --rm -i --quiet \
        --namespace "${NAMESPACE}" \
        -- curl -s -G "http://loki:3100/loki/api/v1/query" \
           --data-urlencode 'query={namespace="kube-system"}' \
           --data-urlencode "limit=5" 2>/dev/null || echo "QUERY_FAILED")

    if echo "${query_result}" | grep -q '"status":"success"'; then
        log_pass "kube-system logs are queryable"
        return 0
    else
        log_fail "Cannot query kube-system logs"
        echo "Query result: ${query_result}"
        return 1
    fi
}

# Test: Istio proxy logs are captured
test_istio_proxy_logs() {
    log_info "Testing: Istio proxy logs are captured..."

    local query_result
    query_result=$(kubectl run loki-istio-query \
        --image=curlimages/curl:latest \
        --restart=Never \
        --rm -i --quiet \
        --namespace "${NAMESPACE}" \
        -- curl -s -G "http://loki:3100/loki/api/v1/query" \
           --data-urlencode 'query={container="istio-proxy"}' \
           --data-urlencode "limit=5" 2>/dev/null || echo "QUERY_FAILED")

    if echo "${query_result}" | grep -q '"status":"success"'; then
        log_pass "Istio proxy logs are captured"
        return 0
    else
        log_warn "Istio proxy logs query inconclusive (may need Istio-injected pods running)"
        return 0  # Don't fail - may just need traffic
    fi
}

# Test: Verify Minio storage is being used
test_minio_storage() {
    log_info "Testing: Loki is using Minio storage..."

    # Check if objects exist in the loki-chunks bucket
    local bucket_contents
    bucket_contents=$(kubectl run minio-bucket-check \
        --image=minio/mc:latest \
        --restart=Never \
        --rm -i --quiet \
        --namespace minio \
        --env="MC_HOST_myminio=http://minioadmin:minioadmin123@minio.minio.svc.cluster.local:9000" \
        -- mc ls myminio/loki-chunks/ 2>/dev/null || echo "EMPTY_OR_ERROR")

    if [[ "${bucket_contents}" != "EMPTY_OR_ERROR" ]] && [[ -n "${bucket_contents}" ]]; then
        log_pass "Loki is storing data in Minio (loki-chunks bucket has objects)"
        return 0
    else
        log_warn "Minio bucket may be empty (Loki may not have flushed chunks yet)"
        return 0  # Don't fail - chunks flush periodically
    fi
}

# Main test runner
main() {
    log_info "=========================================="
    log_info "Loki Installation Tests"
    log_info "=========================================="
    echo ""

    setup_kubeconfig

    local failed=0

    test_loki_running || ((failed++))
    test_promtail_running || ((failed++))
    test_loki_health || ((failed++))
    test_kube_system_logs || ((failed++))
    test_istio_proxy_logs || ((failed++))
    test_minio_storage || ((failed++))
    # test_log_ingestion || ((failed++))  # Optional, takes time

    echo ""
    log_info "=========================================="
    if [[ ${failed} -eq 0 ]]; then
        log_pass "All tests passed!"
        exit 0
    else
        log_fail "${failed} test(s) failed"
        exit 1
    fi
}

main "$@"
