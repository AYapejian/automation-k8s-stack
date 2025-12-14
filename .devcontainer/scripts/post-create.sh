#!/usr/bin/env bash
# =============================================================================
# post-create.sh - One-time setup after container creation
# =============================================================================
# This script runs once when the devcontainer is first created.
# It sets up shell completions, directories, and prints quick-start info.
#
# TEMPLATING NOTES:
# - Shell completions: Keep as-is (common tools)
# - Quick-start message: Customize per project
# - Directory setup: Keep as-is (standard paths)
# =============================================================================

set -euo pipefail

echo "=============================================="
echo "  automation-k8s-stack: Post-Create Setup"
echo "=============================================="

# =============================================================================
# Directory Setup
# =============================================================================
echo "[INFO] Setting up directories..."

# Ensure .kube directory exists with correct permissions
mkdir -p ~/.kube
chmod 700 ~/.kube

# Ensure .claude directory exists with correct permissions
mkdir -p ~/.claude
chmod 700 ~/.claude

# Create bash history directory (for persistent history volume)
mkdir -p ~/.bash_history_dir
touch ~/.bash_history_dir/.bash_history

# =============================================================================
# Shell Completions
# =============================================================================
echo "[INFO] Configuring shell completions..."

# Add to .bashrc if not already present
BASHRC_ADDITIONS='
# === Devcontainer Shell Customizations ===

# Persistent bash history (mounted volume)
export HISTFILE=~/.bash_history_dir/.bash_history
export HISTSIZE=10000
export HISTFILESIZE=20000

# kubectl completion and alias
source <(kubectl completion bash)
alias k=kubectl
complete -o default -F __start_kubectl k

# helm completion
source <(helm completion bash)

# k3d completion
source <(k3d completion bash)

# Useful aliases
alias ll="ls -la"
alias kgp="kubectl get pods"
alias kga="kubectl get all"
alias kgn="kubectl get nodes"

# Show git branch in prompt
parse_git_branch() {
    git branch 2>/dev/null | sed -e "/^[^*]/d" -e "s/* \(.*\)/ (\1)/"
}
export PS1="\[\033[01;32m\]\u@devcontainer\[\033[00m\]:\[\033[01;34m\]\w\[\033[33m\]\$(parse_git_branch)\[\033[00m\]\$ "
'

# Only add if marker not present
if ! grep -q "Devcontainer Shell Customizations" ~/.bashrc 2>/dev/null; then
    echo "$BASHRC_ADDITIONS" >> ~/.bashrc
    echo "[INFO] Added shell customizations to .bashrc"
else
    echo "[INFO] Shell customizations already present in .bashrc"
fi

# =============================================================================
# Verify Tools
# =============================================================================
echo ""
echo "[INFO] Verifying installed tools..."
echo "  kubectl: $(kubectl version --client --short 2>/dev/null || kubectl version --client -o yaml | grep gitVersion | head -1)"
echo "  k3d:     $(k3d version | head -1)"
echo "  helm:    $(helm version --short)"
echo "  node:    $(node --version)"
echo "  claude:  $(claude --version 2>/dev/null || echo 'installed')"
echo "  gh:      $(gh --version | head -1)"

# =============================================================================
# Quick Start Guide
# =============================================================================
echo ""
echo "=============================================="
echo "  Setup Complete!"
echo "=============================================="
echo ""
echo "Quick Start:"
echo "  make cluster-up       # Create k3d cluster"
echo "  make stack-up         # Deploy full stack (Istio, observability, etc.)"
echo "  make stack-status     # Check health of all components"
echo ""
echo "Claude Code (with unsafe permissions - safe in container):"
echo "  claude --dangerously-skip-permissions"
echo ""
echo "Useful Commands:"
echo "  eval \$(make kubeconfig)  # Set kubectl context"
echo "  k get pods -A            # View all pods"
echo "  make help                # Show all make targets"
echo ""
echo "Access Points (after stack-up):"
echo "  Grafana:    https://grafana.localhost:8443 (admin/admin)"
echo "  Prometheus: https://prometheus.localhost:8443"
echo "  Registry:   registry.localhost:5111"
echo ""

# =============================================================================
# Claude Authentication Check
# =============================================================================
if [ -f ~/.claude/.credentials.json ]; then
    echo "Claude Code: Authenticated (credentials shared from host)"
else
    echo "NOTE: Claude Code not authenticated."
    echo "      Run 'claude login' on your HOST machine, then rebuild container."
    echo "      Your ~/.claude directory is bind-mounted for credential sharing."
    echo ""
fi
