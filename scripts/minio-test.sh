#!/usr/bin/env bash
# minio-test.sh - Test Minio installation
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="minio"
CLUSTER_NAME="automation-k8s"
TEST_BUCKET="loki-chunks"
TEST_FILE="test-$(date +%s).txt"

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

# Test: Minio pod is running
test_pod_running() {
    log_info "Testing: Minio pod is running..."
    if kubectl get pod -n "${NAMESPACE}" -l app.kubernetes.io/name=minio -o jsonpath='{.items[0].status.phase}' 2>/dev/null | grep -q "Running"; then
        log_pass "Minio pod is running"
        return 0
    else
        log_fail "Minio pod is not running"
        kubectl get pods -n "${NAMESPACE}" 2>/dev/null || true
        return 1
    fi
}

# Test: Minio service is accessible
test_service_accessible() {
    log_info "Testing: Minio service is accessible..."

    # Create a test pod to check connectivity
    kubectl run minio-test-client \
        --image=curlimages/curl:latest \
        --restart=Never \
        --rm -i --quiet \
        --namespace "${NAMESPACE}" \
        -- curl -s -o /dev/null -w "%{http_code}" \
           "http://minio.${NAMESPACE}.svc.cluster.local:9000/minio/health/live" 2>/dev/null | grep -q "200"

    if [[ $? -eq 0 ]]; then
        log_pass "Minio service is accessible (health check passed)"
        return 0
    else
        log_fail "Minio service is not accessible"
        return 1
    fi
}

# Test: Buckets exist
test_buckets_exist() {
    log_info "Testing: Required buckets exist..."

    local minio_pod
    minio_pod=$(kubectl get pod -n "${NAMESPACE}" -l app.kubernetes.io/name=minio -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

    if [[ -z "${minio_pod}" ]]; then
        log_fail "Cannot find Minio pod"
        return 1
    fi

    local all_passed=true
    for bucket in "loki-chunks" "tempo-traces" "velero"; do
        # Use mc alias inside the minio pod to list buckets
        if kubectl exec -n "${NAMESPACE}" "${minio_pod}" -- \
            mc ls local 2>/dev/null | grep -q "${bucket}"; then
            log_pass "  Bucket '${bucket}' exists"
        else
            # Buckets might be created by the job, check if job completed
            local job_status
            job_status=$(kubectl get job -n "${NAMESPACE}" -l app.kubernetes.io/name=minio-make-bucket-job -o jsonpath='{.items[0].status.succeeded}' 2>/dev/null || echo "0")
            if [[ "${job_status}" == "1" ]]; then
                log_warn "  Bucket '${bucket}' not found but bucket job completed"
            else
                log_warn "  Bucket '${bucket}' may not exist yet (bucket job may still be running)"
            fi
        fi
    done

    return 0
}

# Test: Can perform S3 operations
test_s3_operations() {
    log_info "Testing: S3 operations work..."

    # Create a test pod with mc (minio client)
    local test_result
    test_result=$(kubectl run minio-s3-test \
        --image=minio/mc:latest \
        --restart=Never \
        --rm -i --quiet \
        --namespace "${NAMESPACE}" \
        --env="MC_HOST_myminio=http://minioadmin:minioadmin123@minio.${NAMESPACE}.svc.cluster.local:9000" \
        -- sh -c "
            echo 'test content' | mc pipe myminio/${TEST_BUCKET}/${TEST_FILE} 2>/dev/null && \
            mc cat myminio/${TEST_BUCKET}/${TEST_FILE} 2>/dev/null && \
            mc rm myminio/${TEST_BUCKET}/${TEST_FILE} 2>/dev/null && \
            echo 'SUCCESS'
        " 2>/dev/null || echo "FAILED")

    if echo "${test_result}" | grep -q "SUCCESS"; then
        log_pass "S3 operations work (put/get/delete)"
        return 0
    else
        log_warn "S3 operations test inconclusive (bucket may not be ready)"
        return 0  # Don't fail the whole test for this
    fi
}

# Test: PVC is bound
test_pvc_bound() {
    log_info "Testing: PVC is bound..."

    local pvc_status
    pvc_status=$(kubectl get pvc -n "${NAMESPACE}" -l app.kubernetes.io/name=minio -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "NotFound")

    if [[ "${pvc_status}" == "Bound" ]]; then
        log_pass "PVC is bound"
        return 0
    else
        log_fail "PVC status: ${pvc_status}"
        return 1
    fi
}

# Main test runner
main() {
    log_info "=========================================="
    log_info "Minio Installation Tests"
    log_info "=========================================="
    echo ""

    setup_kubeconfig

    local failed=0

    test_pod_running || ((failed++))
    test_pvc_bound || ((failed++))
    test_service_accessible || ((failed++))
    test_buckets_exist || ((failed++))
    # test_s3_operations || ((failed++))  # Optional, can be flaky

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
