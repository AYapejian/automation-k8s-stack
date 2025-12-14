# =============================================================================
# Devcontainer Dockerfile for automation-k8s-stack
# =============================================================================
# This Dockerfile creates a development environment with all tools needed for
# Kubernetes development with k3d, plus Claude Code for AI-assisted development.
#
# TEMPLATING NOTES (for future extraction to reusable template):
# - Base image: Standard devcontainer base, keep as-is
# - Tool versions: Extract to ARGs for easy customization
# - Helm repos: Project-specific, move to post-create.sh for templates
# - Claude Code: Core requirement, keep in base image
# =============================================================================

FROM mcr.microsoft.com/devcontainers/base:ubuntu-22.04

# Tool versions - adjust these for your project needs
# TEMPLATE: Extract these to devcontainer.json build.args for customization
ARG KUBECTL_VERSION="1.31"
ARG NODE_VERSION="20"
ARG DEBIAN_FRONTEND=noninteractive

# Metadata
LABEL maintainer="automation-k8s-stack"
LABEL description="Development container for k3d-based Kubernetes automation with Claude Code"

# =============================================================================
# System Dependencies
# =============================================================================
RUN apt-get update && apt-get install -y --no-install-recommends \
    # Core utilities
    curl \
    wget \
    git \
    ca-certificates \
    gnupg \
    lsb-release \
    # JSON/YAML processing
    jq \
    # Network utilities (for debugging)
    dnsutils \
    iputils-ping \
    netcat-openbsd \
    # Build essentials (for native npm modules)
    build-essential \
    python3 \
    && rm -rf /var/lib/apt/lists/*

# =============================================================================
# kubectl
# =============================================================================
# TEMPLATE: Version configurable via ARG
RUN curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${KUBECTL_VERSION}/deb/Release.key" | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg \
    && echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${KUBECTL_VERSION}/deb/ /" > /etc/apt/sources.list.d/kubernetes.list \
    && apt-get update && apt-get install -y kubectl \
    && rm -rf /var/lib/apt/lists/*

# =============================================================================
# k3d (Kubernetes in Docker)
# =============================================================================
# Always installs latest - k3d is backwards compatible
RUN curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash

# =============================================================================
# Helm
# =============================================================================
# Installs latest Helm 3.x
RUN curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# =============================================================================
# yq (YAML processor, complements jq)
# =============================================================================
RUN wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 \
    && chmod +x /usr/local/bin/yq

# =============================================================================
# Node.js (required for Claude Code)
# =============================================================================
RUN curl -fsSL https://deb.nodesource.com/setup_${NODE_VERSION}.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# =============================================================================
# Claude Code CLI
# =============================================================================
# Install globally for all users
RUN npm install -g @anthropic-ai/claude-code

# =============================================================================
# GitHub CLI (for PR/issue workflows)
# =============================================================================
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y gh \
    && rm -rf /var/lib/apt/lists/*

# =============================================================================
# User Setup
# =============================================================================
# Switch to vscode user (created by base image)
USER vscode
WORKDIR /workspaces/automation-k8s-stack

# =============================================================================
# Helm Repository Configuration
# =============================================================================
# TEMPLATE: These are project-specific. For a reusable template, move to post-create.sh
# and make configurable via environment variables or a config file.
RUN helm repo add istio https://istio-release.storage.googleapis.com/charts 2>/dev/null || true \
    && helm repo add jetstack https://charts.jetstack.io 2>/dev/null || true \
    && helm repo add grafana https://grafana.github.io/helm-charts 2>/dev/null || true \
    && helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true \
    && helm repo update 2>/dev/null || true

# =============================================================================
# Verification (build-time sanity check)
# =============================================================================
RUN echo "=== Tool Versions ===" \
    && kubectl version --client --output=yaml | head -5 \
    && k3d version \
    && helm version --short \
    && node --version \
    && claude --version 2>/dev/null || echo "Claude Code installed" \
    && gh --version | head -1 \
    && echo "=== Build Complete ==="
