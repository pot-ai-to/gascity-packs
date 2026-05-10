# Patches to add to your gastown city

The patrol-toolchain works by toggling the `suspended` field on
gastown's pack-defined patrol agents. To make those fields exist (so
the toolchain has something to flip), add the following blocks.

The trailing `# patrol-toggle:<name>` comments are **load-bearing** —
`patrol-set.sh` uses them as sed anchors. Don't change the spacing
("`true   # patrol-toggle…`" — three spaces between `true` and `#`)
and don't strip the comments.

## In `pack.toml` (city-scoped agents)

```toml
[[patches.agent]]
name = "deacon"
suspended = true   # patrol-toggle:deacon

[[patches.agent]]
name = "boot"
suspended = true   # patrol-toggle:boot
```

`deacon` is woken by `maybe-patrol.timer` on a silence gate.
`boot` is suspended by default but never woken automatically — wake it
manually if you want it to run a watchdog cycle.

## In `city.toml` (rig-scoped agents — one block per rig)

```toml
[[patches.named_agent]]
rig = "your-rig-name"
agent = "witness"
suspended = true   # patrol-toggle:witness:your-rig-name
```

Repeat for every rig you have. The marker is **disambiguated by rig
name** — `patrol-toggle:witness:dendri`, `patrol-toggle:witness:foo`,
etc. — so multi-rig setups can flip each rig's witness independently.

## After editing

```sh
gc supervisor reload
```

Then verify the agents picked up `suspended = true`:

```sh
gc agent list --json | jq '.[] | select(.name | contains("witness") or contains("deacon") or contains("boot")) | {name, suspended}'
```
