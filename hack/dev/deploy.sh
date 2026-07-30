#!/usr/bin/env bash
# Install CRDs and deploy the controller into the local minikube cluster.
#
# Reuses the existing hack/e2e kustomize overlay, which already repoints the
# controller image to the :e2e tag that DEV_IMG defaults to.
set -euo pipefail

# shellcheck source=hack/dev/env.sh
. "$(cd "$(dirname "$0")" && pwd)/env.sh"

cluster::exists || common::die "cluster '$(cluster::profile)' not found; run 'make dev-up' first"

common::log "Installing CRDs"
make -C "${REPO_ROOT}" install

common::log "Deploying controller"
make -C "${REPO_ROOT}" kustomize
"${REPO_ROOT}/bin/kustomize" build "${REPO_ROOT}/hack/e2e" | kubectl apply -f -

common::log "Waiting for the controller"
kubectl wait deployment/agentic-controller-controller-manager \
    --namespace agentic-controller-system --for=condition=Available --timeout=180s

common::log "Controller deployed"
kubectl get pods -n agentic-controller-system
