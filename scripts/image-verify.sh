#!/usr/bin/env bash
# Verify container image signatures with Cosign. Exits non-zero if ANY image is
# unsigned or signed by an untrusted identity - this is what the deploy gate and
# the CI verification step call.
#
# Two modes, picked automatically:
#
#   key mode (local)      when a local public key exists (SC_COSIGN_PUB) or
#                         SC_COSIGN_PUBLIC_KEY is set. Verifies against that key.
#   keyless mode (CI)     otherwise. Verifies a GitHub-Actions-issued Fulcio
#                         certificate matched by SC_COSIGN_CERT_IDENTITY and
#                         SC_COSIGN_OIDC_ISSUER.
#
# Environment:
#   SC_COSIGN_PUBLIC_KEY     path to the public key (key mode)
#   SC_COSIGN_CERT_IDENTITY  identity regexp (keyless), e.g.
#                            https://github.com/owner/repo/.github/workflows/ci.yml@
#   SC_COSIGN_OIDC_ISSUER    certificate issuer (keyless), default GitHub Actions
#
# Usage:
#   scripts/image-verify.sh [image-ref ...]   default: local registry backend + frontend

set -euo pipefail
source "$(dirname "$0")/lib.sh"

require_cmd cosign

# Explicit override wins; otherwise fall back to the local key pair if present.
if [ -n "${SC_COSIGN_PUBLIC_KEY:-}" ]; then
  PUB="${SC_COSIGN_PUBLIC_KEY}"
elif [ -f "${SC_COSIGN_PUB}" ]; then
  PUB="${SC_COSIGN_PUB}"
else
  PUB=""
fi

if [ "$#" -gt 0 ]; then
  images=("$@")
else
  images=("${SC_BACKEND_REF}" "${SC_FRONTEND_REF}")
fi

if [ -n "${PUB}" ]; then
  if [ ! -f "${PUB}" ]; then
    echo "error: SC_COSIGN_PUBLIC_KEY points to a missing file: ${PUB}" >&2
    exit 2
  fi
  MODE="key"
  echo "==> verification mode: key (${PUB})"
else
  if [ -z "${SC_COSIGN_CERT_IDENTITY:-}" ]; then
    echo "error: no local public key and SC_COSIGN_CERT_IDENTITY is not set." >&2
    echo "       (keyless mode needs the identity the signer certificate was issued for)" >&2
    exit 2
  fi
  MODE="keyless"
  echo "==> verification mode: keyless (identity=${SC_COSIGN_CERT_IDENTITY})"
fi

fail=0

for img in "${images[@]}"; do
  cosign_reg_flags "${img}"

  if [ "${MODE}" = "key" ]; then
    if cosign verify --key "${PUB}" "${COSIGN_REG_FLAGS[@]}" "${img}" >/dev/null; then
      echo "  OK: ${img} signature verified"
    else
      echo "  REJECTED: ${img} is unsigned or signed by an untrusted key" >&2
      fail=1
    fi
  else
    if cosign verify \
        --certificate-identity-regexp "${SC_COSIGN_CERT_IDENTITY}" \
        --certificate-oidc-issuer "${SC_COSIGN_OIDC_ISSUER:-https://token.actions.githubusercontent.com}" \
        "${COSIGN_REG_FLAGS[@]}" "${img}" >/dev/null; then
      echo "  OK: ${img} signature verified (trusted identity)"
    else
      echo "  REJECTED: ${img} is unsigned or signed by an untrusted identity" >&2
      fail=1
    fi
  fi
done

if [ "${fail}" = "0" ]; then
  echo "=> all images verified"
else
  echo "=> signature verification FAILED" >&2
fi

exit "${fail}"
