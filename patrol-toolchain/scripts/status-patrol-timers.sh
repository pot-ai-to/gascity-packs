#!/usr/bin/env bash
# status-patrol-timers.sh — read-only status of the patrol timer pair.
#
# Reports:
#   - systemctl --user list-timers for both patrol timers (NEXT/LEFT/LAST)
#   - last 5 journalctl --user lines per .service unit
#   - lock + last-fire markers under $PATROL_CITY/.patrol-toolchain/state/
#
# Env:
#   PATROL_CITY  — absolute path to the city directory. Required.
#
# Exit:
#   0 if both timers active (waiting),
#   1 if either is inactive / not-found / failed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

if [[ -z "${PATROL_CITY:-}" ]]; then
    die "PATROL_CITY env var must be set" 64
fi

TIMERS=(maybe-patrol.timer witness-stale-check.timer)
SERVICES=(maybe-patrol.service witness-stale-check.service)
state_dir="$PATROL_CITY/.patrol-toolchain/state"

log_info "===== systemctl --user list-timers ====="
systemctl --user list-timers --all maybe-patrol.timer witness-stale-check.timer 2>&1 || true

for s in "${SERVICES[@]}"; do
    log_info "===== journalctl --user -u $s -n 5 ====="
    journalctl --user -u "$s" -n 5 --no-pager 2>&1 || true
    echo
done

log_info "===== state-dir markers ($state_dir) ====="
if [[ ! -d "$state_dir" ]]; then
    log_warn "state dir does not exist: $state_dir"
else
    for f in maybe-patrol.lock witness-stale.lock last-deacon-fire; do
        path="$state_dir/$f"
        if [[ -e "$path" ]]; then
            mtime=$(stat -c '%y' "$path" 2>/dev/null || stat -f '%Sm' "$path" 2>/dev/null || echo "?")
            log_info "  $f  (mtime $mtime)"
        else
            log_info "  $f  (absent)"
        fi
    done

    if compgen -G "$state_dir/last-witness-fire-*" > /dev/null; then
        for f in "$state_dir"/last-witness-fire-*; do
            [[ -e "$f" ]] || continue
            mtime=$(stat -c '%y' "$f" 2>/dev/null || stat -f '%Sm' "$f" 2>/dev/null || echo "?")
            log_info "  $(basename "$f")  (mtime $mtime)"
        done
    else
        log_info "  last-witness-fire-*  (no per-rig markers yet)"
    fi
fi

log_info "===== exit-code computation ====="
final_rc=0
for t in "${TIMERS[@]}"; do
    state=$(systemctl --user is-active "$t" 2>&1 || true)
    if [[ "$state" == "active" ]]; then
        log_info "  $t = active"
    else
        log_warn "  $t = $state (NOT healthy)"
        final_rc=1
    fi
done

if (( final_rc == 0 )); then
    log_info "both timers healthy — exit 0"
else
    log_warn "one or more timers unhealthy — exit 1"
fi

exit "$final_rc"
