#!/usr/bin/env bash
#
# destroy.sh — tear down the cluster and unlink kubectl from this Mac.
#
# Does two things:
#   1. `terraform destroy` — deletes the 2 BinaryLane servers (and the k3s cluster on them).
#   2. Unlinks kubectl — removes the KUBECONFIG export from ~/.zshrc and deletes the kubeconfig.
#
# Set SKIP_TERRAFORM=1 to only unlink kubectl and keep the servers running.

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
KUBECONFIG="$HOME/.kube/k3s.yaml"

# =============================================================================
# 1. Destroy the servers (and everything on them)
# =============================================================================
if [ "${SKIP_TERRAFORM:-0}" != "1" ]; then
  echo "==> Destroying the servers with terraform..."

  TOKEN="$(grep '^BINARYLANE_API_TOKEN=' "$PROJECT_DIR/src/.env" | cut -d= -f2-)"
  if [ -z "$TOKEN" ]; then
    echo "ERROR: BINARYLANE_API_TOKEN not found in src/.env"
    exit 1
  fi
  export BINARYLANE_API_TOKEN="$TOKEN"

  (cd "$PROJECT_DIR/terraform" && terraform destroy)
else
  echo "==> SKIP_TERRAFORM=1 set — skipping terraform destroy."
fi

# =============================================================================
# 2. Unlink kubectl
# =============================================================================
echo "==> Unlinking kubectl..."

# Remove the KUBECONFIG export line from ~/.zshrc (if present)
if grep -q 'export KUBECONFIG=~/.kube/k3s.yaml' "$HOME/.zshrc" 2>/dev/null; then
  sed -i '' '/export KUBECONFIG=~\/\.kube\/k3s\.yaml/d' "$HOME/.zshrc"
  echo "    removed KUBECONFIG export from ~/.zshrc"
fi

# Delete the kubeconfig file
rm -f "$KUBECONFIG"
echo "    removed $KUBECONFIG"

# Clear it from the current shell session
unset KUBECONFIG

echo
echo "==> Done. Verify with:  kubectl get nodes   (should error: no configuration)"
