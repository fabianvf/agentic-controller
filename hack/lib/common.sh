# shellcheck shell=bash
# Shared helpers for hack/ scripts. Source, do not execute.
#
# Portability: these run on macOS (bash 3.2, BSD userland) and Linux (bash 5,
# GNU userland). Avoid: declare -A, mapfile, ${v,,}, sed -i, readlink -f,
# base64 -w0, timeout, grep -P, date -d, stat -c, nproc, sort -V, echo -e.

# Guard against double-sourcing.
[ -n "${__KONVEYOR_COMMON_SH:-}" ] && return 0
__KONVEYOR_COMMON_SH=1

common::log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
common::info() { printf '    %s\n' "$*"; }
common::warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
common::err()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; }
common::die()  { common::err "$*"; exit 1; }

common::have() { command -v "$1" >/dev/null 2>&1; }

common::require_cmd() {
    local missing=0 c
    for c in "$@"; do
        if ! common::have "$c"; then
            common::err "required command not found: $c"
            missing=1
        fi
    done
    [ "$missing" = 0 ] || exit 1
}

# Repo root, without readlink -f (absent on older BSD).
common::repo_root() {
    local d
    d="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    printf '%s\n' "$d"
}

# Single source of truth for container tool detection. The Makefile and the
# hack/ scripts each used to do this independently, with different defaults --
# the Makefile defaulted to docker even on machines that only have podman.
common::container_tool() {
    if [ -n "${CONTAINER_TOOL:-}" ]; then
        printf '%s\n' "${CONTAINER_TOOL}"
        return 0
    fi
    if common::have podman; then
        printf 'podman\n'
    elif common::have docker; then
        printf 'docker\n'
    else
        common::die "neither podman nor docker found"
    fi
}
