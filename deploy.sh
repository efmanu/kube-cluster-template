#!/usr/bin/env bash
#
# deploy.sh — set up kubectl on this Mac and deploy the full demo stack in one command.
#
# Prerequisites:
#   1. The servers already exist and k3s is installed on them. Run this first:
#        (cd terraform && terraform init && terraform apply)
#      The terraform cloud-init installs k3s automatically on first boot.
#   2. `sshpass` is needed to copy the kubeconfig over password SSH. One-time install:
#        brew install hudochenkov/sshpass/sshpass
#      (Without sshpass the script prints the manual scp command and stops.)
#
# Re-run this script any time you change the CONFIG below (new server IP/password).
# It is idempotent: applying the manifests again just reconciles to the same state.

set -euo pipefail

# =============================================================================
# CONFIG — change these when your servers change
# =============================================================================
MASTER_IP="66.226.150.44"                          # control-plane public IP
SSH_USER="root"                                    # SSH user (BinaryLane default: root)
SSH_PASSWORD="replace-with-a-strong-password"      # root password (used for scp)
KUBECONFIG="$HOME/.kube/k3s.yaml"                  # where to store the cluster config
NAMESPACE="dev"                                    # namespace the stack lives in
NODE_PORT="30080"                                  # NodePort the frontend listens on
MANIFESTS_DIR="$(cd "$(dirname "$0")/manifests" && pwd)"

# =============================================================================
# 1. Ensure kubectl is installed
# =============================================================================
if ! command -v kubectl >/dev/null 2>&1; then
  echo "==> kubectl not found — installing via Homebrew..."
  brew install kubectl
fi
echo "==> kubectl $(kubectl version --client -o json 2>/dev/null | sed -n 's/.*"gitVersion": "\([^"]*\)".*/\1/p' || echo installed)"

# =============================================================================
# 2. Fetch the kubeconfig from the control plane
# =============================================================================
mkdir -p "$(dirname "$KUBECONFIG")"

if ! command -v sshpass >/dev/null 2>&1; then
  echo "ERROR: sshpass is required to copy the kubeconfig over password SSH."
  echo "Install it once with:  brew install hudochenkov/sshpass/sshpass"
  echo "Then copy manually:"
  echo "  scp $SSH_USER@$MASTER_IP:/etc/rancher/k3s/k3s.yaml $KUBECONFIG"
  exit 1
fi

# k3s finishes installing ~60–90s after the server boots, so retry for up to ~2.5 min.
echo "==> Fetching kubeconfig from $MASTER_IP (retrying while k3s finishes installing)..."
for attempt in $(seq 1 15); do
  if sshpass -p "$SSH_PASSWORD" scp -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
       "$SSH_USER@$MASTER_IP:/etc/rancher/k3s/k3s.yaml" "$KUBECONFIG" 2>/dev/null; then
    echo "==> kubeconfig copied."
    break
  fi
  [ "$attempt" -eq 15 ] && { echo "ERROR: could not copy kubeconfig after 15 attempts."; exit 1; }
  echo "    k3s not ready yet (attempt $attempt/15) — waiting 10s..."
  sleep 10
done

# =============================================================================
# 3. Point the kubeconfig at the public IP (k3s writes 127.0.0.1 by default)
# =============================================================================
sed -i '' "s/127.0.0.1/$MASTER_IP/g" "$KUBECONFIG"
export KUBECONFIG="$KUBECONFIG"

echo "==> Cluster nodes:"
kubectl get nodes

# =============================================================================
# 4. Deploy the stack (order matters: namespace first, deps before consumers)
# =============================================================================
echo "==> Applying manifests (namespace: $NAMESPACE)..."

kubectl apply -f "$MANIFESTS_DIR/00-namespace.yaml"
kubectl apply -f "$MANIFESTS_DIR/01-secret.yaml" -f "$MANIFESTS_DIR/02-configmap.yaml"
kubectl apply -f "$MANIFESTS_DIR/10-postgres-pvc.yaml" -f "$MANIFESTS_DIR/11-postgres.yaml"
kubectl apply -f "$MANIFESTS_DIR/12-api.yaml"
kubectl apply -f "$MANIFESTS_DIR/13-nginx-config.yaml" -f "$MANIFESTS_DIR/14-frontend.yaml"

# =============================================================================
# 5. Wait for all pods to be Ready
# =============================================================================
for app in postgres api frontend; do
  echo "==> Waiting for $app pods to be Ready..."
  kubectl -n "$NAMESPACE" wait --for=condition=Ready pod -l "app=$app" --timeout=300s
done

# =============================================================================
# 6. Show the result
# =============================================================================
echo
kubectl -n "$NAMESPACE" get all
echo
echo "Done! The full chain is up. Test it with:"
echo "  curl http://$MASTER_IP:$NODE_PORT/"
