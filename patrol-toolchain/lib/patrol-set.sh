#!/usr/bin/env bash
# patrol-set.sh — toggle a patrol agent's `suspended` field in pack.toml /
# city.toml via atomic sed + tomllib validation + `gc supervisor reload`.
#
# Usage:
#   patrol-set.sh deacon  <true|false>             # city-scoped (pack.toml)
#   patrol-set.sh boot    <true|false>             # city-scoped (pack.toml)
#   patrol-set.sh witness <rig-name> <true|false>  # rig-scoped (city.toml)
#
# Env:
#   PATROL_CITY  — absolute path to the city directory containing pack.toml
#                  and city.toml. Required.
#
# Mechanism:
#   `gc agent suspend|resume` refuses pack-defined agents. We instead patch
#   the `suspended` field declaratively via [[patches.agent]] /
#   [[patches.named_agent]] blocks. This script flips that field in place,
#   validates the result, and reloads the supervisor.
#
# Preflight:
#   If `gc supervisor run` is not in the process table, the supervisor is
#   down. Mutating pack.toml / city.toml without a successful trailing
#   reload leaves the on-disk markers drifting from the supervisor's
#   in-memory snapshot — the next supervisor start picks up unintended
#   state. Detect early and exit 0 silently.
#
#   Exit-0 (not 1) is intentional: timer-driven callers treat any non-zero
#   from this script as "edit failed" and run cleanup logic. Nothing was
#   edited — this is a no-op, not a failure.
#
# Atomicity:
#   - Write to <file>.new.<pid>
#   - Validate via python3 tomllib
#   - Atomic mv only if validation passes
#   - `gc supervisor reload` last
#
# Idempotency:
#   - Pattern matches BOTH 'true' and 'false', replaces with DESIRED
#   - Re-running with the same DESIRED is a no-op (sed produces same content)
#
# Marker contract:
#   - city-scoped (deacon/boot): bare '# patrol-toggle:<name>'
#   - rig-scoped  (witness):     disambiguated '# patrol-toggle:witness:<rig>'
#   - This comment is the unique anchor; sed will not match anything else
#   - Do NOT remove the markers from pack.toml / city.toml

set -euo pipefail

AGENT="${1:-}"

if [[ -z "$AGENT" ]]; then
    echo "Usage:" >&2
    echo "  $0 deacon  <true|false>" >&2
    echo "  $0 boot    <true|false>" >&2
    echo "  $0 witness <rig-name> <true|false>" >&2
    exit 64
fi

case "$AGENT" in
    witness)
        RIG="${2:-}"
        DESIRED="${3:-}"
        if [[ -z "$RIG" || -z "$DESIRED" ]]; then
            echo "patrol-set: witness requires <rig> argument" >&2
            echo "  $0 witness <rig-name> <true|false>" >&2
            exit 64
        fi
        MARKER="patrol-toggle:witness:${RIG}"
        ;;
    deacon|boot)
        DESIRED="${2:-}"
        if [[ -z "$DESIRED" ]]; then
            echo "Usage: $0 $AGENT <true|false>" >&2
            exit 64
        fi
        MARKER="patrol-toggle:${AGENT}"
        ;;
    *)
        echo "patrol-set: unknown agent '$AGENT' (expected deacon, boot, witness)" >&2
        exit 64
        ;;
esac

if [[ "$DESIRED" != "true" && "$DESIRED" != "false" ]]; then
    echo "patrol-set: DESIRED must be 'true' or 'false', got '$DESIRED'" >&2
    exit 64
fi

# Preflight — see header for rationale.
if ! pgrep -f 'gc supervisor run' >/dev/null 2>&1; then
    echo "patrol-set: supervisor not running — refusing to flip ${MARKER}" >&2
    echo "patrol-set: nothing to honor a config reload; skipping" >&2
    exit 0
fi

if [[ -z "${PATROL_CITY:-}" ]]; then
    echo "patrol-set: PATROL_CITY env var must be set (absolute path to city dir)" >&2
    exit 64
fi

CITY="$PATROL_CITY"

case "$AGENT" in
    deacon|boot)  FILE="$CITY/pack.toml" ;;
    witness)      FILE="$CITY/city.toml" ;;
esac

if [[ ! -f "$FILE" ]]; then
    echo "patrol-set: target file not found: $FILE" >&2
    exit 1
fi

if ! grep -qE "^suspended = (true|false)   # ${MARKER}\$" "$FILE"; then
    echo "patrol-set: marker '# ${MARKER}' not found on a 'suspended =' line in $FILE" >&2
    echo "patrol-set: refusing to edit — marker may have been removed or rig is unknown" >&2
    exit 1
fi

TMP="${FILE}.new.$$"
trap 'rm -f "$TMP"' EXIT

# Separator '@' to avoid colliding with '|' (regex) and '#' (in marker text).
sed -E "s@^(suspended = )(true|false)(   # ${MARKER})\$@\\1${DESIRED}\\3@g" \
    "$FILE" > "$TMP"

if ! python3 -c "import tomllib; tomllib.load(open('$TMP', 'rb'))" 2>/dev/null; then
    echo "patrol-set: TOML validation failed for $TMP — refusing to swap" >&2
    echo "--- diff (rejected) ---" >&2
    diff -u "$FILE" "$TMP" >&2 || true
    exit 1
fi

if cmp -s "$FILE" "$TMP"; then
    rm -f "$TMP"
    trap - EXIT
    exit 0
fi

mv "$TMP" "$FILE"
trap - EXIT

if ! gc supervisor reload >/dev/null 2>&1; then
    echo "patrol-set: gc supervisor reload failed (file written, supervisor may be out of sync)" >&2
    exit 1
fi

if [[ "$AGENT" == "witness" ]]; then
    echo "patrol-set: ${RIG}/witness.suspended = $DESIRED ($FILE updated, supervisor reloaded)"
else
    echo "patrol-set: $AGENT.suspended = $DESIRED ($FILE updated, supervisor reloaded)"
fi
