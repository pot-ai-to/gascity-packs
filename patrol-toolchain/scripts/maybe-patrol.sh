#!/usr/bin/env bash
# maybe-patrol.sh — silence-gated dispatcher for one-shot deacon patrol.
#
# Timer-driven (every 15 min). Single-flight, deduplicated, restore-on-exit.
#
# Logic:
#   1. flock single-flight    → exit 0 if another instance running
#   2. trap restore EXIT      → ALWAYS re-suspend deacon on exit (any signal)
#   3. dedup check            → exit 0 if a patrol fired in last 2h
#   4. silence check          → exit 0 if any bead.updated in last 30 min
#   5. wake deacon            → patrol-set.sh deacon false (TOML edit + reload)
#   6. sling patrol formula   → gc sling deacon mol-deacon-patrol-once --formula
#   7. bounded wait ≤ 10 min  → poll bead status until closed (or timeout)
#   8. re-suspend deacon      → patrol-set.sh deacon true (also via trap)
#   9. record fire timestamp  → for next-run dedup
#
# Env:
#   PATROL_CITY  — absolute path to the city directory. Required.

set -euo pipefail

if [[ -z "${PATROL_CITY:-}" ]]; then
    echo "[maybe-patrol] PATROL_CITY env var must be set" >&2
    exit 64
fi

CITY="$PATROL_CITY"
PATROL_SET="$CITY/patrol-toolchain/lib/patrol-set.sh"

if [[ ! -x "$PATROL_SET" ]]; then
    echo "[maybe-patrol] $(date -Iseconds) — patrol-set primitive not found at $PATROL_SET" >&2
    exit 1
fi

STATE_DIR="$CITY/.patrol-toolchain/state"
mkdir -p "$STATE_DIR"

LOCK="$STATE_DIR/maybe-patrol.lock"
LAST_FIRE="$STATE_DIR/last-deacon-fire"

SILENCE_THRESHOLD_SEC=$((30 * 60))   # 30 min — town considered active if any update inside this window
DEDUP_SEC=$((2 * 60 * 60))           # 2h — minimum gap between patrol fires
WAIT_TIMEOUT_SEC=$((10 * 60))        # 10 min — bounded wait for patrol bead to close

cd "$CITY"

# 1. Single-flight via flock — exit silently if another instance is running.
exec 9>"$LOCK"
if ! flock -n 9; then
    exit 0
fi

# 2. Restore-on-exit: re-suspend deacon if we exit at any point past the wake.
WOKEN=0
restore() {
    if [[ "$WOKEN" -eq 1 ]]; then
        bash "$PATROL_SET" deacon true 2>&1 \
            | sed 's/^/[maybe-patrol restore] /'
    fi
}
trap restore EXIT INT TERM

# 3. Dedup
if [[ -f "$LAST_FIRE" ]]; then
    last=$(cat "$LAST_FIRE")
    now=$(date +%s)
    if [[ $((now - last)) -lt "$DEDUP_SEC" ]]; then
        exit 0
    fi
fi

# 4. Silence check — gc events outputs JSONL.
silence_window="${SILENCE_THRESHOLD_SEC}s"
recent=$(gc events --since "$silence_window" --type bead.updated 2>/dev/null | head -n1 || true)
if [[ -n "$recent" ]]; then
    exit 0
fi

echo "[maybe-patrol] $(date -Iseconds) — silence threshold met, firing deacon patrol"

# 5. Wake deacon (toggle suspended → false in pack.toml + reload)
bash "$PATROL_SET" deacon false
WOKEN=1

# 6. Sling work. `gc sling` has no --json in v1.x; parse text output.
# Expected output begins with: 'Created hq-XXX — "..."' (the work bead id).
sling_out=$(gc sling deacon mol-deacon-patrol-once --formula 2>&1) || {
    echo "[maybe-patrol] sling failed: $sling_out" >&2
    exit 1
}

work_bead=$(echo "$sling_out" | grep -oE '^Created [a-z]{2}-[a-z0-9]{3,}' | head -n1 | awk '{print $2}')

if [[ -z "$work_bead" ]]; then
    work_bead=$(echo "$sling_out" | grep -oE '\b[a-z]{2}-[a-z0-9]{3,}\b' | head -n1)
fi

if [[ -z "$work_bead" ]]; then
    echo "[maybe-patrol] could not extract bead id from sling output:" >&2
    echo "$sling_out" >&2
    exit 1
fi

echo "[maybe-patrol] dispatched as bead $work_bead, waiting up to ${WAIT_TIMEOUT_SEC}s for completion"

# 7. Bounded wait for the bead to close
deadline=$(( $(date +%s) + WAIT_TIMEOUT_SEC ))
while [[ $(date +%s) -lt "$deadline" ]]; do
    status=$(gc bd show "$work_bead" --json 2>/dev/null | jq -r '.status // "unknown"' 2>/dev/null || echo unknown)
    if [[ "$status" = "closed" ]]; then
        echo "[maybe-patrol] bead $work_bead closed"
        break
    fi
    sleep 15
done

# 8. Re-suspend (the trap will also do this; redundant but explicit)
bash "$PATROL_SET" deacon true
WOKEN=0
trap - EXIT INT TERM

# 9. Record fire time for dedup
date +%s > "$LAST_FIRE"

echo "[maybe-patrol] $(date -Iseconds) — patrol complete"
