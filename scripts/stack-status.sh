#!/usr/bin/env bash
# stack-status.sh - Show overall stack health status
set -euo pipefail

CLUSTER_NAME="automation-k8s"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Status indicators
status_ok() { echo -e "  ${GREEN}[OK]${NC} $*"; }
status_warn() { echo -e "  ${YELLOW}[WARN]${NC} $*"; }
status_fail() { echo -e "  ${RED}[FAIL]${NC} $*"; }

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

# Check if cluster exists and is running
check_cluster() {
    echo -e "${BOLD}Cluster${NC}"
    if ! command -v k3d >/dev/null 2>&1; then
        status_fail "k3d not installed"
        return 1
    fi

    if k3d cluster list -o json 2>/dev/null | jq -e ".[] | select(.name == \"${CLUSTER_NAME}\")" >/dev/null 2>&1; then
        local servers_running
        servers_running=$(k3d cluster list -o json | jq -r ".[] | select(.name == \"${CLUSTER_NAME}\") | .serversRunning")
        if [[ "${servers_running}" -gt 0 ]]; then
            status_ok "Cluster '${CLUSTER_NAME}' is running"
            return 0
        else
            status_warn "Cluster '${CLUSTER_NAME}' exists but not running"
            return 1
        fi
    else
        status_fail "Cluster '${CLUSTER_NAME}' not found"
        return 1
    fi
}

# Check component status by deployment
check_component() {
    local name="$1"
    local namespace="$2"
    local deployment="$3"

    echo -e "${BOLD}${name}${NC}"

    if ! kubectl get namespace "${namespace}" >/dev/null 2>&1; then
        status_fail "${name} namespace not found"
        return 1
    fi

    if ! kubectl get deployment "${deployment}" -n "${namespace}" >/dev/null 2>&1; then
        status_fail "${name} deployment not found"
        return 1
    fi

    local available
    available=$(kubectl get deployment "${deployment}" -n "${namespace}" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo "0")
    if [[ -n "${available}" && "${available}" -gt 0 ]]; then
        status_ok "${name} is running (${available} replica(s))"
        return 0
    else
        status_warn "${name} deployment exists but no replicas available"
        return 1
    fi
}

# Check Loki (uses StatefulSet, not Deployment)
check_loki() {
    local name="Loki"
    local namespace="observability"

    echo -e "${BOLD}${name}${NC}"

    if ! kubectl get namespace "${namespace}" >/dev/null 2>&1; then
        status_fail "${name} namespace not found"
        return 1
    fi

    # Loki can be either a deployment or statefulset depending on version
    if kubectl get pods -n "${namespace}" -l app=loki,release=loki -o name 2>/dev/null | grep -q .; then
        local ready_pods
        ready_pods=$(kubectl get pods -n "${namespace}" -l app=loki,release=loki -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | tr ' ' '\n' | grep -c True || echo "0")
        if [[ "${ready_pods}" -gt 0 ]]; then
            status_ok "Loki is running (${ready_pods} pod(s) ready)"
            return 0
        else
            status_warn "Loki pods exist but not ready"
            return 1
        fi
    else
        status_fail "Loki pods not found"
        return 1
    fi
}

# Check Promtail (DaemonSet)
check_promtail() {
    local name="Promtail"
    local namespace="observability"

    echo -e "${BOLD}${name}${NC}"

    if ! kubectl get namespace "${namespace}" >/dev/null 2>&1; then
        status_fail "${name} namespace not found"
        return 1
    fi

    if kubectl get daemonset -n "${namespace}" -l app.kubernetes.io/name=promtail -o name 2>/dev/null | grep -q .; then
        local desired
        local ready
        desired=$(kubectl get daemonset -n "${namespace}" -l app.kubernetes.io/name=promtail -o jsonpath='{.items[0].status.desiredNumberScheduled}' 2>/dev/null || echo "0")
        ready=$(kubectl get daemonset -n "${namespace}" -l app.kubernetes.io/name=promtail -o jsonpath='{.items[0].status.numberReady}' 2>/dev/null || echo "0")
        if [[ "${ready}" -gt 0 ]]; then
            status_ok "Promtail is running (${ready}/${desired} pods ready)"
            return 0
        else
            status_warn "Promtail DaemonSet exists but no pods ready"
            return 1
        fi
    else
        status_fail "Promtail DaemonSet not found"
        return 1
    fi
}

# Print URL access status
check_urls() {
    echo -e "${BOLD}URL Accessibility${NC}"

    # Check Grafana
    if curl -sk --connect-timeout 2 https://grafana.localhost:8443/api/health >/dev/null 2>&1; then
        status_ok "Grafana: https://grafana.localhost:8443"
    else
        status_warn "Grafana: https://grafana.localhost:8443 (not responding)"
    fi

    # Check Prometheus
    if curl -sk --connect-timeout 2 https://prometheus.localhost:8443/-/healthy >/dev/null 2>&1; then
        status_ok "Prometheus: https://prometheus.localhost:8443"
    else
        status_warn "Prometheus: https://prometheus.localhost:8443 (not responding)"
    fi
}

main() {
    echo ""
    echo -e "${BOLD}Stack Status${NC}"
    echo "============"
    echo ""

    setup_kubeconfig

    local overall_status=0

    check_cluster || overall_status=1
    echo ""

    # Only check other components if cluster is accessible
    if ! kubectl cluster-info >/dev/null 2>&1; then
        echo -e "${RED}Cannot connect to cluster. Is it running?${NC}"
        echo ""
        echo "Start the stack with: make stack-up"
        exit 1
    fi

    check_component "Istio Control Plane" "istio-system" "istiod" || overall_status=1
    echo ""
    check_component "Istio Gateway" "istio-ingress" "istio-ingress" || overall_status=1
    echo ""
    check_component "cert-manager" "cert-manager" "cert-manager" || overall_status=1
    echo ""
    check_component "Prometheus Operator" "observability" "prometheus-kube-prometheus-operator" || overall_status=1
    echo ""
    check_component "Grafana" "observability" "prometheus-grafana" || overall_status=1
    echo ""
    check_loki || overall_status=1
    echo ""
    check_promtail || overall_status=1
    echo ""
    check_urls
    echo ""

    if [[ ${overall_status} -eq 0 ]]; then
        echo -e "${GREEN}${BOLD}All components healthy${NC}"
    else
        echo -e "${YELLOW}${BOLD}Some components need attention${NC}"
    fi
    echo ""

    echo -e "${BOLD}Set kubectl context:${NC}"
    echo "  export KUBECONFIG=\$(k3d kubeconfig write ${CLUSTER_NAME})"
    echo ""

    exit ${overall_status}
}

main "$@"
