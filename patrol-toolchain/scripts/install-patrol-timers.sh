#!/usr/bin/env bash
# install-patrol-timers.sh — install the patrol-toolchain into systemd-user.
# Writes 4 unit files atomically, daemon-reloads, and enables --now both
# timers.
#
# Idempotent: rerunning is a no-op (cmp-skip on identical files; daemon-
# reload only if a unit actually changed; enable --now of already-enabled
# timer is a no-op in systemctl).
#
# Units installed:
#   maybe-patrol.service        — silence-gated deacon dispatcher (Type=oneshot)
#   maybe-patrol.timer          — fires every 15 min (OnCalendar=*:0/15)
#   witness-stale-check.service — per-rig polecat staleness probe (Type=oneshot)
#   witness-stale-check.timer   — fires every 5 min  (OnCalendar=*:0/5)
#
# Env:
#   PATROL_CITY  — absolute path to the city directory. Required.
#                  Baked into the generated unit files (ConditionPathExists,
#                  ExecStart, Environment=PATROL_CITY).
#
# Exit: 0 on success or no-op, 1 on failure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
# shellcheck source=../lib/systemd-user.sh
source "$SCRIPT_DIR/../lib/systemd-user.sh"

require_cmd systemctl awk

if [[ -z "${PATROL_CITY:-}" ]]; then
    die "PATROL_CITY env var must be set (absolute path to city dir)" 64
fi

CITY="$PATROL_CITY"
SCRIPT_BASE="$CITY/patrol-toolchain/scripts"

if [[ ! -x "$SCRIPT_BASE/maybe-patrol.sh" || ! -x "$SCRIPT_BASE/witness-stale-check.sh" ]]; then
    die "patrol-toolchain not deployed at $SCRIPT_BASE — copy this pack into \$PATROL_CITY/patrol-toolchain/ first" 1
fi

# Pull PATH from the gascity supervisor unit so our timers see the same
# binaries (gc, jq, dolt, etc.). Survives nix-store path changes — re-run
# the installer after a system rebuild to re-bake the new PATH.
SUPERVISOR_UNIT="$HOME/.local/share/systemd/user/gascity-supervisor.service"
if [[ ! -f "$SUPERVISOR_UNIT" ]]; then
    die "supervisor unit not found at $SUPERVISOR_UNIT — install gascity-supervisor first" 1
fi

SUPERVISOR_PATH=$(awk -F= '/^Environment=PATH=/{print $2; exit}' "$SUPERVISOR_UNIT" | tr -d '"')
if [[ -z "$SUPERVISOR_PATH" ]]; then
    die "could not extract Environment=PATH from $SUPERVISOR_UNIT (unit format unexpected)" 1
fi

log_info "extracted PATH from supervisor unit ($(printf '%s' "$SUPERVISOR_PATH" | wc -c) chars)"

MAYBE_PATROL_SERVICE="[Unit]
Description=Gascity deacon silence-gated patrol dispatcher
After=gascity-supervisor.service
ConditionPathExists=${CITY}

[Service]
Type=oneshot
ExecStart=${SCRIPT_BASE}/maybe-patrol.sh
Environment=BEADS_DOLT_AUTO_START=0
Environment=PATROL_CITY=${CITY}
Environment=PATH=${SUPERVISOR_PATH}
"

MAYBE_PATROL_TIMER="[Unit]
Description=Fire maybe-patrol every 15 minutes (silence-gated deacon dispatcher)

[Timer]
OnCalendar=*:0/15
Persistent=true
AccuracySec=30s
Unit=maybe-patrol.service

[Install]
WantedBy=timers.target
"

WITNESS_STALE_SERVICE="[Unit]
Description=Gascity per-rig witness staleness probe
After=gascity-supervisor.service
ConditionPathExists=${CITY}

[Service]
Type=oneshot
ExecStart=${SCRIPT_BASE}/witness-stale-check.sh
Environment=BEADS_DOLT_AUTO_START=0
Environment=PATROL_CITY=${CITY}
Environment=PATH=${SUPERVISOR_PATH}
"

WITNESS_STALE_TIMER="[Unit]
Description=Fire witness-stale-check every 5 minutes (per-rig polecat stuck-detection)

[Timer]
OnCalendar=*:0/5
Persistent=true
AccuracySec=30s
Unit=witness-stale-check.service

[Install]
WantedBy=timers.target
"

declare -A UNITS=(
  [maybe-patrol.service]="$MAYBE_PATROL_SERVICE"
  [maybe-patrol.timer]="$MAYBE_PATROL_TIMER"
  [witness-stale-check.service]="$WITNESS_STALE_SERVICE"
  [witness-stale-check.timer]="$WITNESS_STALE_TIMER"
)

UNIT_DIR="$HOME/.config/systemd/user"
changed=0

for unit_name in "${!UNITS[@]}"; do
    set +e
    write_unit_atomic "$UNIT_DIR/$unit_name" "${UNITS[$unit_name]}"
    rc=$?
    set -e
    case "$rc" in
        0) log_info "wrote $unit_name"; changed=1 ;;
        1) log_info "$unit_name unchanged" ;;
        *) die "write_unit_atomic returned unexpected rc=$rc for $unit_name" 1 ;;
    esac
done

if (( changed == 1 )); then
    log_info "daemon-reload (one or more units changed)"
    reload_user_daemon
else
    log_info "all units unchanged — skipping daemon-reload"
fi

enable_user_timer maybe-patrol.timer
enable_user_timer witness-stale-check.timer

log_info "install complete — current timer state:"
systemctl --user list-timers --all maybe-patrol.timer witness-stale-check.timer 2>&1
