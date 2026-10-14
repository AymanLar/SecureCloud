#!/usr/bin/env bash
# Create the local k3d cluster (if it does not exist yet) and wait for it.
# The abstract look on the result: a single-node k3s cluster with Traefik
# (ingress) and the local-path storage class (persistence) preinstalled.

set -euo pipefail
source "$(dirname "$0")/lib.sh"

require_cmd docker
require_cmd k3d
require_cmd kubectl

docker version >/dev/null 2>&1 || {
  echo "error: Docker daemon is not running (start Docker Desktop / the Docker service)" >&2
  exit 1
}

if k3d cluster list 2>/dev/null | grep -q "^${K3D_CLUSTER_NAME}[[:space:]]"; then
  echo "==> cluster '${K3D_CLUSTER_NAME}' already exists"
else
  echo "==> creating k3d cluster '${K3D_CLUSTER_NAME}'"
  k3d cluster create "${K3D_CLUSTER_NAME}" \
    --agents 0 \
    --port "${K3D_HTTP_PORT}:80@loadbalancer" \
    --port "${K3D_HTTPS_PORT}:443@loadbalancer" \
    --wait --timeout 300s
fi

echo "==> switching to context k3d-${K3D_CLUSTER_NAME}"
kubectl config use-context "k3d-${K3D_CLUSTER_NAME}" >/dev/null 2>&1 || true

echo "==> waiting for nodes to be Ready"
kubectl wait --for=condition=Ready node --all --timeout=180s

echo "==> cluster info"
kubectl cluster-info

echo
echo "app will be served at: $(app_url)  (after: make deploy)"
echo "https URL:             https://localhost:${K3D_HTTPS_PORT}  (untrusted cert)"