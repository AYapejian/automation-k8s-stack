.PHONY: help cluster-up cluster-down cluster-status istio-up istio-down istio-status test lint clean

# Default target
.DEFAULT_GOAL := help

# Directories
SCRIPTS_DIR := $(shell dirname $(realpath $(lastword $(MAKEFILE_LIST))))/scripts

##@ General

help: ## Show this help message
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

##@ Cluster Management

cluster-up: ## Create k3d cluster with local registry (idempotent)
	@$(SCRIPTS_DIR)/cluster-up.sh

cluster-down: ## Destroy k3d cluster and registry (idempotent)
	@$(SCRIPTS_DIR)/cluster-down.sh

cluster-status: ## Show cluster status
	@echo "Checking cluster status..."
	@k3d cluster list 2>/dev/null | grep -q "automation-k8s" && \
		echo "Cluster: automation-k8s" && \
		k3d cluster list 2>/dev/null | grep "automation-k8s" && \
		echo "" && \
		kubectl get nodes -o wide 2>/dev/null || \
		echo "Cluster: automation-k8s (not found)"
	@echo ""
	@k3d registry list 2>/dev/null | grep -q "registry.localhost" && \
		echo "Registry:" && \
		k3d registry list 2>/dev/null | grep "registry.localhost" || \
		echo "Registry: not running"

##@ Platform

istio-up: ## Install Istio service mesh (idempotent)
	@$(SCRIPTS_DIR)/istio-up.sh

istio-down: ## Uninstall Istio service mesh (idempotent)
	@$(SCRIPTS_DIR)/istio-down.sh --force

istio-status: ## Show Istio status
	@echo "Checking Istio status..."
	@echo ""
	@echo "Helm releases:"
	@helm list -n istio-system 2>/dev/null || echo "  (none)"
	@helm list -n istio-ingress 2>/dev/null || echo "  (none)"
	@echo ""
	@echo "Istio system pods:"
	@kubectl get pods -n istio-system 2>/dev/null || echo "  istio-system namespace not found"
	@echo ""
	@echo "Istio ingress pods:"
	@kubectl get pods -n istio-ingress 2>/dev/null || echo "  istio-ingress namespace not found"

##@ Testing

test: ## Run all tests
	@echo "TODO: Implement in Phase 1.3"
	@exit 1

lint: ## Run linting checks
	@echo "Checking YAML files..."
	@find . -name '*.yaml' -o -name '*.yml' | xargs -I {} echo "Found: {}"
	@echo "Lint check placeholder - will add yamllint in future"

##@ Cleanup

clean: ## Clean up generated files
	@echo "Cleaning up..."
	@rm -rf .tmp 2>/dev/null || true
	@echo "Done"
