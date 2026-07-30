#!/usr/bin/env bash
# Preflight the local dev environment.
#
# Every check here corresponds to a failure that is confusing when hit later:
# a missing tool, an arch mismatch that surfaces as "exec format error" deep
# inside a sandbox pod, a runtime that silently cannot serve ImageVolume.
set -uo pipefail

# shellcheck source=hack/dev/env.sh
. "$(cd "$(dirname "$0")" && pwd)/env.sh"

FAIL=0
ok()   { printf '  \033[1;32m%-12s\033[0m %s\n' "ok" "$*"; }
bad()  { printf '  \033[1;31m%-12s\033[0m %s\n' "MISSING" "$*"; FAIL=1; }
note() { printf '  \033[1;33m%-12s\033[0m %s\n' "note" "$*"; }

common::log "Tools"
for t in minikube kubectl helm git; do
    if common::have "$t"; then ok "$t ($("$t" version --short 2>/dev/null | head -1 || echo present))"
    else bad "$t"; fi
done
if common::have "${CONTAINER_TOOL}"; then ok "container tool: ${CONTAINER_TOOL}"
else bad "container tool: ${CONTAINER_TOOL}"; fi

common::log "Configuration"
note "profile:     ${MINIKUBE_PROFILE}"
note "runtime:     ${CONTAINER_RUNTIME}"
note "driver:      ${MINIKUBE_DRIVER}"
note "k8s version: ${MINIKUBE_K8S_VERSION}"
note "gates:       ${MINIKUBE_FEATURE_GATES:-<none>}"
note "kubeconfig:  ${DEV_KUBECONFIG}"

# cri-dockerd does not implement ImageVolume at all, so a docker-runtime profile
# cannot answer the question this environment exists for.
case "${CONTAINER_RUNTIME}" in
    docker)
        note "CONTAINER_RUNTIME=docker: cri-dockerd does not implement ImageVolume."
        note "  Skill mounts will not work. Use cri-o (OpenShift) or containerd."
        ;;
esac

common::log "Architecture"
HOST_ARCH="$("${CONTAINER_TOOL}" info --format '{{.Host.Arch}}' 2>/dev/null \
    || uname -m 2>/dev/null)"
note "host: ${HOST_ARCH:-unknown}"
# A `FROM scratch` image still declares os/arch. Building arm64 images for an
# amd64 node yields "exec format error" with no obvious cause.
if cluster::exists; then
    NODE_ARCH="$(kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.architecture}' 2>/dev/null)"
    note "node: ${NODE_ARCH:-unknown}"
    case "${HOST_ARCH}" in
        aarch64|arm64) H=arm64 ;;
        x86_64|amd64)  H=amd64 ;;
        *)             H="${HOST_ARCH}" ;;
    esac
    if [ -n "${NODE_ARCH:-}" ] && [ "${H}" != "${NODE_ARCH}" ]; then
        printf '  \033[1;31m%-12s\033[0m %s\n' "MISMATCH" \
            "host ${H} vs node ${NODE_ARCH}: locally built images will not run"
        FAIL=1
    fi
    if [ -n "${DOCKER_DEFAULT_PLATFORM:-}" ]; then
        note "DOCKER_DEFAULT_PLATFORM=${DOCKER_DEFAULT_PLATFORM} is set -- this can"
        note "  silently produce images the node cannot execute."
    fi
else
    note "node: (cluster not running -- run 'make dev-up')"
fi

if cluster::exists; then
    common::log "Cluster"
    RUNTIME_VER="$(kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.containerRuntimeVersion}' 2>/dev/null)"
    note "runtime version: ${RUNTIME_VER:-unknown}"
    case "${RUNTIME_VER}" in
        cri-o://1.2*|cri-o://1.30.*) note "  cri-o < 1.31 has no ImageVolume support" ;;
        containerd://1.*)            note "  containerd < 2.0 has no ImageVolume support" ;;
    esac
    NODE="$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
    GATE="$(kubectl get --raw "/api/v1/nodes/${NODE}/proxy/metrics" 2>/dev/null \
        | grep '^kubernetes_feature_enabled{name="ImageVolume"' | head -1)"
    if [ -n "${GATE}" ]; then
        note "ImageVolume gate: ${GATE}"
        case "${GATE}" in *"} 0") note "  DISABLED -- skill mounts will fail" ;; esac
    else
        note "ImageVolume gate: not reported (likely GA, or metrics unavailable)"
    fi
fi

printf '\n'
if [ "${FAIL}" = 0 ]; then
    common::log "Preflight passed."
else
    common::err "Preflight found problems (see MISSING/MISMATCH above)."
    exit 1
fi
