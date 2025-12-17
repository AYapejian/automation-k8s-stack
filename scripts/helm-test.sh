#!/usr/bin/env bash
# helm-test.sh - Run Helm tests for deployed charts
# Validates chart functionality beyond simple pod readiness
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_NAME="automation-k8s"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_pass() { echo -e "${GREEN}[PASS]${NC} $*"; }
log_fail() { echo -e "${RED}[FAIL]${NC} $*"; }
log_section() { echo -e "\n${BLUE}${BOLD}=== $* ===${NC}"; }

# Track test results
PASSED_TESTS=0
FAILED_TESTS=0
SKIPPED_TESTS=0

# Charts known to have built-in Helm tests
# Format: "release-name:namespace"
TESTABLE_CHARTS=(
    "prometheus-grafana:observability"
    "loki:observability"
    "cert-manager:cert-manager"
)

# Setup kubeconfig for k3d cluster
setup_kubeconfig() {
    if command -v k3d &> /dev/null; then
        local kubeconfig
        kubeconfig=$(k3d kubeconfig write "${CLUSTER_NAME}" 2>/dev/null) || true
        if [[ -n "$kubeconfig" ]]; then
            export KUBECONFIG="$kubeconfig"
        fi
    fi
}

# Check if a Helm release exists
release_exists() {
    local release="$1"
    local namespace="$2"
    helm status "$release" -n "$namespace" >/dev/null 2>&1
}

# Run Helm test for a release
run_helm_test() {
    local release="$1"
    local namespace="$2"
    local timeout="${3:-180s}"

    if ! release_exists "$release" "$namespace"; then
        log_warn "Release '$release' not found in namespace '$namespace', skipping"
        SKIPPED_TESTS=$((SKIPPED_TESTS + 1))
        return 0
    fi

    log_info "Testing $release in $namespace (timeout: $timeout)..."

    # Run helm test with timeout
    if helm test "$release" -n "$namespace" --timeout "$timeout" 2>&1; then
        log_pass "$release tests passed"
        PASSED_TESTS=$((PASSED_TESTS + 1))
        return 0
    else
        log_fail "$release tests failed"
        FAILED_TESTS=$((FAILED_TESTS + 1))

        # Show pod logs for failed tests
        log_info "Fetching test pod logs for debugging..."
        kubectl get pods -n "$namespace" -l "helm.sh/chart" --show-labels 2>/dev/null || true

        return 1
    fi
}

# Run all configured Helm tests
run_all_tests() {
    log_section "Helm Test Suite"

    for chart_info in "${TESTABLE_CHARTS[@]}"; do
        local release="${chart_info%%:*}"
        local namespace="${chart_info##*:}"

        run_helm_test "$release" "$namespace" || true
    done
}

# Print summary
print_summary() {
    log_section "Test Summary"

    local total=$((PASSED_TESTS + FAILED_TESTS + SKIPPED_TESTS))

    echo -e "Total:   ${BOLD}$total${NC}"
    echo -e "Passed:  ${GREEN}$PASSED_TESTS${NC}"
    echo -e "Failed:  ${RED}$FAILED_TESTS${NC}"
    echo -e "Skipped: ${YELLOW}$SKIPPED_TESTS${NC}"
    echo ""

    if [[ $FAILED_TESTS -gt 0 ]]; then
        log_error "$FAILED_TESTS Helm test(s) failed"
        return 1
    elif [[ $PASSED_TESTS -eq 0 && $SKIPPED_TESTS -gt 0 ]]; then
        log_warn "No Helm tests ran (all skipped)"
        return 0
    else
        log_info "All Helm tests passed"
        return 0
    fi
}

# Main function
main() {
    log_section "Helm Test Runner"

    # Setup kubeconfig
    setup_kubeconfig

    # Verify kubectl is available
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl not found"
        exit 1
    fi

    # Verify helm is available
    if ! command -v helm &> /dev/null; then
        log_error "helm not found"
        exit 1
    fi

    # Run tests
    run_all_tests

    # Print summary and exit with appropriate code
    print_summary
}

main "$@"
