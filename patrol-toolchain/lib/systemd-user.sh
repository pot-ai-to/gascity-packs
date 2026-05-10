# shellcheck shell=bash
# This file must be sourced, not executed.
#
# systemd-user unit-file helpers. Safe under `set -euo pipefail` (callers
# enable strict mode; this lib leaves it to them).
#
# Provides:
#   write_unit_atomic UNIT_PATH CONTENTS
#       Write CONTENTS to UNIT_PATH via atomic temp + rename. Skip the
#       rename if cmp -s shows the contents are byte-identical (idempotent).
#       rc 0 = wrote (caller should daemon-reload)
#       rc 1 = no change (caller can skip daemon-reload)
#       rc 1 is informational, NOT an error. Under `set -e`, callers must
#       consume it explicitly:
#           if write_unit_atomic "$path" "$body"; then changed=1; fi
#         or
#           write_unit_atomic "$path" "$body" || true
#
#   enable_user_timer  UNIT_NAME    — `systemctl --user enable --now UNIT`
#   disable_user_timer UNIT_NAME    — `systemctl --user disable --now UNIT`
#   reload_user_daemon              — `systemctl --user daemon-reload`
#   reset_failed_user UNIT_NAME     — best-effort `reset-failed`
#
# Depends on `die` / `log_*` from lib/common.sh — callers must source
# common.sh before this library.

if [[ "${BASH_SOURCE[0]:-}" == "${0}" ]]; then
    echo 'lib/systemd-user.sh must be sourced' >&2
    exit 1
fi

write_unit_atomic() {
    local unit_path="$1"
    local contents="$2"
    local tmp="${unit_path}.new.$$"

    mkdir -p "$(dirname "$unit_path")"
    printf '%s' "$contents" > "$tmp"

    if [[ -f "$unit_path" ]] && cmp -s "$unit_path" "$tmp"; then
        rm -f "$tmp"
        return 1
    fi

    mv "$tmp" "$unit_path"
    return 0
}

enable_user_timer() {
    local unit="$1"
    if ! systemctl --user enable --now "$unit" 2>&1; then
        die "failed to enable --now $unit" 1
    fi
}

disable_user_timer() {
    local unit="$1"
    systemctl --user disable --now "$unit" 2>&1 || true
}

reload_user_daemon() {
    if ! systemctl --user daemon-reload 2>&1; then
        die "systemctl --user daemon-reload failed" 1
    fi
}

reset_failed_user() {
    local unit="$1"
    systemctl --user reset-failed "$unit" 2>/dev/null || true
}
