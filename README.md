# Emerg-ant

Emerg-ant is a competitive multiplayer Coworld built for the ERA @ ALIFE 2026
Emerg-ant hackathon. It is always a 1v1 policy duel: Softmax runs eight copies
of each submitted policy as one red or blue colony. Each colony begins with a
winged queen and one worker; the other copies wait as dormant brood.

> **Version note:** `main` contains the current GV53 foraging rules on the
> restored pre-NAnts engine. The
> NAnts-style v0.6 game remains available on the
> [`nants-v0.6`](https://github.com/Metta-AI/coworld-emerg-ant/tree/nants-v0.6)
> branch and the
> [`v0.6.0-nants`](https://github.com/Metta-AI/coworld-emerg-ant/tree/v0.6.0-nants)
> tag.

Opposing pheromones cancel or erase one another, so navigation changes as the
colonies move. Guns and items are removed; rivals can fight only by touching
and biting. Every living ant can smell the map position of available food, but
must navigate around the arena to find and touch it. Returning one food to the
queen hatches one dormant copy of that colony's policy. Kill the queen and her
colony collapses. The first colony to five deliveries wins; at the clock, a
unique score leader wins. Every league round has a winner: tied finishes
compare food, living ants, colony health, and contact kills, then use
replay-seed parity only if the colonies are still perfectly equal.

The design is inspired by [NAnts](https://github.com/ichko/nants) and the
[ERA @ ALIFE 2026 hackathon](https://emerging-researchers-alife.github.io/alife26-era-workshop/#hackathon).

See [docs/EMERG_ANT.md](docs/EMERG_ANT.md) for the complete rules and bot-facing
observation labels.

## Gameplay

[![Both colonies rush their nests at the start of a certified replay](docs/images/emerg-ant-nest-rush.png)](https://api.observatory.softmax-research.net/v2/coworlds/replays/static/cow_7b867933-3ba2-4e68-92c6-f120a804cf56/sha256%3A530db427227e6bc1af3f0bc11fb80fe08e6caf5682bdf00fc9ab00b16dfffcde/index.html?replay=https%3A%2F%2Fsoftmax-public.s3.amazonaws.com%2Freplays%2F07bb3467-e6ed-4d3d-bb54-32ff8ae18708.replay&v=2)

*The red and blue colonies leave their nests in the hosted certification replay.*

[![Ant colonies form competing public pheromone trails](docs/images/emerg-ant-pheromone-race.png)](https://api.observatory.softmax-research.net/v2/coworlds/replays/static/cow_7b867933-3ba2-4e68-92c6-f120a804cf56/sha256%3A530db427227e6bc1af3f0bc11fb80fe08e6caf5682bdf00fc9ab00b16dfffcde/index.html?replay=https%3A%2F%2Fsoftmax-public.s3.amazonaws.com%2Freplays%2F07bb3467-e6ed-4d3d-bb54-32ff8ae18708.replay&v=2)

*Public red and blue pheromones expose the routes each colony is building.*

## Published Coworld

- Version: `emerg-ant:0.7.0`
- Coworld ID: [`cow_7b867933-3ba2-4e68-92c6-f120a804cf56`](https://softmax.com/observatory/v2/coworlds/cow_7b867933-3ba2-4e68-92c6-f120a804cf56)
- Status: canonical and hosted-smoke certified
- Source: [Metta-AI/coworld-emerg-ant](https://github.com/Metta-AI/coworld-emerg-ant)
- Replay: [watch ladder round 72 produce a clear winner](https://api.observatory.softmax-research.net/v2/coworlds/replays/static/cow_7b867933-3ba2-4e68-92c6-f120a804cf56/sha256%3A530db427227e6bc1af3f0bc11fb80fe08e6caf5682bdf00fc9ab00b16dfffcde/index.html?replay=https%3A%2F%2Fsoftmax-public.s3.amazonaws.com%2Freplays%2F07bb3467-e6ed-4d3d-bb54-32ff8ae18708.replay&v=2)

## Competition league

- Public ladder: [softmax.com/emerg-ant](https://softmax.com/emerg-ant)
- League ID: `league_485b7b0a-5a52-4254-9b2b-1e10b9596941`
- Division: `Competition`
- Format: platform round-robin ladder; two or more entrants can fill the
  16-player roster through multiple seats
- Seed competitors: `emerg-ant-rival:v1` and
  `emerg-ant-rival-colony:v1`

The ladder is enabled and recurring hosted rounds are active. Submitted
policies are placed asynchronously and promoted to the entrant's active
champion when `--auto-champion always` is used.

To compete, start with [Build an Emerg-ant policy](docs/BUILD_A_POLICY.md).

## Run locally

Install the pinned Nim dependencies, then start the server:

```bash
nimby --global sync nimby.lock
nim c -d:release -r src/ctf.nim
```

The checked-in [config.json](config.json) launches a 1v1 policy match with eight
available seats per colony on the hand-tuned arena.

Run the tests from the repository root:

```bash
nim c -d:release -r tests/tests.nim
```

## Build the Coworld package

The standalone manifest publishes one variant, `emerg-ant`, and includes the
reference player image used by hosted certification.

```bash
uvx --from "coworld[auth]==0.1.34" coworld build \
  --version 0.7.0 \
  --project . \
  --compose compose.yaml \
  --template coworld_manifest.json \
  --output build/coworld-package/coworld_manifest.json
```

After authenticating with `softmax set-token`, upload the generated package:

```bash
uvx --from "coworld[auth]==0.1.34" coworld upload-coworld \
  build/coworld-package/coworld_manifest.json \
  --timeout-seconds 900 \
  --wait-hosted-smoke \
  --hosted-smoke-timeout-seconds 1800
```

## Architecture

- `src/ctf/sim_types.nim` — wire-stable types, constants, and `GameVersion`.
- `src/ctf/sim.nim` — food returns, scoring, pheromone dynamics, and gameplay.
- `src/ctf/global.nim` — ant, food, trail, HUD, and spectator rendering.
- `config.json` — local 1v1 policy / eight-seat-per-colony configuration.
- `coworld_manifest.json` — publishable Coworld manifest.
- `tests/test_emerg_ant.nim` — competitive-mode and determinism tests.

The engine retains its CTF-derived internals for replay and protocol
compatibility, but this repository publishes only the Emerg-ant ruleset.
