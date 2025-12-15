#!/usr/bin/env bash
# stack-up.sh - Deploy complete infrastructure stack via ArgoCD GitOps (idempotent)
# Deploys: cluster -> ArgoCD -> root app -> waits for sync waves
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
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

# Wait for a namespace's pods to be ready
wait_for_namespace() {
    local namespace="$1"
    local timeout="${2:-180}"
    local label="${3:-}"

    if [ -n "$label" ]; then
        kubectl wait --for=condition=Ready pods -l "$label" -n "$namespace" --timeout="${timeout}s" 2>/dev/null || true
    else
        kubectl wait --for=condition=Ready pods --all -n "$namespace" --timeout="${timeout}s" 2>/dev/null || true
    fi
}

# Print URL summary
print_urls() {
    echo ""
    echo -e "${GREEN}${BOLD}=========================================="
    echo "  Stack Deployment Complete!"
    echo "==========================================${NC}"
    echo ""
    echo -e "${BOLD}GitOps Management:${NC}"
    echo "  ArgoCD UI:  https://argocd.localhost:8443"
    echo "              Username: admin"
    echo "              Password: (run 'make argocd-status' for password)"
    echo ""
    echo -e "${BOLD}Observability:${NC}"
    echo "  Grafana:    https://grafana.localhost:8443"
    echo "              Username: admin / Password: admin"
    echo "  Prometheus: https://prometheus.localhost:8443"
    echo "  Jaeger:     https://jaeger.localhost:8443"
    echo ""
    echo -e "${BOLD}Storage:${NC}"
    echo "  Minio:      https://minio.localhost:8443"
    echo "              Username: minioadmin / Password: minioadmin123"
    echo ""
    echo -e "${BOLD}Home Automation:${NC}"
    echo "  HomeAssistant:  https://homeassistant.localhost:8443"
    echo "  Zigbee2MQTT:    https://zigbee2mqtt.localhost:8443"
    echo "  Homebridge:     https://homebridge.localhost:8443"
    echo ""
    echo -e "${BOLD}Sample Apps:${NC}"
    echo "  httpbin:    https://httpbin.localhost:8443"
    echo ""
}

# Print kubeconfig instructions
print_kubeconfig() {
    echo -e "${BOLD}Set kubectl context:${NC}"
    echo "  export KUBECONFIG=\$(k3d kubeconfig write ${CLUSTER_NAME})"
    echo ""
}

# Print useful commands
print_next_steps() {
    echo -e "${BOLD}Useful commands:${NC}"
    echo "  make argocd-status  # View ArgoCD applications and password"
    echo "  make stack-status   # Check overall stack health"
    echo "  make stack-down     # Tear down entire stack"
    echo ""
}

main() {
    echo ""
    echo -e "${BOLD}Deploying Infrastructure Stack via ArgoCD GitOps${NC}"
    echo "================================================="
    echo ""
    echo "Deployment steps:"
    echo "  1. Create k3d cluster"
    echo "  2. Bootstrap ArgoCD"
    echo "  3. Apply root application (app-of-apps)"
    echo "  4. Wait for sync waves to complete"
    echo ""

    local start_time
    start_time=$(date +%s)

    # Step 1: Create k3d cluster
    log_step "Creating k3d cluster..."
    if "${SCRIPT_DIR}/cluster-up.sh"; then
        DEPLOYED_COMPONENTS+=("k3d cluster")
        log_info "Cluster created"
    else
        log_error "Failed to create cluster"
        exit 1
    fi
    echo ""

    # Step 2: Bootstrap ArgoCD
    log_step "Bootstrapping ArgoCD..."
    if "${SCRIPT_DIR}/argocd-up.sh"; then
        DEPLOYED_COMPONENTS+=("ArgoCD")
        log_info "ArgoCD bootstrapped"
    else
        log_error "Failed to bootstrap ArgoCD"
        exit 1
    fi
    echo ""

    # Step 3: Apply root application
    log_step "Applying root application (app-of-apps)..."
    if kubectl apply -f "${REPO_ROOT}/argocd/applications/root-app.yaml"; then
        DEPLOYED_COMPONENTS+=("Root application")
        log_info "Root application applied"
    else
        log_error "Failed to apply root application"
        exit 1
    fi
    echo ""

    # Step 4: Wait for sync waves
    log_step "Waiting for ArgoCD to sync applications..."
    echo "  Sync waves will deploy in order:"
    echo "    Wave 0:  Istio CRDs"
    echo "    Wave 1:  Istiod control plane"
    echo "    Wave 2:  cert-manager"
    echo "    Wave 4:  Istio Gateway, Ingress"
    echo "    Wave 5:  Minio"
    echo "    Wave 10: Prometheus/Grafana, Loki"
    echo "    Wave 11: Tracing (Jaeger, Tempo, OTel)"
    echo "    Wave 12: Velero"
    echo "    Wave 20: Home Automation, Sample Apps"
    echo ""

    # Wait for critical platform components
    log_info "Waiting for platform layer (waves 0-5)..."

    # Wait for Istio CRDs
    log_info "  Waiting for Istio CRDs..."
    timeout 180 bash -c 'until kubectl get crd gateways.networking.istio.io 2>/dev/null; do sleep 5; done' || true

    # Wait for Istiod
    log_info "  Waiting for Istiod..."
    wait_for_namespace "istio-system" 180 "app=istiod"

    # Wait for cert-manager
    log_info "  Waiting for cert-manager..."
    wait_for_namespace "cert-manager" 180

    # Wait for Istio ingress
    log_info "  Waiting for Istio gateway..."
    wait_for_namespace "istio-ingress" 120

    # Wait for Minio
    log_info "  Waiting for Minio..."
    wait_for_namespace "minio" 180 "release=minio"

    DEPLOYED_COMPONENTS+=("Platform layer")
    echo ""

    # Wait for observability
    log_info "Waiting for observability layer (waves 10-12)..."

    log_info "  Waiting for Prometheus..."
    wait_for_namespace "observability" 180 "app.kubernetes.io/name=prometheus"

    log_info "  Waiting for Grafana..."
    wait_for_namespace "observability" 180 "app.kubernetes.io/name=grafana"

    DEPLOYED_COMPONENTS+=("Observability layer")
    echo ""

    # Wait for workloads
    log_info "Waiting for workloads layer (wave 20)..."

    log_info "  Waiting for Home Automation..."
    wait_for_namespace "home-automation" 180 "app.kubernetes.io/name=mosquitto"

    log_info "  Waiting for sample app..."
    wait_for_namespace "ingress-sample" 120 "app=httpbin"

    DEPLOYED_COMPONENTS+=("Workloads layer")
    echo ""

    # Show ArgoCD application status
    log_step "ArgoCD Application Status:"
    kubectl get applications -n argocd 2>/dev/null || echo "  (applications still syncing)"
    echo ""

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
