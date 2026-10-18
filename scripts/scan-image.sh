#!/usr/bin/env bash
# Scan built container images for known vulnerabilities with Trivy.
#
# Two gates run per image:
#   1. fixable HIGH / CRITICAL   -- fails the run (same policy as CI; matches
#      docs/SECURITY-PIPELINE.md).
#   2. CRITICAL (any, fixed or not) -- fails the run unconditionally. A CRITICAL
#      finding in a container is a stop-the-line event, so it is never ignored,
#      not even when no fix is published yet.
#
# Usage:
#   scripts/scan-image.sh [image ...]   default: backend + frontend images

set -euo pipefail
source "$(dirname "$0")/lib.sh"

require_cmd trivy

if [ "$#" -gt 0 ]; then
  images=("$@")
else
  images=("${BACKEND_IMAGE}" "${FRONTEND_IMAGE}")
fi

fail=0

for img in "${images[@]}"; do
  echo "==> [${img}] fixable HIGH/CRITICAL vulnerabilities"
  if ! trivy image --scanners vuln --severity HIGH,CRITICAL --ignore-unfixed \
      --exit-code 1 --skip-version-check "${img}"; then
    echo "  FAIL: fixable HIGH/CRITICAL found in ${img}" >&2
    fail=1
  fi

  echo "==> [${img}] CRITICAL vulnerabilities (hard gate, unfixed included)"
  if ! trivy image --scanners vuln --severity CRITICAL \
      --exit-code 1 --skip-version-check "${img}"; then
    echo "  FAIL: CRITICAL found in ${img} - pipeline must stop" >&2
    fail=1
  fi
done

if [ "${fail}" = "0" ]; then
  echo "=> container scan clean (no CRITICAL, no fixable HIGH/CRITICAL)"
fi

exit "${fail}"
