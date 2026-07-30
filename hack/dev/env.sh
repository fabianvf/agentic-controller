# shellcheck shell=bash
# Shared defaults for the local development environment. Source, do not execute.
#
# Every hack/dev/* script sources this first so they all agree on the profile,
# the kubeconfig, and the image tags.

[ -n "${__KONVEYOR_DEV_ENV_SH:-}" ] && return 0
__KONVEYOR_DEV_ENV_SH=1

# BASH_SOURCE is empty when sourced from a non-bash shell (e.g. a developer
# running `. hack/dev/env.sh` from zsh to pick up KUBECONFIG), so fall back to
# git. Without this, dirname("") resolves to "." and REPO_ROOT silently lands
# two directories above the repo.
if [ -n "${BASH_SOURCE[0]:-}" ]; then
    REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
else
    REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
fi
if [ -z "${REPO_ROOT}" ] || [ ! -d "${REPO_ROOT}/hack/dev" ]; then
    echo "ERROR: cannot locate the repository root; run from inside the repo" >&2
    return 1 2>/dev/null || exit 1
fi
export REPO_ROOT

# shellcheck source=hack/lib/common.sh
. "${REPO_ROOT}/hack/lib/common.sh"
# shellcheck source=hack/lib/cluster.sh
. "${REPO_ROOT}/hack/lib/cluster.sh"

# CRI-O by default: it is what OpenShift runs, and it is the runtime whose
# image-mount behaviour differs from containerd's.
CONTAINER_RUNTIME="${CONTAINER_RUNTIME:-cri-o}"
MINIKUBE_PROFILE="${MINIKUBE_PROFILE:-agentic-dev}"
MINIKUBE_DRIVER="${MINIKUBE_DRIVER:-$(common::container_tool)}"
MINIKUBE_K8S_VERSION="${MINIKUBE_K8S_VERSION:-v1.34.0}"
MINIKUBE_CPUS="${MINIKUBE_CPUS:-4}"
MINIKUBE_MEMORY="${MINIKUBE_MEMORY:-6144}"
# ImageVolume is beta (on by default) from k8s 1.33. Set empty to omit the flags
# entirely -- required once the gate is GA'd and removed, since an unknown gate
# makes the component refuse to start.
MINIKUBE_FEATURE_GATES="${MINIKUBE_FEATURE_GATES:-ImageVolume=true}"

CONTAINER_TOOL="$(common::container_tool)"
AGENT_SANDBOX_TAG="${AGENT_SANDBOX_TAG:-v0.5.0}"

DEV_IMG="${DEV_IMG:-quay.io/konveyor/agentic-controller:e2e}"
DEV_AGENT_IMG="${DEV_AGENT_IMG:-quay.io/konveyor/agentic-controller-agent:e2e}"
DEV_RESULTS_DIR="${DEV_RESULTS_DIR:-${REPO_ROOT}/.dev/results}"
AGENT_RUN="${AGENT_RUN:-dev-run}"

export CONTAINER_RUNTIME MINIKUBE_PROFILE MINIKUBE_DRIVER MINIKUBE_K8S_VERSION
export MINIKUBE_CPUS MINIKUBE_MEMORY MINIKUBE_FEATURE_GATES
export CONTAINER_TOOL AGENT_SANDBOX_TAG
export DEV_IMG DEV_AGENT_IMG DEV_RESULTS_DIR AGENT_RUN

# Kubeconfig isolation is a correctness requirement, not a convenience.
#
# Developers routinely have other clusters as their current context (this repo's
# author has an unrelated `mta-hub` minikube profile active). A dev target that
# ran bare `kubectl` would target whatever that happens to be -- and `make
# dev-apply` would create Agents and AgentRuns on it.
#
# Exported BEFORE `minikube start`, so minikube writes its context here and every
# downstream `kubectl`, `helm`, and nested `make install`/`make deploy` inherits
# it. Chosen over `kubectl --context` because the Makefile invokes "$(KUBECTL)"
# quoted, so an argument-bearing KUBECTL would break those targets.
DEV_KUBECONFIG="${DEV_KUBECONFIG:-${REPO_ROOT}/.dev/${MINIKUBE_PROFILE}.kubeconfig}"
mkdir -p "$(dirname "${DEV_KUBECONFIG}")"
export DEV_KUBECONFIG
export KUBECONFIG="${DEV_KUBECONFIG}"
