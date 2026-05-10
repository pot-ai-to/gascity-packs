# shellcheck shell=bash
# This file must be sourced, not executed.
#
# Minimal shared helpers for patrol-toolchain scripts. Provides logging +
# command-existence guards. Safe under `set -euo pipefail` (callers enable
# strict mode; this lib leaves it to them).

if [[ "${BASH_SOURCE[0]:-}" == "${0}" ]]; then
    echo 'lib/common.sh must be sourced' >&2
    exit 1
fi

_tool_name() {
    if [[ -n "${BASH_SOURCE[2]:-}" ]]; then
        basename "${BASH_SOURCE[2]}"
    else
        basename "${0:-patrol-toolchain}"
    fi
}

log_info() { printf '[%s] %s\n' "$(_tool_name)" "$*" >&2; }
log_warn() { printf '[%s] WARN: %s\n' "$(_tool_name)" "$*" >&2; }
log_err()  { printf '[%s] ERROR: %s\n' "$(_tool_name)" "$*" >&2; }

die() {
    log_err "$1"
    exit "${2:-1}"
}

require_cmd() {
    local missing=()
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if (( ${#missing[@]} > 0 )); then
        die "missing required command(s): ${missing[*]}" 64
    fi
}
