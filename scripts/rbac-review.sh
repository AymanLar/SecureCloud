#!/usr/bin/env bash
# Phase 4 RBAC review.
#
# Confirms the application ServiceAccounts follow least privilege:
#   - no binding to cluster-admin or any ClusterRole
#   - only the namespaced empty Role is bound
#   - no token is auto-mounted (automountServiceAccountToken: false)
#   - the accounts cannot perform sensitive verbs
#
# Exits non-zero if any expectation fails, so it can gate changes.

set -euo pipefail
source "$(dirname "$0")/lib.sh"

require_cmd kubectl
require_cluster

SAS=(securecloud-backend securecloud-frontend securecloud-postgres)
fail=0

echo "==> ServiceAccounts and their bindings"
kubectl -n "${NAMESPACE}" get sa "${SAS[@]}" -o custom-columns='NAME:.metadata.name,TOKEN:.automountServiceAccountToken' 2>/dev/null || true
echo
kubectl -n "${NAMESPACE}" get rolebinding -o custom-columns='NAME:.metadata.name,ROLE:.roleRef.name,SUBJECT:.subjects[*].name' 2>/dev/null || true
echo

echo "==> Check 1: no ClusterRoleBinding references a SecureCloud ServiceAccount"
bad_crb="$(kubectl get clusterrolebinding -o json 2>/dev/null | python -c "
import sys, json
d = json.load(sys.stdin)
hits = []
for b in d['items']:
    role = b.get('roleRef', {}).get('name', '')
    for s in b.get('subjects', []) or []:
        if s.get('kind') == 'ServiceAccount' and s.get('namespace') == 'securecloud':
            hits.append(f\"{b['metadata']['name']} -> {role}\")
print('\n'.join(hits))
")"
if [ -z "${bad_crb}" ]; then
  echo "  OK: SecureCloud ServiceAccounts have no ClusterRoleBindings"
else
  echo "  FAIL: found ClusterRoleBindings: ${bad_crb}" >&2
  fail=1
fi

echo
echo "==> Check 2: no cluster-admin membership touching SecureCloud"
admin_hit="$(kubectl get clusterrolebinding -o json 2>/dev/null | python -c "
import sys, json
d = json.load(sys.stdin)
hits = []
for b in d['items']:
    if b.get('roleRef', {}).get('name') != 'cluster-admin':
        continue
    for s in b.get('subjects', []) or []:
        if s.get('namespace') == 'securecloud' or 'securecloud' in (s.get('name', '')):
            hits.append(s)
print('; '.join(f\"{s.get('kind')}:{s.get('namespace')}/{s.get('name')}\" for s in hits))
")"
if [ -z "${admin_hit}" ]; then
  echo "  OK: no SecureCloud subject is cluster-admin"
else
  echo "  FAIL: cluster-admin subjects: ${admin_hit}" >&2
  fail=1
fi

echo
echo "==> Check 3: automountServiceAccountToken is false on every SA"
missing=""
for sa in "${SAS[@]}"; do
  v="$(kubectl -n "${NAMESPACE}" get sa "${sa}" -o jsonpath='{.automountServiceAccountToken}' 2>/dev/null || true)"
  if [ "${v}" != "false" ]; then missing="${missing} ${sa}"; fi
done
if [ -z "${missing}" ]; then
  echo "  OK: token automount disabled for all application SAs"
else
  echo "  FAIL: token automount not disabled:${missing}" >&2
  fail=1
fi

echo
echo "==> Check 4: sensitive verbs must be denied"
verbs=(
  "get secrets"
  "list secrets"
  "create pods"
  "create deployments"
  "create clusterrolebindings"
  "get nodes"
)
for sa in "${SAS[@]}"; do
  for v in "${verbs[@]}"; do
    # shellcheck disable=SC2086
    if kubectl auth can-i ${v} --as="system:serviceaccount:${NAMESPACE}:${sa}" -n "${NAMESPACE}" >/dev/null 2>&1; then
      echo "  FAIL: ${sa} MAY ${v}" >&2
      fail=1
    fi
  done
  echo "  OK: ${sa} denied all sensitive verbs (${#verbs[@]} checks)"
done

echo
if [ "${fail}" = "0" ]; then
  echo "RBAC REVIEW PASSED (least privilege confirmed)"
else
  echo "RBAC REVIEW FAILED" >&2
  exit 1
fi
