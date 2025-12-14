#!/usr/bin/env bash
# stack-down.sh - Tear down complete infrastructure stack (idempotent)
# Teardown order (reverse of deployment): loki -> prometheus-grafana -> ingress -> cert-manager -> istio -> cluster
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

# Parse arguments
FORCE=false
KEEP_CLUSTER=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --force|-f)
            FORCE=true
            shift
            ;;
        --keep-cluster)
            KEEP_CLUSTER=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [--force] [--keep-cluster]"
            echo ""
            echo "Tear down the complete infrastructure stack."
            echo ""
            echo "Options:"
            echo "  --force, -f     Skip confirmation prompt"
            echo "  --keep-cluster  Keep the k3d cluster (tear down only apps/platform)"
            echo "  -h, --help      Show this help message"
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Teardown order (reverse of deployment)
# Note: All down scripts accept --force flag
# Format: "script-name:description"
COMPONENTS=(
    "sample-app-down:Removing sample application (if exists)"
    "velero-down:Uninstalling Velero backup system"
    "tracing-down:Uninstalling distributed tracing"
    "loki-down:Uninstalling Loki + Promtail"
    "prometheus-grafana-down:Uninstalling Prometheus + Grafana"
    "minio-down:Uninstalling Minio object storage"
    "ingress-down:Removing Istio Gateway configuration"
    "cert-manager-down:Uninstalling cert-manager"
    "istio-down:Uninstalling Istio"
)

# Tear down a single component
teardown_component() {
    local script_name="$1"
    local description="$2"
    local script_path="${SCRIPT_DIR}/${script_name}.sh"

    if [[ ! -x "${script_path}" ]]; then
        log_warn "Script not found: ${script_path}, skipping..."
        return 0
    fi

    log_step "${description}..."

    # All down scripts support --force to skip confirmation
    if "${script_path}" --force; then
        log_info "${description} - complete"
        echo ""
        return 0
    else
        log_warn "${description} - may have had issues, continuing..."
        echo ""
        return 0  # Continue teardown even if one component fails
    fi
}

main() {
    echo ""
    echo -e "${BOLD}Tearing Down Infrastructure Stack${NC}"
    echo "==================================="
    echo ""

    if [[ "${FORCE}" != "true" ]]; then
        log_warn "This will tear down the entire infrastructure stack."
        log_warn "All data (metrics, logs) will be lost."
        echo ""
        read -p "Continue? [y/N] " -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Aborted."
            exit 0
        fi
    fi

    local start_time
    start_time=$(date +%s)

    # Tear down components in reverse order
    for component_entry in "${COMPONENTS[@]}"; do
        local script_name="${component_entry%%:*}"
        local description="${component_entry#*:}"
        teardown_component "${script_name}" "${description}"
    done

    # Handle cluster separately
    if [[ "${KEEP_CLUSTER}" == "true" ]]; then
        log_info "Keeping cluster (--keep-cluster flag set)"
    else
        log_step "Destroying k3d cluster..."
        if "${SCRIPT_DIR}/cluster-down.sh"; then
            log_info "Cluster destroyed"
        else
            log_warn "Cluster teardown may have had issues"
        fi
    fi

    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))

    echo ""
    echo -e "${GREEN}${BOLD}=========================================="
    echo "  Stack Teardown Complete!"
    echo "==========================================${NC}"
    echo ""
    log_info "Total teardown time: ${duration}s"
}

main "$@"
