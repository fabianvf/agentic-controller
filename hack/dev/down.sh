#!/usr/bin/env bash
# Delete the local minikube cluster and its repo-local kubeconfig.
set -euo pipefail

# shellcheck source=hack/dev/env.sh
. "$(cd "$(dirname "$0")" && pwd)/env.sh"

if cluster::exists; then
    cluster::delete
else
    common::log "Profile '$(cluster::profile)' does not exist; nothing to delete"
    rm -f "$(cluster::_state_file)" 2>/dev/null || true
fi

rm -f "${DEV_KUBECONFIG}" 2>/dev/null || true
common::log "Done"
