#!/usr/bin/env bash
# witness-stale-check.sh — per-rig polecat staleness detector.
#
# Timer-driven (every 5 min). For each rig, finds in-progress polecat-routed
# beads whose UpdatedAt is >15 min stale. If found, fires
# mol-witness-patrol-once for that rig. Per-rig dedup of 20 min.
#
# Same flock / trap / atomic-toggle pattern as maybe-patrol.sh.
#
# Env:
#   PATROL_CITY  — absolute path to the city directory. Required.

set -euo pipefail

if [[ -z "${PATROL_CITY:-}" ]]; then
    echo "[witness-stale-check] PATROL_CITY env var must be set" >&2
    exit 64
fi

CITY="$PATROL_CITY"
PATROL_SET="$CITY/patrol-toolchain/lib/patrol-set.sh"

STATE_DIR="$CITY/.patrol-toolchain/state"
mkdir -p "$STATE_DIR"

LOCK="$STATE_DIR/witness-stale.lock"

STALENESS_SEC=$((15 * 60))    # 15 min — polecat hasn't moved
DEDUP_SEC=$((20 * 60))        # 20 min — per-rig refire gap
WAIT_TIMEOUT_SEC=$((10 * 60)) # 10 min — bounded wait for witness bead

if [[ ! -x "$PATROL_SET" ]]; then
    echo "[witness-stale-check] $(date -Iseconds) — patrol-set primitive not found at $PATROL_SET" >&2
    exit 1
fi

cd "$CITY"

exec 9>"$LOCK"
if ! flock -n 9; then
    exit 0
fi

WOKEN_RIG=""
restore() {
    if [[ -n "$WOKEN_RIG" ]]; then
        bash "$PATROL_SET" witness "$WOKEN_RIG" true 2>&1 \
            | sed 's/^/[witness-stale restore] /'
    fi
}
trap restore EXIT INT TERM

# GNU date and BSD date differ — try GNU first, fall back to BSD.
cutoff_iso=$(date -u -d "@$(($(date +%s) - STALENESS_SEC))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -v-${STALENESS_SEC}S +%Y-%m-%dT%H:%M:%SZ)

gc rig list --json 2>/dev/null | jq -r '.rigs[] | select(.hq != true) | .name' | while read -r rig; do
    [[ -z "$rig" ]] && continue

    last_fire_file="$STATE_DIR/last-witness-fire-${rig//\//_}"

    if [[ -f "$last_fire_file" ]]; then
        last=$(cat "$last_fire_file")
        if [[ $(( $(date +%s) - last )) -lt "$DEDUP_SEC" ]]; then
            continue
        fi
    fi

    # Find any in-progress bead in this rig assigned to a polecat-pattern
    # agent whose UpdatedAt is older than cutoff.
    stale=$(gc bd list --status=in_progress --json --limit=0 2>/dev/null \
        | jq -r --arg rig "$rig" --arg cutoff "$cutoff_iso" '
            .[]
            | select(.assignee != null)
            | select(.assignee | contains("polecat") and startswith($rig))
            | select(.updated_at < $cutoff)
            | .id' \
        | head -n1)

    if [[ -z "$stale" ]]; then
        continue
    fi

    echo "[witness-stale-check] $(date -Iseconds) — rig=$rig has stale bead $stale"

    bash "$PATROL_SET" witness "$rig" false
    WOKEN_RIG="$rig"

    # Qualified name for rig-scoped pack agent.
    sling_out=$(gc sling "$rig/gastown.witness" mol-witness-patrol-once --formula 2>&1) || {
        echo "[witness-stale-check] sling failed for $rig: $sling_out" >&2
        continue
    }

    work_bead=$(echo "$sling_out" | grep -oE '^Created [a-z]{2}-[a-z0-9]{3,}' | head -n1 | awk '{print $2}')
    if [[ -z "$work_bead" ]]; then
        work_bead=$(echo "$sling_out" | grep -oE '\b[a-z]{2}-[a-z0-9]{3,}\b' | head -n1)
    fi

    if [[ -n "$work_bead" ]]; then
        deadline=$(( $(date +%s) + WAIT_TIMEOUT_SEC ))
        while [[ $(date +%s) -lt "$deadline" ]]; do
            status=$(gc bd show "$work_bead" --json 2>/dev/null | jq -r '.status // "unknown"' 2>/dev/null || echo unknown)
            [[ "$status" = "closed" ]] && break
            sleep 15
        done
    fi

    bash "$PATROL_SET" witness "$rig" true
    WOKEN_RIG=""

    date +%s > "$last_fire_file"

    echo "[witness-stale-check] $(date -Iseconds) — witness patrol complete for $rig"
done

trap - EXIT INT TERM
