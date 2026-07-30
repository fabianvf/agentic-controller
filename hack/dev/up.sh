#!/usr/bin/env bash
# Create the local minikube cluster and install Agent Sandbox.
#
# Mirrors hack/start-kind.sh, but on minikube with a selectable container
# runtime. The kind script stays as-is and remains the CI regression path.
#
#   --minimal   skip the LLM emulator (not needed for the probe; saves a clone,
#               a build, and ~2 minutes)
set -euo pipefail

# shellcheck source=hack/dev/env.sh
. "$(cd "$(dirname "$0")" && pwd)/env.sh"

MINIMAL=0
for arg in "$@"; do
    case "$arg" in
        --minimal) MINIMAL=1 ;;
        *) common::die "unknown argument: $arg" ;;
    esac
done

common::require_cmd minikube kubectl helm git

common::log "Configuration"
common::info "profile:    ${MINIKUBE_PROFILE}"
common::info "runtime:    ${CONTAINER_RUNTIME}"
common::info "driver:     ${MINIKUBE_DRIVER}"
common::info "k8s:        ${MINIKUBE_K8S_VERSION}"
common::info "kubeconfig: ${DEV_KUBECONFIG}"

cluster::create

common::log "Installing Agent Sandbox ${AGENT_SANDBOX_TAG}"
SANDBOX_DIR="$(mktemp -d)"
trap 'rm -rf "${SANDBOX_DIR}"' EXIT
git clone --depth 1 --branch "${AGENT_SANDBOX_TAG}" \
    https://github.com/kubernetes-sigs/agent-sandbox.git "${SANDBOX_DIR}" 2>&1 | sed 's/^/    /'

if ! helm install agent-sandbox "${SANDBOX_DIR}/helm/" \
        --namespace agent-sandbox-system --create-namespace \
        --set image.tag="${AGENT_SANDBOX_TAG}" 2>&1 | sed 's/^/    /'; then
    common::info "install failed, attempting upgrade"
    helm upgrade agent-sandbox "${SANDBOX_DIR}/helm/" \
        --namespace agent-sandbox-system \
        --set image.tag="${AGENT_SANDBOX_TAG}" 2>&1 | sed 's/^/    /'
fi

common::log "Waiting for the Agent Sandbox controller"
kubectl wait deployment/agent-sandbox-controller \
    --namespace agent-sandbox-system --for=condition=Available --timeout=180s

if [ "${MINIMAL}" = 0 ]; then
    common::log "Installing LLEmulator (keyless mock LLM)"
    LLEM_DIR="$(mktemp -d)"
    LLEM_IMG="docker.io/library/openai-emulator:e2e"
    git clone --depth 1 https://github.com/fabianvf/llemulator.git "${LLEM_DIR}" 2>&1 | sed 's/^/    /'
    "${CONTAINER_TOOL}" build -t "${LLEM_IMG}" "${LLEM_DIR}" 2>&1 | tail -3 | sed 's/^/    /'
    cluster::load_image "${LLEM_IMG}"
    kubectl apply -f "${REPO_ROOT}/hack/e2e/llemulator.yaml"
    rm -rf "${LLEM_DIR}"
    kubectl wait deployment/openai-emulator --for=condition=Available --timeout=180s
else
    common::log "Skipping LLEmulator (--minimal)"
fi

common::log "Cluster ready"
kubectl get nodes -o custom-columns=\
NAME:.metadata.name,RUNTIME:.status.nodeInfo.containerRuntimeVersion,KUBELET:.status.nodeInfo.kubeletVersion
printf '\n'
common::info "Point your shell at it with:  eval \"\$(make dev-kubeconfig)\""
