#!/usr/bin/env bash
# Deploy Tackle Hub into the dev cluster and seed it with an Application.
#
#   hub.sh              deploy + wait + seed (idempotent)
#   hub.sh --deploy     deploy + wait only
#   hub.sh --seed       seed only (Hub must already be up)
#   hub.sh --app-id     print the seeded application's ID and exit
#
# The harness fetches application metadata and git credentials from Hub and
# refuses to start without HUB_BASE_URL and APP_ID, so a seeded Application is
# a prerequisite for any real agent run.
set -euo pipefail

# shellcheck source=hack/dev/env.sh
. "$(cd "$(dirname "$0")" && pwd)/env.sh"

HUB_MANIFEST="${REPO_ROOT}/hack/dev/resources/hub.yaml"
HUB_APP_NAME="${HUB_APP_NAME:-dev-app}"
HUB_IDENTITY_NAME="${HUB_IDENTITY_NAME:-dev-git}"
# A real, public, small Java app. Same repo hack/harness-test/resources.yaml
# uses. Note the agent cannot push here -- see hack/dev/pr53-test.sh.
HUB_REPO_URL="${HUB_REPO_URL:-https://github.com/savitharaghunathan/coolstore.git}"
HUB_REPO_BRANCH="${HUB_REPO_BRANCH:-main}"
HUB_LOCAL_PORT="${HUB_LOCAL_PORT:-18080}"
APP_ID_FILE="${REPO_ROOT}/.dev/hub-app-id"

cluster::exists || common::die "cluster '$(cluster::profile)' not found; run 'make dev-up' first"

deploy() {
    common::log "Deploying Tackle Hub"
    kubectl apply -f "${HUB_MANIFEST}"
    common::log "Waiting for Hub (first boot seeds the database; this is slow)"
    if ! kubectl wait deployment/tackle-hub --for=condition=Available --timeout=420s; then
        common::err "Hub did not become available"
        kubectl describe deployment/tackle-hub 2>&1 | tail -20
        kubectl logs deployment/tackle-hub --tail=40 2>&1 || true
        exit 1
    fi
}

# Port-forward so seeding can run on the host, where python3 is available for
# real JSON handling. The Hub image is ubi-minimal and ships no curl or jq, so
# seeding from inside the pod is not an option.
start_port_forward() {
    kubectl port-forward svc/tackle-hub "${HUB_LOCAL_PORT}:8080" >/dev/null 2>&1 &
    PF_PID=$!
    trap 'kill "${PF_PID}" 2>/dev/null || true' EXIT
    local i
    for i in $(seq 1 30); do
        if curl -sf "http://127.0.0.1:${HUB_LOCAL_PORT}/schema" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    common::die "Hub API did not respond on 127.0.0.1:${HUB_LOCAL_PORT}"
}

seed() {
    start_port_forward
    common::log "Seeding Hub"

    # A token for the Identity. The agent needs it to push; a public repo can
    # still be cloned without one, so a missing token is a warning not an error.
    local git_token git_user
    git_token="$(gh auth token 2>/dev/null || true)"
    git_user="$(gh api user -q .login 2>/dev/null || echo konveyor-dev)"
    if [ -z "${git_token}" ]; then
        common::warn "no 'gh auth token' available -- seeding a placeholder credential."
        common::warn "Cloning a public repo will work; pushing will not."
        git_token="placeholder-not-a-real-token"
    fi

    HUB_URL="http://127.0.0.1:${HUB_LOCAL_PORT}" \
    APP_NAME="${HUB_APP_NAME}" \
    IDENTITY_NAME="${HUB_IDENTITY_NAME}" \
    REPO_URL="${HUB_REPO_URL}" \
    REPO_BRANCH="${HUB_REPO_BRANCH}" \
    GIT_USER="${git_user}" \
    GIT_TOKEN="${git_token}" \
    python3 "${REPO_ROOT}/hack/dev/hub_seed.py" | tee "${APP_ID_FILE}.tmp"

    # hub_seed.py prints the app id on the last line.
    tail -1 "${APP_ID_FILE}.tmp" | tr -d '\r\n' > "${APP_ID_FILE}"
    rm -f "${APP_ID_FILE}.tmp"
    common::log "APP_ID=$(cat "${APP_ID_FILE}") written to ${APP_ID_FILE}"
}

case "${1:-all}" in
    --deploy) deploy ;;
    --seed)   seed ;;
    --app-id)
        [ -r "${APP_ID_FILE}" ] || common::die "no seeded app; run 'make dev-hub'"
        cat "${APP_ID_FILE}"
        ;;
    all)      deploy; seed ;;
    *)        common::die "unknown argument '${1}'" ;;
esac
