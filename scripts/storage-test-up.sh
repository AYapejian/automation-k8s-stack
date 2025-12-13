#!/usr/bin/env bash
# storage-test-up.sh - Test storage provisioning by creating PVC and writing data
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_DIR="${REPO_ROOT}/tests/storage"
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
            log_info "Using k3d cluster context: ${CLUSTER_NAME}"
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

    # Setup k3d kubeconfig
    setup_kubeconfig

    # Check if cluster is accessible
    if ! kubectl cluster-info >/dev/null 2>&1; then
        log_error "Cannot connect to Kubernetes cluster. Is the cluster running?"
        log_error "Run 'make cluster-up' first."
        exit 1
    fi

    # Verify we're connected to the right cluster
    local current_context
    current_context=$(kubectl config current-context 2>/dev/null || echo "unknown")
    log_info "Connected to cluster context: ${current_context}"

    # Check test manifests exist
    if [[ ! -f "${TEST_DIR}/test-pvc.yaml" ]]; then
        log_error "Test PVC manifest not found: ${TEST_DIR}/test-pvc.yaml"
        exit 1
    fi
    if [[ ! -f "${TEST_DIR}/test-pod.yaml" ]]; then
        log_error "Test pod manifest not found: ${TEST_DIR}/test-pod.yaml"
        exit 1
    fi
}

# Clean up any existing test resources
cleanup_existing() {
    log_info "Cleaning up any existing test resources..."
    kubectl delete pod storage-test -n default --ignore-not-found=true >/dev/null 2>&1 || true
    kubectl delete pvc storage-test -n default --ignore-not-found=true >/dev/null 2>&1 || true

    # Wait for PVC to be fully deleted
    local attempts=0
    while kubectl get pvc storage-test -n default >/dev/null 2>&1; do
        if [[ $attempts -ge 30 ]]; then
            log_warn "Timeout waiting for PVC deletion, proceeding anyway..."
            break
        fi
        sleep 1
        ((++attempts))
    done
}

# Show StorageClass info
show_storage_info() {
    log_info "Available StorageClasses:"
    kubectl get storageclass
    echo ""
}

# Create PVC
create_pvc() {
    log_info "Creating test PVC..."
    kubectl apply -f "${TEST_DIR}/test-pvc.yaml"

    # PVC stays Pending with WaitForFirstConsumer until pod is created
    log_info "PVC created (will bind when pod is scheduled)"
    kubectl get pvc storage-test -n default
}

# Create test pod
create_pod() {
    log_info "Creating test pod..."
    kubectl apply -f "${TEST_DIR}/test-pod.yaml"
}

# Wait for PVC to bind
wait_for_pvc() {
    log_info "Waiting for PVC to bind..."

    local attempts=0
    local max_attempts=60

    while [[ $attempts -lt $max_attempts ]]; do
        local status
        status=$(kubectl get pvc storage-test -n default -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")

        if [[ "${status}" == "Bound" ]]; then
            log_info "PVC bound successfully!"
            kubectl get pvc storage-test -n default
            return 0
        fi

        sleep 2
        ((++attempts))
    done

    log_error "Timeout waiting for PVC to bind"
    kubectl describe pvc storage-test -n default
    return 1
}

# Wait for pod to complete
wait_for_pod() {
    log_info "Waiting for test pod to complete..."

    # Wait for pod to start
    if ! kubectl wait --for=condition=Ready pod/storage-test -n default --timeout=120s 2>/dev/null; then
        # Pod might have completed already, check status
        local phase
        phase=$(kubectl get pod storage-test -n default -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")

        if [[ "${phase}" != "Succeeded" && "${phase}" != "Running" ]]; then
            log_error "Pod failed to start. Phase: ${phase}"
            kubectl describe pod storage-test -n default
            return 1
        fi
    fi

    # Wait for completion
    local attempts=0
    local max_attempts=30

    while [[ $attempts -lt $max_attempts ]]; do
        local phase
        phase=$(kubectl get pod storage-test -n default -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")

        if [[ "${phase}" == "Succeeded" ]]; then
            log_info "Pod completed successfully!"
            return 0
        elif [[ "${phase}" == "Failed" ]]; then
            log_error "Pod failed!"
            kubectl logs storage-test -n default || true
            return 1
        fi

        sleep 2
        ((++attempts))
    done

    log_warn "Pod did not complete in time, checking logs..."
}

# Verify test passed
verify_test() {
    log_info "Verifying storage test results..."

    local logs
    logs=$(kubectl logs storage-test -n default 2>/dev/null || echo "")

    echo ""
    echo "Pod logs:"
    echo "---"
    echo "${logs}"
    echo "---"
    echo ""

    if echo "${logs}" | grep -q "Storage test passed"; then
        log_info "Storage test PASSED! Data was written to PVC successfully."
        return 0
    else
        log_error "Storage test FAILED! Expected 'Storage test passed' in logs."
        return 1
    fi
}

# Print summary
print_summary() {
    echo ""
    log_info "=========================================="
    log_info "Storage Test Summary"
    log_info "=========================================="
    echo ""
    local sc_name
    sc_name=$(kubectl get pvc storage-test -n default -o jsonpath='{.spec.storageClassName}' 2>/dev/null || echo "default")
    echo "StorageClass used: ${sc_name}"
    echo "PVC status:"
    kubectl get pvc storage-test -n default
    echo ""
    echo "PV created:"
    kubectl get pv | grep storage-test || echo "  (PV details not available)"
    echo ""
    echo "Cleanup:"
    echo "  make storage-test-down  # Remove test resources"
    echo ""
}

main() {
    log_info "Running storage provisioning test..."

    check_prerequisites
    show_storage_info
    cleanup_existing
    create_pvc
    create_pod
    wait_for_pvc
    wait_for_pod
    verify_test
    print_summary

    log_info "Storage test completed successfully!"
}

main "$@"
