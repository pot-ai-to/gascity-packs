#!/usr/bin/env bash
# uninstall-patrol-timers.sh — symmetric reverse of install-patrol-timers.sh.
# Disables both timers, removes the 4 unit files from
# ~/.config/systemd/user/, daemon-reloads, and resets failed state.
#
# Idempotent: rerunning when nothing is installed is a graceful no-op.
#
# Exit: 0 on success or graceful no-op, 1 on real failure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
# shellcheck source=../lib/systemd-user.sh
source "$SCRIPT_DIR/../lib/systemd-user.sh"

TIMERS=(maybe-patrol.timer witness-stale-check.timer)
SERVICES=(maybe-patrol.service witness-stale-check.service)
UNIT_DIR="$HOME/.config/systemd/user"
ALL_UNITS=(maybe-patrol.timer maybe-patrol.service witness-stale-check.timer witness-stale-check.service)

for t in "${TIMERS[@]}"; do
    log_info "disabling $t"
    disable_user_timer "$t"
done

removed=0
for u in "${ALL_UNITS[@]}"; do
    if [[ -f "$UNIT_DIR/$u" ]]; then
        rm -f "$UNIT_DIR/$u"
        log_info "removed $UNIT_DIR/$u"
        removed=1
    else
        log_info "$u not present — skipping"
    fi
done

if (( removed == 1 )); then
    reload_user_daemon
else
    log_info "no unit files removed — skipping daemon-reload"
fi

for s in "${SERVICES[@]}"; do
    reset_failed_user "$s"
done

log_info "uninstall complete"

log_info "post-uninstall systemctl state:"
systemctl --user list-unit-files maybe-patrol.timer maybe-patrol.service \
                                  witness-stale-check.timer witness-stale-check.service 2>&1 \
    || log_info "(units fully removed — list-unit-files reports no matches)"
