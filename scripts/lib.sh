#!/usr/bin/env bash
# Shared configuration and helpers for the SecureCloud Phase 3 scripts.
# Source this from the other scripts; it does not run anything by itself.

set -euo pipefail

# --- cluster ---
K3D_CLUSTER_NAME="${K3D_CLUSTER_NAME:-securecloud}"
# Host port that maps to the ingress controller's HTTP endpoint.
K3D_HTTP_PORT="${K3D_HTTP_PORT:-8080}"
K3D_HTTPS_PORT="${K3D_HTTPS_PORT:-8443}"
NAMESPACE="${NAMESPACE:-securecloud}"

# --- images & versions (keep in sync with kubernetes/base/*-deployment.yaml) ---
SC_VERSION="${SC_VERSION:-3.0.0}"
BACKEND_IMAGE="securecloud-backend:${SC_VERSION}"
FRONTEND_IMAGE="securecloud-frontend:${SC_VERSION}"

# --- paths ---
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPTS_DIR}/.." && pwd)"
OVERLAY_DIR="${ROOT_DIR}/kubernetes/overlays/local"
SECRET_ENV="${OVERLAY_DIR}/secret.env"

require_cmd() {
  if ! command -v "${1}" >/dev/null 2>&1; then
    echo "error: required command '${1}' not found in PATH" >&2
    case "${1}" in
      kubectl) echo "  install kubectl: https://kubernetes.io/docs/tasks/tools/" >&2 ;;
      k3d)     echo "  install k3d:     https://k3d.io/stable/#installation" >&2 ;;
      docker)  echo "  install Docker:  https://docs.docker.com/get-docker/" >&2 ;;
    esac
    exit 1
  fi
}

require_cluster() {
  require_cmd k3d
  require_cmd kubectl
  if ! k3d cluster list 2>/dev/null | grep -q "^${K3D_CLUSTER_NAME}[[:space:]]"; then
    echo "error: cluster '${K3D_CLUSTER_NAME}' is not running; run: make cluster-up" >&2
    exit 1
  fi
  kubectl config use-context "k3d-${K3D_CLUSTER_NAME}" >/dev/null 2>&1 || true
}

app_url() {
  if [ "${K3D_HTTP_PORT}" = "80" ]; then
    echo "http://localhost"
  else
    echo "http://localhost:${K3D_HTTP_PORT}"
  fi
}