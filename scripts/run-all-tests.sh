#!/usr/bin/env bash
# run-all-tests.sh - Run all integration tests
# This script orchestrates all component tests in the correct order
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_NAME="automation-k8s"
TOTAL_FAILED=0

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_section() { echo -e "\n${BLUE}========================================${NC}"; echo -e "${BLUE}$*${NC}"; echo -e "${BLUE}========================================${NC}\n"; }

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

# Check if cluster is accessible
check_cluster() {
    if ! kubectl cluster-info >/dev/null 2>&1; then
        log_error "Cannot connect to Kubernetes cluster."
        log_error "Please ensure the cluster is running: make cluster-up"
        exit 1
    fi
    log_info "Cluster is accessible"
}

# Run a test script and track failures
run_test() {
    local name="$1"
    local script="$2"

    log_section "Running: ${name}"

    if [[ ! -f "${script}" ]]; then
        log_warn "Test script not found: ${script}"
        return 0
    fi

    if [[ ! -x "${script}" ]]; then
        log_warn "Test script not executable: ${script}"
        chmod +x "${script}"
    fi

    local exit_code=0
    "${script}" || exit_code=$?

    if [[ ${exit_code} -eq 0 ]]; then
        log_info "${name}: PASSED"
    else
        log_error "${name}: FAILED (exit code: ${exit_code})"
        TOTAL_FAILED=$((TOTAL_FAILED + exit_code))
    fi

    return 0  # Don't fail the whole script on individual test failures
}

# Print final summary
print_summary() {
    log_section "Test Summary"

    if [[ ${TOTAL_FAILED} -eq 0 ]]; then
        log_info "All tests passed!"
    else
        log_error "Total failed tests: ${TOTAL_FAILED}"
    fi
}

main() {
    log_section "Running All Integration Tests"

    setup_kubeconfig
    check_cluster

    # Core infrastructure tests
    run_test "Storage Test" "${SCRIPT_DIR}/storage-test-up.sh"

    # Clean up storage test
    if [[ -f "${SCRIPT_DIR}/storage-test-down.sh" ]]; then
        "${SCRIPT_DIR}/storage-test-down.sh" || true
    fi

    # Observability tests
    run_test "Loki Test" "${SCRIPT_DIR}/loki-test.sh"
    run_test "Dashboards Test" "${SCRIPT_DIR}/dashboards-test.sh"

    # Backup tests
    run_test "Velero Test" "${SCRIPT_DIR}/velero-test.sh"

    # Application tests
    run_test "Home Automation Test" "${SCRIPT_DIR}/home-automation-test.sh"

    # Media stack test (only if deployed)
    if kubectl get namespace media >/dev/null 2>&1; then
        run_test "Media Stack Test" "${SCRIPT_DIR}/media-stack-test.sh"
    else
        log_warn "Media stack not deployed, skipping test"
    fi

    print_summary

    exit ${TOTAL_FAILED}
}

main "$@"
