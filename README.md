# gascity-packs (pot-ai-to)

A collection of opt-in operator-side [Gas City](https://github.com/gastownhall/gascity)
packs that run on top of the reference [gastown](https://github.com/gastownhall/gascity/tree/main/examples/gastown)
deployment. None of these packs require forking gascity or gastown — they
hook in through the existing pack import / `[[patches]]` mechanisms.

For the gascity model itself (cities, rigs, formulas, beads, runtime providers)
see the [Gas City README](https://github.com/gastownhall/gascity).

## Using a pack

Packs live next to your consuming workspace. A typical layout:

```text
your-city/
  pack.toml
  city.toml
packs/
  patrol-toolchain/    # pack from this repo
  ...
```

Inside your workspace `pack.toml`:

```toml
[imports.patrol-toolchain]
source = "../packs/patrol-toolchain"
```

Each pack ships its own README with prerequisites, import snippet, install
steps, and operational concerns.

## Packs in this repo

- **[`patrol-toolchain/`](patrol-toolchain/)** — operator-side "deadman switch"
  for gastown patrol agents (deacon, witness, boot). Suspends them by
  default; wakes them only when systemd-user timers detect silence in the
  town or staleness in a polecat. Cuts the idle-wake cost of always-on
  patrol sessions on Claude subscription tiers.

More packs to come as I extract them from my own deployment.

## Status

Everything in this repo is **operator-side tooling I wrote for my own
gascity deployment.** It works for me, but each pack ships with a
"Concerns" section in its README — failure modes I've identified but
haven't fully de-risked. Read those before copying a pack into your
setup. Issues and PRs welcome.

## Contributing

If you fix a bug or harden a concern, send a PR. When a pack's surface
changes, update its README in the same PR so the docs stay current with
the code.

## License

[MIT](LICENSE).
