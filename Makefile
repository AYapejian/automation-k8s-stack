.PHONY: help cluster-up cluster-down test lint clean

# Default target
.DEFAULT_GOAL := help

##@ General

help: ## Show this help message
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

##@ Cluster Management

cluster-up: ## Create KIND cluster (idempotent)
	@echo "TODO: Implement in Phase 1.2"
	@exit 1

cluster-down: ## Destroy KIND cluster (idempotent)
	@echo "TODO: Implement in Phase 1.2"
	@exit 1

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
