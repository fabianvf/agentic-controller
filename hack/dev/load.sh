#!/usr/bin/env bash
# Build and load images into the local minikube cluster.
#
#   load.sh controller     controller manager image
#   load.sh agent          stub agent image (+ the :latest alias the LLMProvider
#                          verification Job defaults to)
#   load.sh skills         every skills/examples/* as a FROM-scratch OCI image
#   load.sh all            all of the above (default)
set -euo pipefail

# shellcheck source=hack/dev/env.sh
. "$(cd "$(dirname "$0")" && pwd)/env.sh"

AGENT_LATEST="quay.io/konveyor/agentic-controller-agent:latest"

load_controller() {
    common::log "Building controller image ${DEV_IMG}"
    make -C "${REPO_ROOT}" docker-build IMG="${DEV_IMG}" CONTAINER_TOOL="${CONTAINER_TOOL}"
    cluster::load_image "${DEV_IMG}"
}

load_agent() {
    common::log "Building stub agent image ${DEV_AGENT_IMG}"
    make -C "${REPO_ROOT}" controller-agent-build \
        CONTROLLER_AGENT_IMG="${DEV_AGENT_IMG}" CONTAINER_TOOL="${CONTAINER_TOOL}"
    cluster::load_image "${DEV_AGENT_IMG}"

    # The LLMProvider verification Job defaults to the :latest tag
    # (llmprovider_controller.go). Without this alias the Job ImagePullBackOffs
    # and the provider never goes Ready, which blocks Agent readiness, which
    # blocks every AgentRun -- a confusing cascade from one missing tag.
    "${CONTAINER_TOOL}" tag "${DEV_AGENT_IMG}" "${AGENT_LATEST}"
    cluster::load_image "${AGENT_LATEST}"
}

load_skills() {
    common::log "Building skill images"
    # skillctl builds into its own OCI store; the kubelet needs real container
    # images, so build each skill FROM scratch. Same approach as
    # hack/setup-e2e.sh, kept identical so both paths agree.
    local dir name img ctx
    for dir in "${REPO_ROOT}"/skills/examples/*/; do
        [ -f "${dir}skill.yaml" ] || continue
        name="$(basename "${dir}")"
        img="quay.io/konveyor/skills:${name}"
        ctx="$(mktemp -d)"
        # cp -a, not cp -r: preserves modes, so a committed +x bit survives into
        # the image rather than being silently masked by umask.
        cp -a "${dir}." "${ctx}/"
        printf 'FROM scratch\nCOPY . /\n' > "${ctx}/Containerfile"
        common::info "building ${img}"
        "${CONTAINER_TOOL}" build -t "${img}" -f "${ctx}/Containerfile" "${ctx}" \
            2>&1 | tail -2 | sed 's/^/      /'
        rm -rf "${ctx}"
        cluster::load_image "${img}"
    done
}

verify() {
    common::log "Verifying images reached the container runtime"
    # crictl is ground truth: `minikube image ls` can list an image the CRI
    # cannot actually see, which then fails at pod creation instead of here.
    if minikube -p "$(cluster::profile)" ssh -- sudo crictl images 2>/dev/null \
        | grep -E 'konveyor/(agentic-controller|skills)' | sed 's/^/    /'; then
        :
    else
        common::warn "no konveyor images visible to crictl -- image load may have failed"
        common::warn "retry with MINIKUBE_LOAD_MODE=ssh"
    fi
}

cluster::exists || common::die "cluster '$(cluster::profile)' not found; run 'make dev-up' first"

case "${1:-all}" in
    controller) load_controller ;;
    agent)      load_agent ;;
    skills)     load_skills ;;
    all)        load_controller; load_agent; load_skills ;;
    *)          common::die "unknown target '${1}' (controller|agent|skills|all)" ;;
esac

verify
