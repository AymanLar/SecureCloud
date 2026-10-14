#!/usr/bin/env bash
# Tail application logs. Optionally pass a workload name as argument:
#   ./scripts/logs.sh         # all SecureCloud workloads
#   ./scripts/logs.sh backend
#   ./scripts/logs.sh frontend
#   ./scripts/logs.sh postgres

set -euo pipefail
source "$(dirname "$0")/lib.sh"

require_cmd kubectl
require_cluster

SERVICE="${1:-all}"
case "${SERVICE}" in
  all)      SELECTOR="app.kubernetes.io/part-of=${NAMESPACE}" ;;
  backend)  SELECTOR="app=securecloud-backend" ;;
  frontend) SELECTOR="app=securecloud-frontend" ;;
  postgres | db) SELECTOR="app=securecloud-postgres" ;;
  *)        SELECTOR="app.kubernetes.io/name=${SERVICE}" ;;
esac

echo "==> tailing logs for: ${SERVICE}"
kubectl -n "${NAMESPACE}" logs --prefix -f --max-log-requests=10 -l "${SELECTOR}"