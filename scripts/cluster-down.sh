#!/usr/bin/env bash
# Delete the local k3d cluster and everything in it (pods, PVCs, images).

set -euo pipefail
source "$(dirname "$0")/lib.sh"

require_cmd k3d

if k3d cluster list 2>/dev/null | grep -q "^${K3D_CLUSTER_NAME}[[:space:]]"; then
  echo "==> deleting cluster '${K3D_CLUSTER_NAME}'"
  k3d cluster delete "${K3D_CLUSTER_NAME}"
else
  echo "==> cluster '${K3D_CLUSTER_NAME}' does not exist"
fi