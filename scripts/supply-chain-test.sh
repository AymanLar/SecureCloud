#!/usr/bin/env bash
# End-to-end software supply-chain demonstration. Proves, against real tools and
# real images, that the Phase 5 controls work:
#
#   1. local OCI registry running (stands in for GHCR)
#   2. ephemeral Cosign key pair (private key gitignored)
#   3. SBOM (CycloneDX + SPDX) generated from the built image - real dependencies
#   4. Trivy image scan - a CRITICAL finding stops the run
#   5. images pushed to the registry and signed
#   6. signed image   -> verification SUCCEEDS   (trusted)
#   7. unsigned image -> verification FAILS      (untrusted)
#
# This is the local equivalent of CI's publish -> sign -> verify chain.
#
# Usage:  bash scripts/supply-chain-test.sh        (or: make supply-chain)

set -euo pipefail
source "$(dirname "$0")/lib.sh"

require_cmd docker
require_cmd curl
require_cmd cosign
require_cmd syft
require_cmd trivy

docker version >/dev/null 2>&1 || {
  echo "error: Docker daemon is not running" >&2
  exit 1
}

UNSIGNED_REF="${SC_REGISTRY_HOST}/securecloud-unsigned:${SC_VERSION}"
fail=0

step() { echo; echo "==> $1"; }
ok()   { echo "  => PASS: $1"; }
bad()  { echo "  => FAIL: $1" >&2; fail=1; }

# --- 1. local registry ------------------------------------------------------
step "local OCI registry at ${SC_REGISTRY_HOST}"
if ! docker ps --format '{{.Names}}' | grep -qx "${SC_REGISTRY_NAME}"; then
  port="${SC_REGISTRY_HOST##*:}"
  echo "  starting ${SC_REGISTRY_NAME} (registry:2) on port ${port}"
  docker rm -f "${SC_REGISTRY_NAME}" >/dev/null 2>&1 || true
  docker run -d --name "${SC_REGISTRY_NAME}" -p "${port}:5000" registry:2 >/dev/null
fi
up=0
for _ in $(seq 1 30); do
  if curl -fsS "http://${SC_REGISTRY_HOST}/v2/" >/dev/null 2>&1; then up=1; break; fi
  sleep 1
done
if [ "${up}" = "1" ]; then ok "registry reachable"; else bad "registry did not come up"; fi

# --- 2. ephemeral key pair (never committed) --------------------------------
step "Cosign key material in ${SC_KEY_DIR#"${ROOT_DIR}"/} (gitignored)"
if [ -f "${SC_COSIGN_KEY}" ] && [ -f "${SC_COSIGN_PUB}" ]; then
  ok "reusing existing key pair"
else
  mkdir -p "${SC_KEY_DIR}"
  COSIGN_PASSWORD="${COSIGN_PASSWORD:-}" cosign generate-key-pair \
    --output-key-prefix "${SC_KEY_DIR}/cosign" >/dev/null
  ok "generated ephemeral key pair (private key is NOT committed)"
fi

# --- 3. push the images that will be signed ---------------------------------
step "push images to ${SC_REGISTRY_HOST}"
for svc in backend frontend; do
  src="securecloud-${svc}:${SC_VERSION}"
  dst="${SC_REGISTRY_HOST}/securecloud-${svc}:${SC_VERSION}"
  docker tag "${src}" "${dst}"
  if docker push "${dst}" >/dev/null 2>&1; then
    ok "pushed ${dst}"
  else
    bad "push ${dst}"
  fi
done

# --- 4. SBOM from the built image -------------------------------------------
step "generate SBOM (CycloneDX + SPDX) from the built images"
if bash "${SCRIPTS_DIR}/sbom.sh"; then
  ok "SBOM generated and validated (contains real dependencies)"
else
  bad "SBOM generation"
fi
if SBOM_FORMAT=spdx-json bash "${SCRIPTS_DIR}/sbom.sh" "${BACKEND_IMAGE}"; then
  ok "SPDX SBOM generated"
else
  bad "SPDX SBOM generation"
fi

# --- 5. Trivy image scan (CRITICAL stops the run) ---------------------------
step "Trivy container scan (fails on CRITICAL)"
if bash "${SCRIPTS_DIR}/scan-image.sh"; then
  ok "no CRITICAL / fixable HIGH-CRITICAL vulnerabilities"
else
  bad "container scan found vulnerabilities"
fi

# --- 6. sign ----------------------------------------------------------------
step "sign images with Cosign"
if bash "${SCRIPTS_DIR}/image-sign.sh"; then
  ok "images signed"
else
  bad "signing"
fi

# --- 7. signed image must verify -------------------------------------------
step "verification of SIGNED images (must succeed)"
if bash "${SCRIPTS_DIR}/image-verify.sh" "${SC_BACKEND_REF}" "${SC_FRONTEND_REF}"; then
  ok "trusted, signed images verified"
else
  bad "a signed image failed verification"
fi

# --- 8. unsigned image must NOT verify --------------------------------------
step "verification of UNSIGNED image (must fail)"
docker tag "securecloud-frontend:${SC_VERSION}" "${UNSIGNED_REF}"
docker push "${UNSIGNED_REF}" >/dev/null 2>&1
if bash "${SCRIPTS_DIR}/image-verify.sh" "${UNSIGNED_REF}"; then
  bad "unsigned image verified - signature enforcement is NOT working"
else
  ok "unsigned/untrusted image rejected"
fi

# --- summary ----------------------------------------------------------------
echo
echo "======================================================================"
if [ "${fail}" = "0" ]; then
  echo "SUPPLY-CHAIN TESTS PASSED"
  echo "  unsigned -> verification FAILED   (correctly rejected)"
  echo "  signed   -> verification SUCCEEDED (correctly accepted)"
else
  echo "SUPPLY-CHAIN TESTS FAILED" >&2
fi
echo "======================================================================"
echo "SBOMs:   ${SBOM_DIR#"${ROOT_DIR}"/}/   (gitignored, regenerated on demand)"
echo "registry: ${SC_REGISTRY_NAME} (leave running, or: docker rm -f ${SC_REGISTRY_NAME})"

exit "${fail}"
