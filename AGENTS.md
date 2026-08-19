# Agent operating guide — coworld-emerg-ant

Emerg-ant is a standalone competitive colony-foraging Coworld. Gameplay rules
live in `docs/EMERG_ANT.md`; the inherited engine reference is in
`docs/RULES.md`.

If the task is to create or improve an entrant rather than change the game,
follow `docs/BUILD_A_POLICY.md`. Keep policy experiments inside `players/` and
do not change simulation rules to make a policy stronger.

## Before editing

When an `origin/main` remote exists, fetch and bring the current branch up to
date before touching code. Preserve unrelated user changes.

```bash
git fetch origin
git rev-list --left-right --count HEAD...origin/main
git merge origin/main
```

## Gameplay and replay invariants

- `GameVersion` in `src/ctf/sim_types.nim` gates replay compatibility. Bump it
  for deterministic gameplay changes, check open branches for competing
  claims, and re-record every `.bitreplay` fixture.
- Flatty wire type field order is sacred. Append fields; never reorder them.
- Pheromone state is deterministic gameplay state in Emerg-ant mode. Preserve
  simultaneous cancellation, oldest-first capacity trimming, and hashing.
- Food returns are evaluated simultaneously. A tied same-tick goal is a draw;
  enum or player iteration order must never decide the winner.
- Bot observation labels are an API. Update the label contract, documentation,
  baseline consumer, and tests together when changing them.
- Keep `docs/ENV_VARIATION.md` current whenever configuration fields, map
  overrides, or gameplay constants change.

## Build and test

Run commands from the repository root. Heavy map tests require release mode.

```bash
nimby --global sync nimby.lock
nim c -d:release -r tests/tests.nim
```

Build the publishable package with the command in `README.md`. The manifest
must remain named `emerg-ant`, publish only the `emerg-ant` variant, and certify
with sixteen reference players in the ant ruleset.

## Important files

- `src/ctf/sim_types.nim` — constants, wire types, `GameVersion`.
- `src/ctf/sim.nim` — gameplay and step loop.
- `src/ctf/global.nim` — renderer and observation protocol.
- `src/ctf/arena.nim` — map geometry and validation.
- `coworld_manifest.json` — standalone publication manifest.
- `docs/BUILD_A_POLICY.md` — entrant build, test, upload, and submission guide.
- `tests/test_emerg_ant.nim` — mode behavior and determinism coverage.
