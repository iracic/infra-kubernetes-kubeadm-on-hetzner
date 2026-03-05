#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
export KUBECONFIG="${PROJECT_DIR}/kubeconfig.yaml"

if [ ! -f "$KUBECONFIG" ]; then
  echo "ERROR: kubeconfig.yaml not found. Run 'make kubeconfig' first."
  exit 1
fi

echo "=== Cluster Smoke Test ==="
echo ""

echo "--- Nodes ---"
kubectl get nodes -o wide
echo ""

echo "--- System Pods ---"
kubectl get pods -n kube-system
echo ""

echo "--- Calico Status ---"
kubectl get pods -n kube-system -l k8s-app=calico-node -o wide
echo ""

# Check all nodes are Ready
NOT_READY=$(kubectl get nodes --no-headers | grep -v " Ready " || true)
if [ -n "$NOT_READY" ]; then
  echo "WARNING: Some nodes are not Ready:"
  echo "$NOT_READY"
  exit 1
fi

# Check system pods are running
FAILED_PODS=$(kubectl get pods -n kube-system --no-headers | grep -v "Running\|Completed" || true)
if [ -n "$FAILED_PODS" ]; then
  echo "WARNING: Some system pods are not running:"
  echo "$FAILED_PODS"
  exit 1
fi

echo "All checks passed."
