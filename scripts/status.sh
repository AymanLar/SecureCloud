#!/usr/bin/env bash
# Print the current state of the cluster and the SecureCloud workloads.

set -euo pipefail
source "$(dirname "$0")/lib.sh"

require_cmd kubectl
require_cluster

echo "=== nodes ==="
kubectl get nodes -o wide

echo
echo "=== securecloud workloads ==="
kubectl -n "${NAMESPACE}" get deploy,sts,pods -o wide

echo
echo "=== services / ingress / config / secrets / sa / networkpolicies / pvc ==="
kubectl -n "${NAMESPACE}" get svc,ingress,configmap,secret,serviceaccount,networkpolicy,pvc

echo
echo "=== image versions in use ==="
kubectl -n "${NAMESPACE}" get deploy,sts -o custom-columns='KIND:.kind,NAME:.metadata.name,IMAGES:.spec.template.spec.containers[*].image'