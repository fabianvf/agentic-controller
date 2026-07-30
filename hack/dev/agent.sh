#!/usr/bin/env bash
# Interact with the sandbox pod for an AgentRun.
#
#   agent.sh logs    follow the agent container's logs
#   agent.sh shell   open an interactive shell in the agent container
#   agent.sh name    print the sandbox pod name
#
# Set AGENT_RUN to target a different run (default: dev-run).
set -euo pipefail

# shellcheck source=hack/dev/env.sh
. "$(cd "$(dirname "$0")" && pwd)/env.sh"

sandbox_pod() {
    local name
    name="$(kubectl get agentrun "${AGENT_RUN}" -o jsonpath='{.status.sandboxName}' 2>/dev/null || true)"
    if [ -z "${name}" ]; then
        common::err "AgentRun '${AGENT_RUN}' has no sandboxName yet."
        common::err "Check it exists and is progressing:  kubectl get agentrun ${AGENT_RUN} -o yaml"
        exit 1
    fi
    printf '%s\n' "${name}"
}

case "${1:-logs}" in
    name)
        sandbox_pod
        ;;
    logs)
        pod="$(sandbox_pod)"
        common::log "Following logs for pod/${pod} (AgentRun ${AGENT_RUN})"
        kubectl logs -f "${pod}" -c agent
        ;;
    shell)
        pod="$(sandbox_pod)"
        common::log "Opening a shell in pod/${pod} (AgentRun ${AGENT_RUN})"
        common::info "try: ls -l /opt/skills/ ; grep skills /proc/self/mountinfo"
        # sh, not bash: the agent base is ubi-minimal.
        kubectl exec -it "${pod}" -c agent -- sh
        ;;
    *)
        common::die "unknown command '${1}' (logs|shell|name)"
        ;;
esac
