# shellcheck shell=bash
# minikube cluster lifecycle and image loading. Source, do not execute.
#
# Why minikube and not kind: kind is containerd-only ("kind only supports
# containerd, with experimental support for podman" -- and podman there is the
# host driver, not the in-node CRI). OpenShift runs CRI-O, and CRI-O and
# containerd handle image-volume mounts differently, so a containerd-only answer
# does not transfer. minikube's --container-runtime accepts docker|cri-o|containerd.
#
# The kind path (hack/start-kind.sh, hack/setup-e2e.sh, make e2e) is untouched
# and remains the CI regression path.

[ -n "${__KONVEYOR_CLUSTER_SH:-}" ] && return 0
__KONVEYOR_CLUSTER_SH=1

# shellcheck source=hack/lib/common.sh
. "${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}/hack/lib/common.sh"

cluster::profile() { printf '%s\n' "${MINIKUBE_PROFILE:-agentic-dev}"; }

cluster::_state_file() {
    printf '%s/.dev/%s.state\n' "${REPO_ROOT}" "$(cluster::profile)"
}

# Settings that, if changed, mean the existing profile is the wrong cluster.
# Without this check `minikube start` silently reuses a profile built with a
# different container runtime -- which would quietly produce the wrong answer to
# the exact question this environment exists to answer.
cluster::_want_state() {
    printf 'runtime=%s k8s=%s gates=%s driver=%s\n' \
        "${CONTAINER_RUNTIME}" "${MINIKUBE_K8S_VERSION}" \
        "${MINIKUBE_FEATURE_GATES}" "${MINIKUBE_DRIVER}"
}

cluster::exists() {
    minikube profile list -o json 2>/dev/null \
        | tr ',' '\n' | grep -q "\"Name\":\"$(cluster::profile)\"" || return 1
}

cluster::create() {
    local profile want have
    profile="$(cluster::profile)"
    want="$(cluster::_want_state)"

    if [ -f "$(cluster::_state_file)" ]; then
        have="$(cat "$(cluster::_state_file)")"
        if [ "${have}" != "${want}" ]; then
            common::err "profile '${profile}' already exists with different settings:"
            common::err "  have: ${have}"
            common::err "  want: ${want}"
            common::die "run 'make dev-down' first, or set MINIKUBE_PROFILE to a new name"
        fi
    fi

    local args
    args=(start -p "${profile}"
          --container-runtime="${CONTAINER_RUNTIME}"
          --cpus="${MINIKUBE_CPUS}"
          --memory="${MINIKUBE_MEMORY}"
          --wait=all
          --wait-timeout=10m)

    [ -n "${MINIKUBE_DRIVER}" ]      && args+=(--driver="${MINIKUBE_DRIVER}")
    [ -n "${MINIKUBE_K8S_VERSION}" ] && args+=(--kubernetes-version="${MINIKUBE_K8S_VERSION}")

    # Set the gate on each component explicitly. minikube's global
    # --feature-gates has not always propagated to the kubelet, and the kubelet
    # is the component that must honour ImageVolume. An unknown gate makes the
    # component refuse to start -- a loud failure, which is what we want over a
    # silently missing volume type.
    if [ -n "${MINIKUBE_FEATURE_GATES}" ]; then
        args+=(--feature-gates="${MINIKUBE_FEATURE_GATES}"
               --extra-config="apiserver.feature-gates=${MINIKUBE_FEATURE_GATES}"
               --extra-config="kubelet.feature-gates=${MINIKUBE_FEATURE_GATES}")
    fi

    common::log "minikube start -p ${profile} (runtime=${CONTAINER_RUNTIME})"
    minikube "${args[@]}"

    mkdir -p "$(dirname "$(cluster::_state_file)")"
    printf '%s\n' "${want}" > "$(cluster::_state_file)"
}

cluster::delete() {
    common::log "Deleting minikube profile '$(cluster::profile)'"
    minikube delete -p "$(cluster::profile)" || true
    rm -f "$(cluster::_state_file)"
}

# Load a locally-built image into the cluster.
#
# One path for every host: build -> save to a docker-archive tar -> minikube
# image load. `podman save` streams the archive out of the podman-machine VM to
# a host file, which is what makes this work on macOS; the same dance is already
# relied on for kind (hack/setup-e2e.sh:53).
#
# Not `minikube cache add`  -- that pulls from a *remote* registry.
# Not `eval $(minikube docker-env)` -- docker-runtime only, i.e. the one runtime
# that cannot serve ImageVolume anyway.
#
# One image per tar: podman needs --multi-image-archive for multiple, which is a
# version-dependent footgun.
cluster::load_image() {
    local img=$1 tool dir tar
    tool="$(common::container_tool)"
    dir="$(mktemp -d)"          # bare -d: BSD mktemp requires a template with -t
    tar="${dir}/image.tar"

    common::info "loading ${img}"
    "${tool}" save "${img}" -o "${tar}"

    case "${MINIKUBE_LOAD_MODE:-archive}" in
        archive)
            minikube -p "$(cluster::profile)" image load --overwrite=true "${tar}"
            ;;
        ssh)
            # Fallback: `minikube image load` on cri-o has historically been the
            # flakiest path, so drive the node's own tooling directly.
            cluster::_load_via_ssh "${tar}"
            ;;
        *)
            rm -rf "${dir}"
            common::die "unknown MINIKUBE_LOAD_MODE '${MINIKUBE_LOAD_MODE}' (archive|ssh)"
            ;;
    esac

    rm -rf "${dir}"
}

cluster::_load_via_ssh() {
    local tar=$1 p
    p="$(cluster::profile)"
    minikube -p "$p" cp "${tar}" /tmp/konveyor-load.tar
    case "${CONTAINER_RUNTIME}" in
        containerd) minikube -p "$p" ssh -- sudo ctr -n k8s.io images import /tmp/konveyor-load.tar ;;
        cri-o)      minikube -p "$p" ssh -- sudo podman load -i /tmp/konveyor-load.tar ;;
        docker)     minikube -p "$p" ssh -- docker load -i /tmp/konveyor-load.tar ;;
        *)          common::die "unknown CONTAINER_RUNTIME '${CONTAINER_RUNTIME}'" ;;
    esac
    minikube -p "$p" ssh -- sudo rm -f /tmp/konveyor-load.tar
}

# crictl is ground truth across all three runtimes -- `minikube image ls` can
# report an image the CRI cannot actually see.
cluster::verify_image() {
    local img=$1
    if minikube -p "$(cluster::profile)" ssh -- sudo crictl images 2>/dev/null \
        | grep -q "$(printf '%s' "${img}" | cut -d: -f1)"; then
        return 0
    fi
    return 1
}
