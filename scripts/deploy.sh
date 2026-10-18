#!/usr/bin/env bash
# Build images, generate secrets if needed, apply the kustomize overlay and
# wait for rollouts. Idempotent: re-running reuses existing secrets/images.

set -euo pipefail
source "$(dirname "$0")/lib.sh"

require_cmd docker
require_cmd openssl
require_cluster

docker version >/dev/null 2>&1 || {
  echo "error: Docker daemon is not running (start Docker Desktop / the Docker service)" >&2
  exit 1
}

# 1. Secrets -----------------------------------------------------------------
mkdir -p "${OVERLAY_DIR}"

if [ ! -f "${SECRET_ENV}" ]; then
  echo "==> generating ${SECRET_ENV}"

  get_var() {
    grep -E "^${1}=" "${ROOT_DIR}/.env" 2>/dev/null | tail -n 1 | sed "s/^${1}=//"
  }

  PG_USER="securecloud"
  PG_DB="securecloud"
  PG_PASSWORD=""
  if [ -f "${ROOT_DIR}/.env" ]; then
    v="$(get_var POSTGRES_USER)";     if [ -n "${POSTGRES_USER:-}" ]; then PG_USER="${POSTGRES_USER}"; elif [ -n "$v" ]; then PG_USER="$v"; fi
    v="$(get_var POSTGRES_DB)";       if [ -n "${POSTGRES_DB:-}" ]; then PG_DB="${POSTGRES_DB}"; elif [ -n "$v" ]; then PG_DB="$v"; fi
    v="$(get_var POSTGRES_PASSWORD)"; if [ -n "${POSTGRES_PASSWORD:-}" ]; then PG_PASSWORD="${POSTGRES_PASSWORD}"; elif [ -n "$v" ]; then PG_PASSWORD="$v"; fi
  fi

  if [ -z "${PG_PASSWORD}" ] || [ "${PG_PASSWORD}" = "change-me-before-running" ]; then
    PG_PASSWORD="$(openssl rand -hex 24)"
    echo "  no usable POSTGRES_PASSWORD found - generated a random one"
    echo "  (set POSTGRES_PASSWORD in .env and delete kubernetes/overlays/local/secret.env to change it)"
  fi

  # URL-encode the password for the DSN (hex passwords are already URL-safe).
  PG_PASSWORD_ENC="${PG_PASSWORD}"
  if command -v python3 >/dev/null 2>&1; then
    PG_PASSWORD_ENC="$(python3 -c "import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1], safe=''))" "${PG_PASSWORD}")"
  fi
  DATABASE_URL="postgresql+psycopg://${PG_USER}:${PG_PASSWORD_ENC}@securecloud-postgres:5432/${PG_DB}"

  cat > "${SECRET_ENV}" <<EOF
POSTGRES_PASSWORD=${PG_PASSWORD}
DATABASE_URL=${DATABASE_URL}
EOF
  echo "  wrote ${SECRET_ENV}  (DO NOT COMMIT THIS FILE)"
else
  echo "==> reusing existing ${SECRET_ENV}"
fi

# 2. Images ------------------------------------------------------------------
echo "==> building backend image ${BACKEND_IMAGE}"
docker build -t "${BACKEND_IMAGE}" "${ROOT_DIR}/app/backend"

echo "==> building frontend image ${FRONTEND_IMAGE} (NEXT_PUBLIC_API_URL=$(app_url))"
docker build \
  --build-arg "NEXT_PUBLIC_API_URL=$(app_url)" \
  -t "${FRONTEND_IMAGE}" \
  "${ROOT_DIR}/app/frontend"

echo "==> importing images into cluster '${K3D_CLUSTER_NAME}'"
k3d image import --cluster "${K3D_CLUSTER_NAME}" "${BACKEND_IMAGE}" "${FRONTEND_IMAGE}"

# 3. Verify image signatures (opt-in deployment gate) -----------------------
# When SC_VERIFY_IMAGES=1 (or `make deploy-verified`), every image must carry a
# valid Cosign signature from a trusted identity before anything is applied.
# This is the deployment-time guard: an unsigned or tampered image cannot roll out.
if [ "${SC_VERIFY_IMAGES:-0}" = "1" ]; then
  echo "==> verifying image signatures before deploy (SC_VERIFY_IMAGES=1)"
  bash "${SCRIPTS_DIR}/image-verify.sh"
  echo "    all images verified"
else
  echo "==> image signature verification skipped (run with SC_VERIFY_IMAGES=1 to enforce)"
fi

# 4. Apply -------------------------------------------------------------------
echo "==> applying overlay: kubectl apply -k ${OVERLAY_DIR}"
kubectl apply -k "${OVERLAY_DIR}"

echo "==> waiting for rollouts"
kubectl -n "${NAMESPACE}" rollout status deploy/securecloud-backend --timeout=300s --watch
kubectl -n "${NAMESPACE}" rollout status deploy/securecloud-frontend --timeout=300s --watch
kubectl -n "${NAMESPACE}" rollout status statefulset/securecloud-postgres --timeout=300s --watch
kubectl -n "${NAMESPACE}" wait --for=condition=Ready pod -l app.kubernetes.io/part-of=securecloud --timeout=300s

echo
echo "app is live at: $(app_url)"
echo "dashboard:      make status   |   logs: make logs   |   checks: make verify"