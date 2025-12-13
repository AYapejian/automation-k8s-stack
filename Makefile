.PHONY: help cluster-up cluster-down cluster-status istio-up istio-down istio-status cert-manager-up cert-manager-down cert-manager-status ingress-up ingress-down ingress-status sample-app-up sample-app-down sample-app-status storage-test storage-test-down storage-status test lint clean

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

cert-manager-up: ## Install cert-manager for TLS certificates (idempotent)
	@$(SCRIPTS_DIR)/cert-manager-up.sh

cert-manager-down: ## Uninstall cert-manager (idempotent)
	@$(SCRIPTS_DIR)/cert-manager-down.sh --force

cert-manager-status: ## Show cert-manager status
	@echo "Checking cert-manager status..."
	@echo ""
	@echo "Helm release:"
	@helm list -n cert-manager 2>/dev/null || echo "  (not installed)"
	@echo ""
	@echo "cert-manager pods:"
	@kubectl get pods -n cert-manager 2>/dev/null || echo "  cert-manager namespace not found"
	@echo ""
	@echo "ClusterIssuers:"
	@kubectl get clusterissuers 2>/dev/null || echo "  (none)"
	@echo ""
	@echo "Certificates:"
	@kubectl get certificates -A 2>/dev/null || echo "  (none)"

ingress-up: ## Configure Gateway and TLS certificates (requires cert-manager)
	@$(SCRIPTS_DIR)/ingress-up.sh

ingress-down: ## Remove Gateway and TLS certificates (idempotent)
	@$(SCRIPTS_DIR)/ingress-down.sh --force

ingress-status: ## Show Gateway and certificate status
	@echo "Checking ingress configuration..."
	@echo ""
	@echo "Gateway:"
	@kubectl get gateway -n istio-ingress 2>/dev/null || echo "  (none)"
	@echo ""
	@echo "VirtualServices:"
	@kubectl get virtualservices -A 2>/dev/null || echo "  (none)"
	@echo ""
	@echo "Gateway Certificate:"
	@kubectl get certificate -n istio-ingress 2>/dev/null || echo "  (none)"

##@ Sample Applications

sample-app-up: ## Deploy sample httpbin app (requires ingress)
	@$(SCRIPTS_DIR)/sample-app-up.sh

sample-app-down: ## Remove sample httpbin app (idempotent)
	@$(SCRIPTS_DIR)/sample-app-down.sh --force

sample-app-status: ## Show sample app status
	@echo "Checking sample app..."
	@echo ""
	@echo "Pods:"
	@kubectl get pods -n ingress-sample 2>/dev/null || echo "  ingress-sample namespace not found"
	@echo ""
	@echo "Services:"
	@kubectl get services -n ingress-sample 2>/dev/null || echo "  (none)"
	@echo ""
	@echo "VirtualServices:"
	@kubectl get virtualservices -n ingress-sample 2>/dev/null || echo "  (none)"

##@ Storage

storage-test: ## Run storage provisioning test (creates PVC, writes data)
	@$(SCRIPTS_DIR)/storage-test-up.sh

storage-test-down: ## Clean up storage test resources
	@$(SCRIPTS_DIR)/storage-test-down.sh

storage-status: ## Show StorageClasses and PVCs
	@echo "Checking storage configuration..."
	@echo ""
	@echo "StorageClasses:"
	@kubectl get storageclass 2>/dev/null || echo "  Cannot connect to cluster"
	@echo ""
	@echo "PersistentVolumeClaims (all namespaces):"
	@kubectl get pvc -A 2>/dev/null || echo "  (none)"
	@echo ""
	@echo "PersistentVolumes:"
	@kubectl get pv 2>/dev/null || echo "  (none)"

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
