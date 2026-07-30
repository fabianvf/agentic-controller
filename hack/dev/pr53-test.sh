#!/usr/bin/env bash
# Run a real agent (PR #53 harness + real Anthropic model + Hub) and observe
# where it stages a script it is told to write and execute.
#
# This is the experiment behind ADR 0007: the convention says stage to /tmp,
# outside the git worktree the harness commits and pushes. This checks what a
# real model actually does when the skill does not say where to write.
set -euo pipefail

# shellcheck source=hack/dev/env.sh
. "$(cd "$(dirname "$0")" && pwd)/env.sh"

# The PR #53 Makefile builds agent-java as :latest, but a :latest tag makes
# Kubernetes default imagePullPolicy to Always -- so the kubelet ignores the
# locally-loaded image and tries (and fails) to pull from quay.io. The
# controller never sets PullPolicy explicitly, so the tag is the only lever.
# Retag to :dev, which defaults to IfNotPresent. This is why the skill images,
# tagged :<skill-name>, have worked all along.
PR53_BUILT_IMG="${PR53_BUILT_IMG:-quay.io/konveyor/agent-java:latest}"
PR53_AGENT_IMG="${PR53_AGENT_IMG:-quay.io/konveyor/agent-java:dev}"
LLM_MODEL="${DEV_LLM_MODEL:-claude-sonnet-5}"
SKILL_SRC="${REPO_ROOT}/hack/dev/skills/exec-convention"
SKILL_IMG="quay.io/konveyor/skills:exec-convention"
APP_ID_FILE="${REPO_ROOT}/.dev/hub-app-id"

cluster::exists || common::die "cluster not found; run 'make dev-up' first"
[ -r "${APP_ID_FILE}" ] || common::die "no seeded Hub app; run 'make dev-hub' first"
APP_ID="$(cat "${APP_ID_FILE}")"

# --- credential ------------------------------------------------------------

KEY="${ANTHROPIC_API_KEY:-}"
if [ -z "${KEY}" ] && [ -r "${REPO_ROOT}/.dev/anthropic.key" ]; then
    KEY="$(tr -d '\r\n' < "${REPO_ROOT}/.dev/anthropic.key")"
fi
if [ -z "${KEY}" ] && [ -r "${REPO_ROOT}/.env" ]; then
    KEY="$(sed -nE 's/^[[:space:]]*(export[[:space:]]+)?ANTHROPIC_API_KEY=["'"'"']?([^"'"'"']*)["'"'"']?[[:space:]]*$/\2/p' \
        "${REPO_ROOT}/.env" | head -1 | tr -d '\r\n')"
fi
[ -n "${KEY}" ] || common::die "no Anthropic API key (env, .dev/anthropic.key, or .env)"
common::log "Using model ${LLM_MODEL} (key len=${#KEY})"

# --- skill image -----------------------------------------------------------

common::log "Building and loading the exec-convention skill image"
ctx="$(mktemp -d)"
cp -a "${SKILL_SRC}/." "${ctx}/"
printf 'FROM scratch\nCOPY . /\n' > "${ctx}/Containerfile"
"${CONTAINER_TOOL}" build -t "${SKILL_IMG}" -f "${ctx}/Containerfile" "${ctx}" 2>&1 | tail -2 | sed 's/^/    /'
rm -rf "${ctx}"
cluster::load_image "${SKILL_IMG}"

# --- agent image -----------------------------------------------------------

if ! "${CONTAINER_TOOL}" image exists "${PR53_BUILT_IMG}" 2>/dev/null; then
    common::die "image ${PR53_BUILT_IMG} not built. Run, from the PR #53 worktree:
    make agent-java-build CONTAINER_TOOL=${CONTAINER_TOOL}"
fi
common::log "Retagging ${PR53_BUILT_IMG} -> ${PR53_AGENT_IMG} (avoids pullPolicy=Always)"
"${CONTAINER_TOOL}" tag "${PR53_BUILT_IMG}" "${PR53_AGENT_IMG}"
cluster::load_image "${PR53_AGENT_IMG}"
cluster::verify_image "${PR53_AGENT_IMG}" \
    || common::warn "agent image not visible to crictl; the pod may fail to start"

# --- apply -----------------------------------------------------------------

kubectl create secret generic anthropic-credentials \
    --from-literal=api-key="${KEY}" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
common::info "secret/anthropic-credentials applied"

# Target branch must differ from the source branch. Timestamp keeps reruns from
# colliding on an already-pushed branch.
TARGET_BRANCH="konveyor/exec-probe-$(date -u +%Y%m%d-%H%M%S)"
common::log "Target branch: ${TARGET_BRANCH}"

kubectl delete agentrun pr53-run --ignore-not-found --wait=true >/dev/null 2>&1 || true

sed -e "s|__LLM_MODEL__|${LLM_MODEL}|g" \
    -e "s|__AGENT_IMAGE__|${PR53_AGENT_IMG}|g" \
    -e "s|__APP_ID__|${APP_ID}|g" \
    -e "s|__TARGET_BRANCH__|${TARGET_BRANCH}|g" \
    "${REPO_ROOT}/hack/dev/resources/pr53-test.yaml" | kubectl apply -f -

# --- watch -----------------------------------------------------------------

common::log "Waiting for the sandbox pod"
POD=""
for _ in $(seq 1 60); do
    POD="$(kubectl get agentrun pr53-run -o jsonpath='{.status.sandboxName}' 2>/dev/null || true)"
    [ -n "${POD}" ] && kubectl get pod "${POD}" >/dev/null 2>&1 && break
    sleep 2
done
[ -n "${POD}" ] || { kubectl get agentrun pr53-run -o yaml | tail -30; common::die "no sandbox pod"; }

common::log "Following pod/${POD} (Ctrl-C to stop; the run continues)"
common::info "watch for: script_path=... which reveals where the model staged it"
kubectl logs -f "${POD}" -c agent 2>&1 | tee "${DEV_RESULTS_DIR}/pr53-run.log" || true

printf '\n'
common::log "Where did the model write?"
grep -aE "script_path=|VERIFY_START|VERIFY_OK" "${DEV_RESULTS_DIR}/pr53-run.log" 2>/dev/null | sed 's/^/    /' || \
    common::warn "no VERIFY markers found -- inspect ${DEV_RESULTS_DIR}/pr53-run.log"
