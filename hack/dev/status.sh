#!/usr/bin/env bash
# One-screen view of the local environment: CRs, Sandboxes, pods.
set -uo pipefail

# shellcheck source=hack/dev/env.sh
. "$(cd "$(dirname "$0")" && pwd)/env.sh"

if ! cluster::exists; then
    common::warn "cluster '$(cluster::profile)' not found; run 'make dev-up'"
    exit 0
fi

common::log "Cluster"
kubectl get nodes -o custom-columns=\
NAME:.metadata.name,RUNTIME:.status.nodeInfo.containerRuntimeVersion,KUBELET:.status.nodeInfo.kubeletVersion 2>/dev/null

common::log "Definition resources"
kubectl get llmprovider,skillcard,skillcollection,agent,agentplaybook 2>/dev/null \
    || common::info "(none -- CRDs installed? run 'make dev-deploy')"

common::log "Runs"
kubectl get agentrun,agentplaybookrun 2>/dev/null || common::info "(none)"

common::log "Sandboxes"
kubectl get sandbox 2>/dev/null || common::info "(none)"

common::log "Pods"
kubectl get pods -o wide 2>/dev/null || common::info "(none)"

common::log "Controller"
kubectl get pods -n agentic-controller-system 2>/dev/null \
    || common::info "(controller not deployed -- run 'make dev-deploy')"

# Not-Ready conditions are the usual reason a run is stuck, and reading them off
# `get` output alone is painful.
common::log "Conditions (not Ready)"
for kind in llmprovider skillcard skillcollection agent; do
    kubectl get "${kind}" -o json 2>/dev/null \
        | grep -o '"message":"[^"]*"' | head -5 | sed "s/^/    ${kind}: /" || true
done
