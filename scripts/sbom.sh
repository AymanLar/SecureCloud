#!/usr/bin/env bash
# Generate an SBOM (software bill of materials) for built container images with Syft.
#
# The SBOM is derived from the *image itself* - the OS packages and the language
# dependencies Syft finds installed in the filesystem - not from a hand-written
# manifest. That is the point: it describes what actually ships.
#
# Usage:
#   scripts/sbom.sh [image ...]        default: backend + frontend images
#
# Environment:
#   SBOM_FORMAT=cyclonedx-json|spdx-json   output format (default cyclonedx-json)
#   SBOM_DIR=<dir>                         output directory (default <repo>/sbom)
#
# Fails if the SBOM is empty or does not contain known application dependencies,
# so a silently-empty document can never masquerade as a real SBOM.

set -euo pipefail
source "$(dirname "$0")/lib.sh"

require_cmd syft

FORMAT="${SBOM_FORMAT:-cyclonedx-json}"
OUTDIR="${SBOM_DIR}"

case "${FORMAT}" in
  cyclonedx-json) ext="cdx.json"; needle="bom-ref" ;;
  spdx-json)     ext="spdx.json"; needle="SPDXID" ;;
  *)
    echo "error: unsupported SBOM_FORMAT='${FORMAT}' (use cyclonedx-json or spdx-json)" >&2
    exit 1
    ;;
esac

if [ "$#" -gt 0 ]; then
  images=("$@")
else
  images=("${BACKEND_IMAGE}" "${FRONTEND_IMAGE}")
fi

mkdir -p "${OUTDIR}"
fail=0

for img in "${images[@]}"; do
  name="${img//[\/:@]/_}"
  out="${OUTDIR}/${name}.${ext}"

  echo "==> SBOM for ${img} (${FORMAT}) -> ${out#"${ROOT_DIR}"/}"
  if ! syft "${img}" -o "${FORMAT}=${out}" >/dev/null; then
    echo "  FAIL: syft could not analyse ${img}" >&2
    fail=1
    continue
  fi

  # --- the SBOM must not be a stub -------------------------------------------------
  if [ ! -s "${out}" ]; then
    echo "  FAIL: ${out} is empty" >&2
    fail=1
    continue
  fi

  count="$( (grep -o "${needle}" "${out}" || true) | wc -l | tr -d ' ')"

  # --- it must contain the application's real runtime dependencies ----------------
  #   backend  -> fastapi / sqlalchemy / psycopg (from requirements.txt)
  #   frontend -> next / react (from package.json)
  dep=""
  for candidate in fastapi sqlalchemy psycopg next react; do
    if grep -qi "${candidate}" "${out}"; then
      dep="${candidate}"
      break
    fi
  done

  if [ "${count}" -lt 10 ]; then
    echo "  FAIL: only ${count} components - not a real SBOM" >&2
    fail=1
  elif [ -z "${dep}" ]; then
    echo "  FAIL: no application dependency (fastapi/sqlalchemy/psycopg/next/react) found" >&2
    fail=1
  else
    echo "  OK: ${count} components, includes '${dep}' (${needle} entries)"
  fi
done

exit "${fail}"
