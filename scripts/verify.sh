#!/usr/bin/env bash
# End-to-end connectivity checks:
#   T1  all SecureCloud pods become Ready
#   T2  frontend reachable through the ingress
#   T3  backend reachable through the ingress
#   T4  backend can reach PostgreSQL (via its own DB health endpoint)
#   T5  frontend -> backend (in-cluster, by Service DNS name)
#   T6  backend -> PostgreSQL (in-cluster, using the Secret DSN)

set -euo pipefail
source "$(dirname "$0")/lib.sh"

require_cmd kubectl
require_cmd curl
require_cluster

URL="$(app_url)"
fail=0

echo "==> T1: all SecureCloud pods become Ready"
if kubectl -n "${NAMESPACE}" wait --for=condition=Ready pod -l app.kubernetes.io/part-of=securecloud --timeout=180s >/dev/null 2>&1; then
  echo "  OK"
  kubectl -n "${NAMESPACE}" get pods -o wide
else
  echo "  FAIL: pods not Ready within 180s" >&2
  kubectl -n "${NAMESPACE}" get pods -o wide >&2
  fail=1
fi

echo "==> T2: frontend reachable via ingress (${URL}/)"
code="$(curl -sS -o /dev/null -w '%{http_code}' "${URL}/" || true)"
if [ "${code}" = "200" ]; then
  echo "  OK: HTTP ${code}"
else
  echo "  FAIL: HTTP ${code}" >&2
  fail=1
fi

echo "==> T3: backend reachable via ingress (${URL}/api/health)"
resp="$(curl -sS "${URL}/api/health" || true)"
if echo "${resp}" | grep -q "\"ok\""; then
  echo "  OK: ${resp}"
else
  echo "  FAIL: ${resp}" >&2
  fail=1
fi

echo "==> T4: backend -> PostgreSQL read/write (${URL}/api/health/db)"
resp="$(curl -sS "${URL}/api/health/db" || true)"
if echo "${resp}" | grep -q "\"ok\""; then
  echo "  OK: ${resp}"
else
  echo "  FAIL: ${resp} (backend could not reach PostgreSQL)" >&2
  fail=1
fi

echo "==> T5: frontend pod -> backend Service (in-cluster DNS)"
msg="$(kubectl -n "${NAMESPACE}" exec deploy/securecloud-frontend -- sh -c 'wget -qO- http://securecloud-backend:8000/api/health' 2>/dev/null || true)"
if echo "${msg}" | grep -q "\"ok\""; then
  echo "  OK: ${msg}"
else
  echo "  FAIL: ${msg}" >&2
  fail=1
fi

echo "==> T6: backend pod -> PostgreSQL using the Secret DSN"
msg="$(kubectl -n "${NAMESPACE}" exec deploy/securecloud-backend -- python -c "import os,psycopg;dsn=os.environ['DATABASE_URL'].replace('postgresql+psycopg://','postgresql://');print(psycopg.connect(dsn, connect_timeout=5).execute('select 1').fetchone())" 2>/dev/null || true)"
if echo "${msg}" | grep -q "1,"; then
  echo "  OK: ${msg}"
else
  echo "  FAIL: ${msg}" >&2
  fail=1
fi

echo
if [ "${fail}" = "0" ]; then
  echo "ALL CHECKS PASSED"
else
  echo "SOME CHECKS FAILED" >&2
  exit 1
fi