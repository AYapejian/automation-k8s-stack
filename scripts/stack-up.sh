#!/usr/bin/env bash
# stack-up.sh - Deploy complete infrastructure stack (idempotent)
# Deploys: cluster -> istio -> cert-manager -> ingress -> prometheus-grafana -> loki
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
log_step() { echo -e "${BLUE}[STEP]${NC} ${BOLD}$*${NC}"; }

# Track deployment progress for error reporting
DEPLOYED_COMPONENTS=()

# On failure, show what was deployed
cleanup_on_failure() {
    local exit_code=$?
    if [[ ${exit_code} -ne 0 && ${#DEPLOYED_COMPONENTS[@]} -gt 0 ]]; then
        echo ""
        log_error "Deployment failed. Successfully deployed components:"
        for component in "${DEPLOYED_COMPONENTS[@]}"; do
            echo "  - ${component}"
        done
        echo ""
        log_error "Fix the issue and re-run 'make stack-up' (idempotent)"
        log_error "Or run 'make stack-down' to clean up"
    fi
}

trap cleanup_on_failure EXIT

# Define deployment order
# Each script already has built-in dependency checks and is idempotent
# Format: "script-name:description"
COMPONENTS=(
    "cluster-up:Creating k3d cluster"
    "istio-up:Installing Istio service mesh"
    "cert-manager-up:Installing cert-manager"
    "ingress-up:Configuring Istio Gateway and TLS"
    "minio-up:Installing Minio object storage"
    "prometheus-grafana-up:Installing Prometheus + Grafana"
    "loki-up:Installing Loki + Promtail"
    "tracing-up:Installing distributed tracing"
    "velero-up:Installing Velero backup system"
)

# Deploy a single component
deploy_component() {
    local script_name="$1"
    local description="$2"
    local script_path="${SCRIPT_DIR}/${script_name}.sh"

    if [[ ! -x "${script_path}" ]]; then
        log_error "Script not found or not executable: ${script_path}"
        return 1
    fi

    log_step "${description}..."

    if "${script_path}"; then
        DEPLOYED_COMPONENTS+=("${description}")
        log_info "${description} - complete"
        echo ""
        return 0
    else
        log_error "${description} - FAILED"
        return 1
    fi
}

# Print URL summary
print_urls() {
    echo ""
    echo -e "${GREEN}${BOLD}=========================================="
    echo "  Stack Deployment Complete!"
    echo "==========================================${NC}"
    echo ""
    echo -e "${BOLD}Access URLs:${NC}"
    echo "  Grafana:    https://grafana.localhost:8443"
    echo "              Username: admin"
    echo "              Password: admin"
    echo ""
    echo "  Prometheus: https://prometheus.localhost:8443"
    echo "  Jaeger:     https://jaeger.localhost:8443"
    echo "  Minio:      https://minio.localhost:8443"
    echo "              Username: minioadmin"
    echo "              Password: minioadmin123"
    echo ""
    echo -e "${BOLD}Grafana Features:${NC}"
    echo "  - Explore -> Prometheus: Query metrics"
    echo "  - Explore -> Loki: Query logs"
    echo "  - Explore -> Tempo: Query traces"
    echo "  - Dashboards: Pre-configured Kubernetes dashboards"
    echo ""
}

# Print kubeconfig instructions
print_kubeconfig() {
    echo -e "${BOLD}Set kubectl context:${NC}"
    echo "  export KUBECONFIG=\$(k3d kubeconfig write ${CLUSTER_NAME})"
    echo ""
}

# Print optional next steps
print_next_steps() {
    echo -e "${BOLD}Optional: Deploy sample application${NC}"
    echo "  make sample-app-up                           # Deploy httpbin"
    echo "  curl -k https://httpbin.localhost:8443/get   # Test connectivity"
    echo ""
    echo -e "${BOLD}Useful commands:${NC}"
    echo "  make stack-status   # Check overall stack health"
    echo "  make stack-down     # Tear down entire stack"
    echo ""
}

main() {
    echo ""
    echo -e "${BOLD}Deploying Infrastructure Stack${NC}"
    echo "==============================="
    echo ""
    echo "Components to deploy:"
    for component_entry in "${COMPONENTS[@]}"; do
        local description="${component_entry#*:}"
        echo "  - ${description}"
    done
    echo ""

    local start_time
    start_time=$(date +%s)

    # Deploy each component in order
    # set -e ensures we stop on first failure
    for component_entry in "${COMPONENTS[@]}"; do
        local script_name="${component_entry%%:*}"
        local description="${component_entry#*:}"
        deploy_component "${script_name}" "${description}"
    done

    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))
    local minutes=$((duration / 60))
    local seconds=$((duration % 60))

    print_urls
    print_kubeconfig
    print_next_steps

    log_info "Total deployment time: ${minutes}m ${seconds}s"
}

main "$@"
