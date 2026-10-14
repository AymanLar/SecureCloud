#!/usr/bin/env bash
# Install Kyverno (the admission policy engine) into the local cluster.
#
# Kyverno is installed from its pinned release manifest with a server-side
# apply (the CRDs exceed the client-side apply annotation limit). No Helm
# dependency is required.

set -euo pipefail
source "$(dirname "$0")/lib.sh"

require_cmd kubectl
require_cmd curl
require_cluster

KYVERNO_VERSION="${KYVERNO_VERSION:-v1.19.1}"
URL="https://github.com/kyverno/kyverno/releases/download/${KYVERNO_VERSION}/install.yaml"
MANIFEST="$(mktemp)"

echo "==> fetching Kyverno ${KYVERNO_VERSION} manifest"
curl -fsSL -o "${MANIFEST}" "${URL}"

echo "==> applying (server-side; CRDs are large)"
kubectl apply --server-side --force-conflicts -f "${MANIFEST}"
rm -f "${MANIFEST}"

echo "==> waiting for the Kyverno controllers to become Ready"
kubectl -n kyverno wait --for=condition=Ready pod --all --timeout=300s

echo
echo "Kyverno ${KYVERNO_VERSION} is ready."
echo "Next: make policies-audit   # measure violations"
echo "      make policies-enforce # start blocking"
echo "      make policy-test      # prove the policies work"
