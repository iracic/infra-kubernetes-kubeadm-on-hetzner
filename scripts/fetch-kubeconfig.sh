#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
KUBECONFIG_FILE="${PROJECT_DIR}/kubeconfig.yaml"
TERRAFORM_DIR="${PROJECT_DIR}/terraform"

# Get control plane IP from terraform
CP_IP=$(cd "$TERRAFORM_DIR" && terraform output -raw control_plane_ip)
LB_IP=$(cd "$TERRAFORM_DIR" && terraform output -raw load_balancer_ip)

echo "Fetching kubeconfig from control plane ($CP_IP)..."

scp -o StrictHostKeyChecking=no "root@${CP_IP}:/etc/kubernetes/admin.conf" "$KUBECONFIG_FILE"

# Replace the internal API server address with the load balancer IP
sed -i "s|server: https://.*:6443|server: https://${LB_IP}:6443|" "$KUBECONFIG_FILE"

echo "Kubeconfig saved to: $KUBECONFIG_FILE"
echo ""
echo "Usage:"
echo "  export KUBECONFIG=${KUBECONFIG_FILE}"
echo "  kubectl get nodes"
