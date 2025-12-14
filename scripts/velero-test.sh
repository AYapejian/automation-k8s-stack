#!/usr/bin/env bash
# velero-test.sh - Test Velero backup and restore functionality
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="velero"
TEST_NAMESPACE="velero-test"
CLUSTER_NAME="automation-k8s"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_success() { echo -e "${GREEN}[PASS]${NC} $*"; }
log_fail() { echo -e "${RED}[FAIL]${NC} $*"; }

# Track test results
TESTS_PASSED=0
TESTS_FAILED=0

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

# Test: Velero deployment is running
test_velero_deployment() {
    log_info "Testing Velero deployment..."

    if kubectl get deployment velero -n "${NAMESPACE}" >/dev/null 2>&1; then
        local ready
        ready=$(kubectl get deployment velero -n "${NAMESPACE}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
        if [[ "${ready}" -ge 1 ]]; then
            log_success "Velero deployment is running (${ready} replicas ready)"
            ((TESTS_PASSED++))
        else
            log_fail "Velero deployment not ready"
            ((TESTS_FAILED++))
        fi
    else
        log_fail "Velero deployment not found"
        ((TESTS_FAILED++))
    fi
}

# Test: Node agent (restic) is running
test_node_agent() {
    log_info "Testing node agent (restic) daemonset..."

    if kubectl get daemonset -n "${NAMESPACE}" -l app.kubernetes.io/name=velero -o name 2>/dev/null | grep -q daemonset; then
        log_success "Node agent daemonset exists"
        ((TESTS_PASSED++))
    else
        log_warn "Node agent daemonset not found (may not be configured)"
    fi
}

# Test: Backup storage location is available
test_backup_storage_location() {
    log_info "Testing backup storage location..."

    local phase
    phase=$(kubectl get backupstoragelocation default -n "${NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")

    if [[ "${phase}" == "Available" ]]; then
        log_success "Backup storage location is Available"
        ((TESTS_PASSED++))
    elif [[ "${phase}" == "NotFound" ]]; then
        log_fail "Backup storage location not found"
        ((TESTS_FAILED++))
    else
        log_warn "Backup storage location phase: ${phase} (may need time to sync)"
        # Give it some time to become available
        log_info "Waiting for storage location to become available..."
        for i in {1..10}; do
            sleep 5
            phase=$(kubectl get backupstoragelocation default -n "${NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
            if [[ "${phase}" == "Available" ]]; then
                log_success "Backup storage location is now Available"
                ((TESTS_PASSED++))
                return
            fi
        done
        log_fail "Backup storage location did not become Available (current: ${phase})"
        ((TESTS_FAILED++))
    fi
}

# Test: Scheduled backup exists
test_scheduled_backup() {
    log_info "Testing scheduled backup..."

    if kubectl get schedule daily-backup -n "${NAMESPACE}" >/dev/null 2>&1; then
        log_success "Scheduled backup 'daily-backup' exists"
        ((TESTS_PASSED++))
    else
        log_fail "Scheduled backup not found"
        ((TESTS_FAILED++))
    fi
}

# Test: Create test namespace with resources
create_test_resources() {
    log_info "Creating test namespace and resources..."

    # Create test namespace
    kubectl create namespace "${TEST_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

    # Create a ConfigMap
    kubectl apply -n "${TEST_NAMESPACE}" -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: test-config
  labels:
    app: velero-test
data:
  test-key: "test-value-$(date +%s)"
EOF

    # Create a Deployment
    kubectl apply -n "${TEST_NAMESPACE}" -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-app
  labels:
    app: velero-test
spec:
  replicas: 1
  selector:
    matchLabels:
      app: velero-test
  template:
    metadata:
      labels:
        app: velero-test
    spec:
      containers:
      - name: nginx
        image: nginx:alpine
        ports:
        - containerPort: 80
EOF

    # Wait for deployment to be ready
    kubectl wait --for=condition=Available deployment/test-app -n "${TEST_NAMESPACE}" --timeout=120s || {
        log_warn "Test deployment not ready, continuing anyway..."
    }

    log_info "Test resources created"
}

# Test: Create manual backup
test_create_backup() {
    log_info "Testing backup creation..."

    local backup_name="test-backup-$(date +%s)"

    # Create backup using velero CLI inside the pod
    kubectl exec -n "${NAMESPACE}" deploy/velero -- \
        /velero backup create "${backup_name}" \
        --include-namespaces "${TEST_NAMESPACE}" \
        --wait 2>&1 || {
        log_fail "Failed to create backup"
        ((TESTS_FAILED++))
        return
    }

    # Check backup status
    local phase
    phase=$(kubectl get backup "${backup_name}" -n "${NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")

    if [[ "${phase}" == "Completed" ]]; then
        log_success "Backup '${backup_name}' completed successfully"
        ((TESTS_PASSED++))
        echo "${backup_name}" > /tmp/velero-test-backup-name
    else
        log_fail "Backup phase: ${phase} (expected: Completed)"
        ((TESTS_FAILED++))
    fi
}

# Test: Restore from backup
test_restore_backup() {
    log_info "Testing restore from backup..."

    # Get the backup name from the previous test
    if [[ ! -f /tmp/velero-test-backup-name ]]; then
        log_warn "No backup name found, skipping restore test"
        return
    fi

    local backup_name
    backup_name=$(cat /tmp/velero-test-backup-name)

    # Delete the test namespace
    log_info "Deleting test namespace to prepare for restore..."
    kubectl delete namespace "${TEST_NAMESPACE}" --wait --timeout=60s || {
        log_warn "Namespace deletion timed out, forcing..."
        kubectl delete namespace "${TEST_NAMESPACE}" --force --grace-period=0 2>/dev/null || true
    }

    # Wait for namespace to be fully deleted
    sleep 5

    # Restore from backup
    local restore_name="test-restore-$(date +%s)"
    kubectl exec -n "${NAMESPACE}" deploy/velero -- \
        /velero restore create "${restore_name}" \
        --from-backup "${backup_name}" \
        --wait 2>&1 || {
        log_fail "Failed to create restore"
        ((TESTS_FAILED++))
        return
    }

    # Check restore status
    local phase
    phase=$(kubectl get restore "${restore_name}" -n "${NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")

    if [[ "${phase}" == "Completed" ]] || [[ "${phase}" == "PartiallyFailed" ]]; then
        log_success "Restore '${restore_name}' completed (phase: ${phase})"
        ((TESTS_PASSED++))
    else
        log_fail "Restore phase: ${phase} (expected: Completed)"
        ((TESTS_FAILED++))
        return
    fi

    # Verify restored resources
    log_info "Verifying restored resources..."
    if kubectl get configmap test-config -n "${TEST_NAMESPACE}" >/dev/null 2>&1; then
        log_success "ConfigMap was restored successfully"
        ((TESTS_PASSED++))
    else
        log_fail "ConfigMap not found after restore"
        ((TESTS_FAILED++))
    fi

    if kubectl get deployment test-app -n "${TEST_NAMESPACE}" >/dev/null 2>&1; then
        log_success "Deployment was restored successfully"
        ((TESTS_PASSED++))
    else
        log_fail "Deployment not found after restore"
        ((TESTS_FAILED++))
    fi
}

# Cleanup test resources
cleanup_test_resources() {
    log_info "Cleaning up test resources..."
    kubectl delete namespace "${TEST_NAMESPACE}" --ignore-not-found=true --wait=false 2>/dev/null || true
    rm -f /tmp/velero-test-backup-name
}

# Print test summary
print_summary() {
    echo ""
    echo "=========================================="
    echo "Test Summary"
    echo "=========================================="
    echo -e "Passed: ${GREEN}${TESTS_PASSED}${NC}"
    echo -e "Failed: ${RED}${TESTS_FAILED}${NC}"
    echo ""

    if [[ ${TESTS_FAILED} -gt 0 ]]; then
        log_error "Some tests failed!"
        return 1
    else
        log_success "All tests passed!"
        return 0
    fi
}

main() {
    log_info "Starting Velero tests..."
    echo ""

    setup_kubeconfig

    # Check if cluster is accessible
    if ! kubectl cluster-info >/dev/null 2>&1; then
        log_error "Cannot connect to Kubernetes cluster"
        exit 1
    fi

    # Run tests
    test_velero_deployment
    test_node_agent
    test_backup_storage_location
    test_scheduled_backup

    # Full backup/restore test
    create_test_resources
    test_create_backup
    test_restore_backup

    # Cleanup
    cleanup_test_resources

    # Print summary and exit with appropriate code
    print_summary
}

main "$@"
