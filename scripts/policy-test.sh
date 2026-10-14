#!/usr/bin/env bash
# Test every Kyverno baseline policy against deliberate violations and a
# compliant example.
#
#   EVERY bad/* manifest   -> must be REJECTED (enforce) / accepted (audit)
#   EVERY good/* manifest  -> must be ACCEPTED
#
# The script applies the enforce overlay first so the expected result is
# deterministic, then uses server-side dry-run: admission webhooks run, so
# Kyverno evaluates the object, but nothing is persisted.

set -euo pipefail
source "$(dirname "$0")/lib.sh"

require_cmd kubectl
require_cluster

TESTS_DIR="${ROOT_DIR}/kubernetes/policy-tests"

echo "==> applying enforce overlay: kubectl apply -k kubernetes/policies/enforce"
kubectl apply -k "${ROOT_DIR}/kubernetes/policies/enforce" >/dev/null

# Wait until the policies report Ready before asserting results.
echo "==> waiting for policies to be ready"
READY_PATH='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}'
for i in $(seq 1 30); do
  notready="$(kubectl get clusterpolicy -o jsonpath="${READY_PATH}" 2>/dev/null | grep -c -v "True" || true)"
  if [ "${notready}" = "0" ]; then break; fi
  sleep 2
done
kubectl get clusterpolicy -o custom-columns='NAME:.metadata.name,ACTION:.spec.validationFailureAction' 2>/dev/null | grep securecloud || true
echo

# expect_reject FILE  -> returns 0 when admission blocks it
result_of() {
  # $1 = file ; echoes "rejected" or "accepted"
  if kubectl apply --dry-run=server -f "$1" >/tmp/kyv.out 2>&1; then
    echo "accepted"
  else
    echo "rejected"
  fi
}

fail=0
printf '%-42s %-10s %-10s %s\n' "MANIFEST" "EXPECTED" "GOT" "RESULT"
printf '%-42s %-10s %-10s %s\n' "------------------------------------------" "--------" "--------" "------"

for f in "${TESTS_DIR}"/bad/*.yaml; do
  got="$(result_of "$f")"
  if [ "${got}" = "rejected" ]; then res="PASS"; else res="FAIL"; fail=1; fi
  printf '%-42s %-10s %-10s %s\n' "bad/$(basename "$f")" "rejected" "${got}" "${res}"
done

for f in "${TESTS_DIR}"/good/*.yaml; do
  got="$(result_of "$f")"
  if [ "${got}" = "accepted" ]; then res="PASS"; else res="FAIL"; fail=1; fi
  printf '%-42s %-10s %-10s %s\n' "good/$(basename "$f")" "accepted" "${got}" "${res}"
done

echo
if [ "${fail}" = "0" ]; then
  echo "ALL POLICY TESTS PASSED (violations rejected, compliant accepted)"
else
  echo "SOME POLICY TESTS FAILED" >&2
  exit 1
fi
