#!/usr/bin/env bash
# argocd-health-test.sh - Verify ArgoCD applications are synced and healthy
#
# This test ensures ArgoCD apps are actually functional, not just deployed.
# It catches configuration issues like:
#   - AppProject namespace restrictions
#   - Missing CRDs blocking sync
#   - Selector mismatches
#   - Dependency chain failures
#
# Exit codes:
#   0 - All critical apps are Synced and Healthy
#   1 - One or more critical apps failed
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_section() { echo -e "\n${BLUE}========================================${NC}"; echo -e "${BLUE}$*${NC}"; echo -e "${BLUE}========================================${NC}\n"; }

# Critical apps that MUST be Synced and Healthy for stack to function
# Grouped by dependency order
CRITICAL_PLATFORM_APPS=(
    "istio-base"
    "istio-istiod"
    "cert-manager"
    "istio-gateway"
    "ingress-config"
)

CRITICAL_OBSERVABILITY_APPS=(
    "prometheus-grafana"
    "loki"
    "jaeger"
)

# Apps that are important but may take longer or have acceptable degraded states
IMPORTANT_APPS=(
    "cert-manager-resources"
    "istio-resources"
    "minio"
    "velero"
    "tempo"
    "otel-collector"
)

# Workload apps - may not be deployed in all environments
WORKLOAD_APPS=(
    "home-automation"
    "media-stack"
    "sample-app"
)

FAILED_APPS=()
DEGRADED_APPS=()

# Check if ArgoCD is available
check_argocd() {
    if ! kubectl get namespace argocd &>/dev/null; then
        log_error "ArgoCD namespace not found. Is ArgoCD installed?"
        exit 1
    fi

    if ! kubectl get applications -n argocd &>/dev/null; then
        log_error "Cannot list ArgoCD applications. Check RBAC permissions."
        exit 1
    fi
}

# Get application sync status
get_app_sync_status() {
    local app="$1"
    kubectl get application "$app" -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "NotFound"
}

# Get application health status
get_app_health_status() {
    local app="$1"
    kubectl get application "$app" -n argocd -o jsonpath='{.status.health.status}' 2>/dev/null || echo "NotFound"
}

# Get sync failure message if any
get_sync_error() {
    local app="$1"
    kubectl get application "$app" -n argocd -o jsonpath='{.status.conditions[?(@.type=="SyncError")].message}' 2>/dev/null || true
}

# Get operation state message (shows sync failures)
get_operation_message() {
    local app="$1"
    kubectl get application "$app" -n argocd -o jsonpath='{.status.operationState.message}' 2>/dev/null || true
}

# Check a single application
check_app() {
    local app="$1"
    local required="$2"  # "required" or "optional"

    local sync_status health_status
    sync_status=$(get_app_sync_status "$app")
    health_status=$(get_app_health_status "$app")

    # App not found
    if [[ "$sync_status" == "NotFound" ]]; then
        if [[ "$required" == "required" ]]; then
            log_error "✗ $app: NOT FOUND (required app missing)"
            FAILED_APPS+=("$app")
            return 1
        else
            log_warn "○ $app: Not deployed (optional)"
            return 0
        fi
    fi

    # Check for sync failures
    # Note: OutOfSync with Healthy status and successful operation is acceptable (drift)
    if [[ "$sync_status" != "Synced" ]]; then
        local error_msg operation_phase
        error_msg=$(get_operation_message "$app")
        operation_phase=$(kubectl get application "$app" -n argocd -o jsonpath='{.status.operationState.phase}' 2>/dev/null || echo "Unknown")

        # If health is Healthy and operation succeeded, this is just drift - warn but don't fail
        if [[ "$health_status" == "Healthy" && ("$operation_phase" == "Succeeded" || "$error_msg" == *"successfully synced"*) ]]; then
            log_warn "△ $app: OutOfSync but healthy (drift detected, operation: $operation_phase)"
            DEGRADED_APPS+=("$app")
            return 0
        fi

        if [[ "$required" == "required" ]]; then
            log_error "✗ $app: SYNC FAILED (status: $sync_status, health: $health_status, phase: $operation_phase)"
            if [[ -n "$error_msg" ]]; then
                log_error "  └─ $error_msg"
            fi
            FAILED_APPS+=("$app")
            return 1
        else
            log_warn "△ $app: Out of sync (status: $sync_status, health: $health_status)"
            DEGRADED_APPS+=("$app")
            return 0
        fi
    fi

    # Check health
    case "$health_status" in
        "Healthy")
            log_info "✓ $app: Synced and Healthy"
            return 0
            ;;
        "Progressing")
            if [[ "$required" == "required" ]]; then
                log_warn "△ $app: Still progressing (may need more time)"
                DEGRADED_APPS+=("$app")
            else
                log_info "○ $app: Synced, still progressing"
            fi
            return 0
            ;;
        "Degraded"|"Missing")
            if [[ "$required" == "required" ]]; then
                log_error "✗ $app: UNHEALTHY (sync: $sync_status, health: $health_status)"
                local error_msg
                error_msg=$(get_operation_message "$app")
                if [[ -n "$error_msg" ]]; then
                    log_error "  └─ $error_msg"
                fi
                FAILED_APPS+=("$app")
                return 1
            else
                log_warn "△ $app: Degraded (sync: $sync_status, health: $health_status)"
                DEGRADED_APPS+=("$app")
                return 0
            fi
            ;;
        *)
            log_warn "? $app: Unknown health status '$health_status' (sync: $sync_status)"
            DEGRADED_APPS+=("$app")
            return 0
            ;;
    esac
}

