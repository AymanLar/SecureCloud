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
      syft)    echo "  install syft:    https://github.com/anchore/syft/releases" >&2 ;;
      cosign)  echo "  install cosign:  https://github.com/sigstore/cosign/releases" >&2 ;;
      trivy)   echo "  install trivy:   https://github.com/aquasecurity/trivy/releases" >&2 ;;
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

# --- supply chain (Phase 5) ---------------------------------------------------
# Local OCI registry used by scripts/supply-chain-test.sh to demonstrate a real
# sign -> verify round trip offline. Signatures must live next to the image, so a
# (throwaway) registry stands in for GHCR on a developer machine.
SC_REGISTRY_HOST="${SC_REGISTRY_HOST:-localhost:5000}"
SC_REGISTRY_NAME="${SC_REGISTRY_NAME:-sc-registry}"

# Ephemeral Cosign key material for the local demo. SC_KEY_DIR is gitignored: the
# private key must NEVER be committed. CI does not use a key at all - it signs
# keyless via GitHub's OIDC identity.
SC_KEY_DIR="${SC_KEY_DIR:-${ROOT_DIR}/.supplychain}"
SC_COSIGN_KEY="${SC_COSIGN_KEY:-${SC_KEY_DIR}/cosign.key}"
SC_COSIGN_PUB="${SC_COSIGN_PUB:-${SC_KEY_DIR}/cosign.pub}"

# Image references the local registry flow signs / verifies.
SC_BACKEND_REF="${SC_BACKEND_REF:-${SC_REGISTRY_HOST}/securecloud-backend:${SC_VERSION}}"
SC_FRONTEND_REF="${SC_FRONTEND_REF:-${SC_REGISTRY_HOST}/securecloud-frontend:${SC_VERSION}}"

# Where generated SBOMs land (gitignored - regenerated on demand).
SBOM_DIR="${SBOM_DIR:-${ROOT_DIR}/sbom}"

# Fill the COSIGN_REG_FLAGS array: local plain-HTTP registries need
# --allow-http-registry; real TLS registries need no flag at all.
cosign_reg_flags() {
  COSIGN_REG_FLAGS=()
  case "$1" in
    localhost:*|127.0.0.1:*|\[::1\]:*) COSIGN_REG_FLAGS=(--allow-http-registry) ;;
  esac
}

# Print the registry-qualified digest reference (host/repo@sha256:...) for a local
# image tag that has been pushed to a registry. Prints nothing if the image was
# never pushed (or is not a local image). Docker stores several RepoDigests per
# image, so the digest is matched against the exact registry/repo of the ref.
digest_ref() {
  local ref="$1" repo
  repo="${ref%:*}" # strip the trailing :tag
  docker image inspect "$ref" >/dev/null 2>&1 || return 0
  docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$ref" 2>/dev/null \
    | grep -F "${repo}@" | head -n 1 || true
}