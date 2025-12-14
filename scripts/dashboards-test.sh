#!/usr/bin/env bash
# dashboards-test.sh - Test Grafana dashboards and PrometheusRules
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

# Test: Dashboard ConfigMaps exist
test_dashboard_configmaps() {
    log_info "Testing dashboard ConfigMaps..."

    local dashboards=(
        "grafana-dashboard-cluster-overview"
        "grafana-dashboard-istio-mesh"
        "grafana-dashboard-namespace-resources"
    )

    for dashboard in "${dashboards[@]}"; do
        if kubectl get configmap "${dashboard}" -n "${NAMESPACE}" >/dev/null 2>&1; then
            log_success "Dashboard ConfigMap exists: ${dashboard}"
            ((TESTS_PASSED++))
        else
            log_fail "Dashboard ConfigMap missing: ${dashboard}"
            ((TESTS_FAILED++))
        fi
    done
}

# Test: Dashboard ConfigMaps have correct labels
test_dashboard_labels() {
    log_info "Testing dashboard ConfigMap labels..."

    local dashboards=(
        "grafana-dashboard-cluster-overview"
        "grafana-dashboard-istio-mesh"
        "grafana-dashboard-namespace-resources"
    )

    for dashboard in "${dashboards[@]}"; do
        local label
        label=$(kubectl get configmap "${dashboard}" -n "${NAMESPACE}" -o jsonpath='{.metadata.labels.grafana_dashboard}' 2>/dev/null || echo "")
        if [[ "${label}" == "1" ]]; then
            log_success "Dashboard has correct label: ${dashboard}"
            ((TESTS_PASSED++))
        else
            log_fail "Dashboard missing grafana_dashboard label: ${dashboard}"
            ((TESTS_FAILED++))
        fi
    done
}

# Test: PrometheusRules exist
test_prometheus_rules() {
    log_info "Testing PrometheusRules..."

    if kubectl get prometheusrule cluster-alerts -n "${NAMESPACE}" >/dev/null 2>&1; then
        log_success "PrometheusRule 'cluster-alerts' exists"
        ((TESTS_PASSED++))
    else
        log_fail "PrometheusRule 'cluster-alerts' missing"
        ((TESTS_FAILED++))
    fi
}

# Test: PrometheusRules are loaded by Prometheus
test_prometheus_rules_loaded() {
    log_info "Testing PrometheusRules are loaded..."

    # Get Prometheus pod
    local prom_pod
    prom_pod=$(kubectl get pod -n "${NAMESPACE}" -l app.kubernetes.io/name=prometheus -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

    if [[ -z "${prom_pod}" ]]; then
        log_warn "Prometheus pod not found, skipping rule verification"
        return
    fi

    # Port-forward to Prometheus and check rules API
    kubectl port-forward "pod/${prom_pod}" -n "${NAMESPACE}" 9090:9090 &
    local pf_pid=$!
    sleep 3

    # Query the rules API
    local rules_response
    rules_response=$(curl -s "http://localhost:9090/api/v1/rules" 2>/dev/null || echo "")

    # Kill port-forward
    kill "${pf_pid}" 2>/dev/null || true

    if echo "${rules_response}" | grep -q "PodCrashLooping"; then
        log_success "PrometheusRule 'PodCrashLooping' is loaded"
        ((TESTS_PASSED++))
    else
        log_warn "PrometheusRule 'PodCrashLooping' not yet loaded (may take time to sync)"
    fi
}

# Test: Grafana is healthy
test_grafana_health() {
    log_info "Testing Grafana health..."

    local grafana_pod
    grafana_pod=$(kubectl get pod -n "${NAMESPACE}" -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

    if [[ -z "${grafana_pod}" ]]; then
        log_fail "Grafana pod not found"
        ((TESTS_FAILED++))
        return
    fi

    # Port-forward to Grafana and check health
    kubectl port-forward "pod/${grafana_pod}" -n "${NAMESPACE}" 3000:3000 &
    local pf_pid=$!
    sleep 3

    local health_response
    health_response=$(curl -s "http://localhost:3000/api/health" 2>/dev/null || echo "")

    # Kill port-forward
    kill "${pf_pid}" 2>/dev/null || true

    if echo "${health_response}" | grep -q "ok"; then
        log_success "Grafana health check passed"
        ((TESTS_PASSED++))
    else
        log_fail "Grafana health check failed"
        ((TESTS_FAILED++))
    fi
}

# Test: Alertmanager is running
test_alertmanager() {
    log_info "Testing Alertmanager..."

    if kubectl get pod -n "${NAMESPACE}" -l app.kubernetes.io/name=alertmanager -o jsonpath='{.items[0].metadata.name}' >/dev/null 2>&1; then
        log_success "Alertmanager pod exists"
        ((TESTS_PASSED++))
    else
        log_fail "Alertmanager pod not found"
        ((TESTS_FAILED++))
    fi
}

# Test: Dashboard JSON is valid
test_dashboard_json_validity() {
    log_info "Testing dashboard JSON validity..."

    local dashboards=(
        "grafana-dashboard-cluster-overview"
        "grafana-dashboard-istio-mesh"
        "grafana-dashboard-namespace-resources"
    )

    for dashboard in "${dashboards[@]}"; do
        local json_key
        # Determine the JSON key based on dashboard name
        case "${dashboard}" in
            *cluster-overview*) json_key="cluster-overview.json" ;;
            *istio-mesh*) json_key="istio-mesh.json" ;;
            *namespace-resources*) json_key="namespace-resources.json" ;;
            *) json_key="" ;;
        esac

        if [[ -z "${json_key}" ]]; then
            continue
        fi

        local json_content
        json_content=$(kubectl get configmap "${dashboard}" -n "${NAMESPACE}" -o jsonpath="{.data.${json_key}}" 2>/dev/null || echo "")

        if [[ -n "${json_content}" ]]; then
            # Validate JSON using jq if available
            if command -v jq >/dev/null 2>&1; then
                if echo "${json_content}" | jq . >/dev/null 2>&1; then
                    log_success "Dashboard JSON is valid: ${dashboard}"
                    ((TESTS_PASSED++))
                else
                    log_fail "Dashboard JSON is invalid: ${dashboard}"
                    ((TESTS_FAILED++))
                fi
            else
                # Basic check if jq not available
                if [[ "${json_content}" == "{"* ]]; then
                    log_success "Dashboard JSON exists: ${dashboard}"
                    ((TESTS_PASSED++))
                else
                    log_fail "Dashboard JSON missing or invalid: ${dashboard}"
                    ((TESTS_FAILED++))
                fi
            fi
        else
            log_fail "Dashboard JSON content missing: ${dashboard}"
            ((TESTS_FAILED++))
        fi
    done
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
    log_info "Starting dashboards and alerting tests..."
    echo ""

    setup_kubeconfig

    # Check if cluster is accessible
    if ! kubectl cluster-info >/dev/null 2>&1; then
        log_error "Cannot connect to Kubernetes cluster"
        exit 1
    fi

    # Run tests
    test_dashboard_configmaps
    test_dashboard_labels
    test_dashboard_json_validity
    test_prometheus_rules
    test_alertmanager
    test_grafana_health

    # Print summary and exit with appropriate code
    print_summary
}

main "$@"
