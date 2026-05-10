# patrol-toolchain

Operator-side **"deadman switch"** for gastown patrol agents (deacon,
witness, boot). Suspends them by default and wakes them on-demand via
systemd-user timers. **Zero changes to gascity or gastown source** —
hooks in through the existing `[[patches.agent]]` /
`[[patches.named_agent]]` mechanism.

> **Status:** sanity-check requested. Works on my deployment; see
> [Concerns](#concerns) before copying it into yours.

## Why

Gastown declares `mayor`, `deacon`, `boot`, and per-rig `witness` as
`mode = "always"` named sessions. Each is a real Claude Code process
that wakes on every supervisor nudge — bead updates, mail, witness
health checks, timer callbacks. In a multi-rig city that's many
always-on sessions, all waking on the same events.

Even a "nothing to do" turn loads the agent's prompt template + recent
context. That's a billable turn every time, on every session. On Claude
subscription tiers, idle background reasoning can eat a real chunk of the
5-hour message budget before any polecat gets dispatched. On lower tiers
it can starve the budget entirely. On the API it's real $$ 24/7.

The patrol-toolchain flips the economics: patrol agents stay suspended
by default; two systemd-user timers wake them only when there's a real
silence or staleness signal.

## What it does

- **`maybe-patrol.timer`** — every 15 min. If `gc events --since 30m
  --type bead.updated` shows the town is silent, un-suspend deacon,
  sling `mol-deacon-patrol-once`, wait ≤10 min for the bead to close,
  re-suspend. 2-hour dedup, single-flight via flock,
  trap-restored on any exit signal.
- **`witness-stale-check.timer`** — every 5 min. Iterates
  `gc rig list --json`. For each rig, finds in-progress polecat-routed
  beads with `updated_at` older than 15 min. If any, un-suspend that
  rig's witness, sling `mol-witness-patrol-once`, wait, re-suspend.
  20-min per-rig dedup.

Worst case in an idle town: ~12 deacon wakes/day. In an active town:
silence gate suppresses deacon completely; witness only fires for
actually stale work.

## Layout

```
patrol-toolchain/
  pack.toml
  lib/
    patrol-set.sh        # atomic-TOML-toggle primitive
    common.sh            # log_*/die/require_cmd helpers
    systemd-user.sh      # write_unit_atomic + enable/disable/reload
  scripts/
    maybe-patrol.sh             # deacon dispatcher (silence-gated)
    witness-stale-check.sh      # witness dispatcher (per-rig)
    install-patrol-timers.sh    # systemd-user unit installer
    uninstall-patrol-timers.sh  # symmetric reverse
    status-patrol-timers.sh     # read-only health check
  examples/
    pack-toml-additions.md      # patches to add to your pack.toml/city.toml
```

## Install

1. **Copy the pack into your city dir.** The dispatchers expect to
   find each other at `$PATROL_CITY/patrol-toolchain/...`.

   ```sh
   export PATROL_CITY="$HOME/cities/<your-city>"
   cp -a patrol-toolchain "$PATROL_CITY/"
   chmod +x "$PATROL_CITY/patrol-toolchain/scripts/"*.sh \
            "$PATROL_CITY/patrol-toolchain/lib/patrol-set.sh"
   ```

2. **Add the `[[patches]]` blocks** to your `pack.toml` and
   `city.toml`. See [`examples/pack-toml-additions.md`](examples/pack-toml-additions.md)
   for the exact text. The trailing `# patrol-toggle:<name>` comments
   are load-bearing sed anchors — don't change spacing or strip them.

3. **Reload the supervisor** so the new `suspended = true` patches
   take effect:

   ```sh
   gc supervisor reload
   ```

4. **Install the timers:**

   ```sh
   PATROL_CITY="$HOME/cities/<your-city>" \
     bash "$PATROL_CITY/patrol-toolchain/scripts/install-patrol-timers.sh"
   ```

5. **Verify:**

   ```sh
   PATROL_CITY="$HOME/cities/<your-city>" \
     bash "$PATROL_CITY/patrol-toolchain/scripts/status-patrol-timers.sh"
   ```

   Should report both timers active and exit 0.

## Uninstall

```sh
bash "$PATROL_CITY/patrol-toolchain/scripts/uninstall-patrol-timers.sh"
```

This removes the systemd units but leaves the `suspended = true`
patches in your `pack.toml` / `city.toml` — the patrol agents will
stay asleep until you remove those blocks and reload.

## Requirements

- gascity v1.x with `[[patches.agent]]` / `[[patches.named_agent]]`
  support
- Linux with systemd-user (the toolchain is timer-driven)
- `gc`, `jq`, `python3` (for `tomllib`), `flock`, `awk`, `sed` in
  PATH (the installer pulls PATH from the gascity-supervisor unit so
  the timers see the same binaries gascity does)
- A running `gc supervisor run` — `patrol-set.sh` refuses to mutate
  config files when the supervisor is down

## Concerns

I have open questions about whether this is the right shape. If you
copy it, you might run into:

1. **State drift between disk and supervisor.** The
   `pgrep`-supervisor preflight catches the obvious case. Reload
   races, crashes mid-reload, and partial writes might still cause
   drift. I haven't fully characterised those modes.
2. **Silence-oracle fragility.** `gc events --since 30m --type
   bead.updated` is the only signal. If event filter semantics change
   in a future gascity version, the silence gate fails open or fails
   closed — silently.
3. **Witness staleness is a jq scrape.** Brittle to assignee-format
   changes and any future "in-progress sub-state" gascity adds.
4. **Marker comments are load-bearing.** Reformat `pack.toml` and
   drop a `# patrol-toggle:deacon` and sed quietly no-ops — deacon
   stays asleep forever, no error.
5. **10-min bounded wait.** If a patrol formula doesn't close its
   bead in 10 min, the trap re-suspends mid-patrol.
6. **Suspended ≠ torn down.** The claude-code processes still live in
   their tmux panes; only the supervisor's nudges stop. Memory and
   descriptors aren't reclaimed.

If you've got opinions or war stories, I'd love to hear them in
issues / discussions.
