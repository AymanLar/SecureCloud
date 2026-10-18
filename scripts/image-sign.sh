#!/usr/bin/env bash
# Sign container images with Cosign (local / key-based mode).
#
# How signing works here:
#   * An ephemeral Cosign key pair is generated into SC_KEY_DIR on first use.
#     The directory is gitignored - the PRIVATE KEY IS NEVER COMMITTED.
#   * Each image is signed by its registry digest (host/repo@sha256:...), so the
#     signature is bound to the exact bytes being shipped, not to a mutable tag.
#   * cosign stores the signature in the registry alongside the image, hence the
#     image must be pushed to a registry first (see scripts/supply-chain-test.sh).
#
# In CI the very same flow runs *keyless*: no private key at all, GitHub's OIDC
# identity is exchanged for a short-lived Fulcio certificate and the signature is
# written to the Rekor transparency log. See .github/workflows/ci.yml.
#
# Usage:
#   scripts/image-sign.sh [image-ref ...]   default: local registry backend + frontend
#   SC_COSIGN_KEY=<path>                     override the key to sign with

set -euo pipefail
source "$(dirname "$0")/lib.sh"

require_cmd cosign
require_cmd docker

# The local demo key is generated with an empty passphrase, so export the (empty)
# password to keep cosign non-interactive. CI never uses a key - it signs keyless.
export COSIGN_PASSWORD="${COSIGN_PASSWORD:-}"

KEY="${SC_COSIGN_KEY}"
PUB="${SC_COSIGN_PUB}"

if [ ! -f "${KEY}" ]; then
  echo "==> generating ephemeral Cosign key pair in ${SC_KEY_DIR#"${ROOT_DIR}"/} (gitignored)"
  mkdir -p "${SC_KEY_DIR}"
  COSIGN_PASSWORD="${COSIGN_PASSWORD:-}" cosign generate-key-pair \
    --output-key-prefix "${SC_KEY_DIR}/cosign" >/dev/null
  echo "    private key: ${KEY#"${ROOT_DIR}"/}"
  echo "    public key:  ${PUB#"${ROOT_DIR}"/}"
fi

if [ "$#" -gt 0 ]; then
  images=("$@")
else
  images=("${SC_BACKEND_REF}" "${SC_FRONTEND_REF}")
fi

fail=0

for img in "${images[@]}"; do
  cosign_reg_flags "${img}"

  # Prefer signing by registry digest (avoids tag races). Fall back to the ref
  # itself when it is not a local image - cosign resolves the tag server-side.
  sig_ref="$(digest_ref "${img}")"
  if [ -z "${sig_ref}" ]; then
    sig_ref="${img}"
    echo "==> [${img}] not a local image - signing by reference"
  fi

  echo "==> signing ${sig_ref}"
  if ! cosign sign --key "${KEY}" --yes "${COSIGN_REG_FLAGS[@]}" "${sig_ref}"; then
    echo "  FAIL: could not sign ${img} (is it pushed to a registry?)" >&2
    fail=1
  fi
done

if [ "${fail}" = "0" ]; then
  echo "=> images signed (signatures stored beside the images in the registry)"
fi

exit "${fail}"