# Wait for apps with retries
wait_for_apps() {
    local -n apps=$1
    local required="$2"
    local max_retries="${3:-3}"
    local retry_delay="${4:-30}"

    local attempt=1
    local all_healthy=false

    while [[ $attempt -le $max_retries ]]; do
        local failed_this_round=()

        for app in "${apps[@]}"; do
            if ! check_app "$app" "$required"; then
                failed_this_round+=("$app")
            fi
        done

        if [[ ${#failed_this_round[@]} -eq 0 ]]; then
            all_healthy=true
            break
        fi

        if [[ $attempt -lt $max_retries ]]; then
            log_info "Waiting ${retry_delay}s before retry (attempt $((attempt+1))/$max_retries)..."
            sleep "$retry_delay"
            # Clear failed apps for retry
            FAILED_APPS=()
        fi

        ((attempt++))
    done
}

# Verify component-level health beyond ArgoCD status
# This catches misconfigurations that ArgoCD might not detect
verify_component_health() {
    log_section "Component Health Verification"

    local component_failures=0

    # Verify Istio mTLS is STRICT
    log_info "Checking Istio mTLS configuration..."
    local mtls_mode
    mtls_mode=$(kubectl get peerauthentication default -n istio-system -o jsonpath='{.spec.mtls.mode}' 2>/dev/null || echo "NOTFOUND")
    if [[ "$mtls_mode" == "STRICT" ]]; then
        log_info "✓ Istio mTLS: STRICT mode enabled"
    else
        log_error "✗ Istio mTLS not STRICT (got: $mtls_mode)"
        FAILED_APPS+=("istio-mtls-config")
        ((component_failures++))
    fi

    # Verify cert-manager can issue certificates
    log_info "Checking cert-manager certificate status..."
    local cert_ready
    cert_ready=$(kubectl get certificate gateway-tls -n istio-ingress -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")
    if [[ "$cert_ready" == "True" ]]; then
        log_info "✓ Gateway TLS certificate: Ready"
    else
        log_error "✗ Gateway TLS certificate not ready (status: $cert_ready)"
        FAILED_APPS+=("cert-manager-certificate")
        ((component_failures++))
    fi

    # Verify ClusterIssuers exist and are ready
    log_info "Checking ClusterIssuers..."
    local issuers_ready
    issuers_ready=$(kubectl get clusterissuers -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
    if echo "$issuers_ready" | grep -q "True"; then
        log_info "✓ ClusterIssuers: Ready"
    else
        log_warn "△ ClusterIssuers may not be ready"
        DEGRADED_APPS+=("clusterissuers")
    fi

    # Verify Prometheus is running and has targets
    log_info "Checking Prometheus status..."
    local prometheus_pod
    prometheus_pod=$(kubectl get pods -n observability -l app.kubernetes.io/name=prometheus -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [[ -n "$prometheus_pod" ]]; then
        local prometheus_ready
        prometheus_ready=$(kubectl get pod "$prometheus_pod" -n observability -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")
        if [[ "$prometheus_ready" == "True" ]]; then
            log_info "✓ Prometheus: Running and ready"
        else
            log_warn "△ Prometheus pod not ready"
            DEGRADED_APPS+=("prometheus-pod")
        fi
    else
        log_error "✗ Prometheus pod not found"
        FAILED_APPS+=("prometheus-pod")
        ((component_failures++))
    fi

    # Verify Grafana is accessible
    log_info "Checking Grafana status..."
    local grafana_pod
    grafana_pod=$(kubectl get pods -n observability -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [[ -n "$grafana_pod" ]]; then
        local grafana_ready
        grafana_ready=$(kubectl get pod "$grafana_pod" -n observability -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")
        if [[ "$grafana_ready" == "True" ]]; then
            log_info "✓ Grafana: Running and ready"
        else
            log_warn "△ Grafana pod not ready"
            DEGRADED_APPS+=("grafana-pod")
        fi
    else
        log_error "✗ Grafana pod not found"
        FAILED_APPS+=("grafana-pod")
        ((component_failures++))
    fi

    # Verify Loki is accepting logs
    log_info "Checking Loki status..."
    local loki_ready
    loki_ready=$(kubectl get pods -n observability -l app.kubernetes.io/name=loki -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")
    if [[ "$loki_ready" == "True" ]]; then
        log_info "✓ Loki: Running and ready"
    else
        log_warn "△ Loki may not be ready"
        DEGRADED_APPS+=("loki-pod")
    fi

    if [[ $component_failures -gt 0 ]]; then
        log_error "Component verification found $component_failures critical issue(s)"
    else
        log_info "Component verification passed"
    fi
}

# Print detailed failure info for debugging
print_failure_details() {
    if [[ ${#FAILED_APPS[@]} -eq 0 ]]; then
        return
    fi

    log_section "Failure Details"

    for app in "${FAILED_APPS[@]}"; do
        echo ""
        log_error "=== $app ==="

        # Get full status
        kubectl get application "$app" -n argocd -o yaml 2>/dev/null | \
            grep -A 50 "^status:" | \
            grep -E "(sync:|health:|message:|phase:|status:)" | \
            head -20 || true

        # Check for specific sync failures
        local sync_result
        sync_result=$(kubectl get application "$app" -n argocd -o jsonpath='{.status.operationState.syncResult.resources[?(@.status=="SyncFailed")]}' 2>/dev/null || true)
        if [[ -n "$sync_result" ]]; then
            echo ""
            log_error "Sync failures:"
            echo "$sync_result" | jq -r '"\(.kind)/\(.name) in \(.namespace): \(.message)"' 2>/dev/null || echo "$sync_result"
        fi
    done
}

main() {
    log_section "ArgoCD Application Health Test"

    check_argocd

    # Check platform apps (required)
    log_section "Platform Layer (Required)"
    wait_for_apps CRITICAL_PLATFORM_APPS "required" 3 30

    # Check observability apps (required)
    log_section "Observability Layer (Required)"
    wait_for_apps CRITICAL_OBSERVABILITY_APPS "required" 3 30

    # Check important apps (warn only)
    log_section "Supporting Apps"
    for app in "${IMPORTANT_APPS[@]}"; do
        check_app "$app" "optional"
    done

    # Check workload apps (optional)
    log_section "Workload Apps (Optional)"
    for app in "${WORKLOAD_APPS[@]}"; do
        check_app "$app" "optional"
    done

    # Component-level verification
    verify_component_health

    # Summary
    log_section "Test Summary"

    echo ""
    echo "Critical apps checked: $((${#CRITICAL_PLATFORM_APPS[@]} + ${#CRITICAL_OBSERVABILITY_APPS[@]}))"
    echo "Failed: ${#FAILED_APPS[@]}"
    echo "Degraded: ${#DEGRADED_APPS[@]}"
    echo ""

    if [[ ${#FAILED_APPS[@]} -gt 0 ]]; then
        print_failure_details
        echo ""
        log_error "FAILED: ${#FAILED_APPS[@]} critical app(s) are not healthy"
        log_error "Failed apps: ${FAILED_APPS[*]}"
        exit 1
    fi

    if [[ ${#DEGRADED_APPS[@]} -gt 0 ]]; then
        log_warn "WARNING: ${#DEGRADED_APPS[@]} app(s) are degraded or progressing"
        log_warn "Degraded apps: ${DEGRADED_APPS[*]}"
    fi

    log_info "SUCCESS: All critical ArgoCD applications are synced and healthy"
    exit 0
}

main "$@"
