#!/usr/bin/env bash
# Apply the dev CR fixtures.
#
#   apply.sh              apply
#   apply.sh --reset      delete first, then apply (fresh run)
#   apply.sh --emulator   use the keyless LLM emulator instead of a real key
#
# LLM credentials: by default this wires up a REAL Anthropic provider from
# $ANTHROPIC_API_KEY. The key is read from the environment and written straight
# to a Secret -- it is never written to a file in the repo, and no fixture
# contains it.
set -euo pipefail

# shellcheck source=hack/dev/env.sh
. "$(cd "$(dirname "$0")" && pwd)/env.sh"

RESOURCES="${REPO_ROOT}/hack/dev/resources"
RESET=0
USE_EMULATOR=0
for arg in "$@"; do
    case "$arg" in
        --reset)    RESET=1 ;;
        --emulator) USE_EMULATOR=1 ;;
        *) common::die "unknown argument: $arg" ;;
    esac
done

cluster::exists || common::die "cluster '$(cluster::profile)' not found; run 'make dev-up' first"

if [ "${RESET}" = 1 ]; then
    common::log "Deleting existing dev resources"
    kubectl delete -f "${RESOURCES}/resources.yaml" --ignore-not-found --wait=true 2>/dev/null || true
    kubectl delete -f "${RESOURCES}/playbook.yaml" --ignore-not-found --wait=true 2>/dev/null || true
fi

# --- credentials -----------------------------------------------------------

if [ "${USE_EMULATOR}" = 1 ]; then
    common::log "Using the LLM emulator (keyless)"
    ENDPOINT="http://openai-emulator.default.svc"
    MODEL="test-model"
    API_KEY="emulator-key-not-real"
else
    # Fall back to a key file, then to .env. Exported env vars do not survive
    # between separate shell invocations, so reading from a gitignored file is
    # the practical way to hand the key over once and reuse it.
    KEY_FILE="${DEV_KEY_FILE:-${REPO_ROOT}/.dev/anthropic.key}"
    if [ -z "${ANTHROPIC_API_KEY:-}" ] && [ -r "${KEY_FILE}" ]; then
        ANTHROPIC_API_KEY="$(tr -d '\r\n' < "${KEY_FILE}")"
        common::info "read key from ${KEY_FILE}"
    fi
    # .env, tolerating an optional `export ` prefix and surrounding quotes.
    if [ -z "${ANTHROPIC_API_KEY:-}" ] && [ -r "${REPO_ROOT}/.env" ]; then
        ANTHROPIC_API_KEY="$(sed -nE 's/^[[:space:]]*(export[[:space:]]+)?ANTHROPIC_API_KEY=["'"'"']?([^"'"'"']*)["'"'"']?[[:space:]]*$/\2/p' \
            "${REPO_ROOT}/.env" | head -1 | tr -d '\r\n')"
        [ -n "${ANTHROPIC_API_KEY}" ] && common::info "read key from .env"
    fi

    if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
        common::err "No Anthropic API key found."
        common::err "  export ANTHROPIC_API_KEY=sk-ant-..."
        common::err "  or write it to ${KEY_FILE} (gitignored)"
        common::err "  or use the emulator:  make dev-apply DEV_APPLY_ARGS=--emulator"
        exit 1
    fi
    common::log "Using the real Anthropic API"
    ENDPOINT="${DEV_LLM_ENDPOINT:-https://api.anthropic.com}"
    MODEL="${DEV_LLM_MODEL:-claude-sonnet-4-5}"
    API_KEY="${ANTHROPIC_API_KEY}"
fi

common::info "endpoint: ${ENDPOINT}"
common::info "model:    ${MODEL}"

# --dry-run=client | apply keeps this idempotent without needing delete-first.
kubectl create secret generic dev-llm-credentials \
    --from-literal=api-key="${API_KEY}" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
common::info "secret/dev-llm-credentials applied"

# --- resources -------------------------------------------------------------

common::log "Applying dev resources"
# Pipe through sed rather than sed -i: BSD requires an argument to -i, GNU
# requires there not to be one.
sed -e "s|__LLM_ENDPOINT__|${ENDPOINT}|g" \
    -e "s|__LLM_MODEL__|${MODEL}|g" \
    -e "s|__AGENT_IMAGE__|${DEV_AGENT_IMG}|g" \
    "${RESOURCES}/resources.yaml" | kubectl apply -f -

sed -e "s|__LLM_MODEL__|${MODEL}|g" \
    "${RESOURCES}/playbook.yaml" | kubectl apply -f -

printf '\n'
common::log "Applied"
kubectl get llmprovider,skillcard,agent,agentrun 2>/dev/null || true

printf '\n'
common::info "NOTE: the LLMProvider verification Job only checks REACHABILITY."
common::info "It sends 'Authorization: Bearer' while Anthropic expects 'x-api-key',"
common::info "so even a wrong key returns 401 -- which the controller accepts as"
common::info "reachable. A bad key will go Ready here and only fail once an agent"
common::info "actually talks to the model."
