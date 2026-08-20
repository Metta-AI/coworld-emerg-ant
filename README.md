# Emerg-ant

Emerg-ant is a competitive artificial-life Coworld for the
[ERA @ ALIFE 2026 Emerg-ant hackathon](https://emerging-researchers-alife.github.io/alife26-era-workshop/#hackathon).
Two policies each inhabit 16 identical ant bodies. The replicas forage finite
neutral food, coordinate through locally sensed pheromones, recover after rain
erases the shared trail field, and attack enemies only through physical
contact.

The current source extends the v0.2 ecology and replaces its scripted starter with
a stronger NAnts-style controller. One shared 182→48→14 MLP is copied into all
16 bodies. Each copy sees only a rotated 5×5 local patch, carried-food and bite
state, displacement from its own wake point, and a private-phase clock. Learned
movement distributions become smooth expected steering for food and homing;
uncued ants use a wake-seeded correlated random walk and local collision escape.
There is no slot feature, absolute position, predefined nest location, pathfinder,
global live-resource feed, or cross-container communication.

Read the [complete v0.4 rules](docs/EMERG_ANT.md) or
[build a colony policy](docs/BUILD_A_POLICY.md).

## What to present at the hackathon

**Two Brains, 32 Bodies** is both the demo and the experiment:

1. Start a 16-vs-16 replay and show identical policy replicas dispersing from
   each nest.
2. Follow the first food discovery as C-marked return trails recruit other
   locally sensing ants.
3. Show congestion, enemy trail cancellation, and contact-only fights around
   a finite patch—coordination and conflict arise from the same local rule.
4. At 1:15, rain removes every pheromone. Compare each colony's recovery time
   and the routes that re-emerge.
5. End on the Softmax replay/league page: participants can fork the starter,
   upload one policy image, and watch 16 replicas compete as a colony.

The research artifact is not merely the score. It is the relationship between
a local controller, the stigmergic field it constructs, and colony resilience
when that field is disturbed.

## How this relates to NAnts

This is now substantively NAnts-like, while not claiming to be a fork:

| NAnts | Emerg-ant |
| --- | --- |
| shared neural rule across ants | the same checked-in MLP across 16 containers |
| local patch + wake displacement + clock | rotated 5×5×7 patch + the same private scalars |
| sampled left/straight/right turn | learned eight-way steering, pheromone, and bite heads |
| learned writes and turns | learned scout/food deposits, movement, and contact attack |
| one colony on a wrapping cellular field | two adversarial colonies in a physical arena |

The meaningful extension is competitive ALife: two learned crowds alter a
shared external memory, erase one another's marks, race finite food, survive a
global trail wash, and can kill only on bodily contact. The engine is still
CTF-derived infrastructure; the submitted behavior is not CTF logic.

## Train the shared policy

NumPy is the only training dependency. The fixed seed regenerates both the
portable JSON checkpoint and the Nim constants compiled into the container:

```bash
python3 players/neural/train.py
nim c -d:release -r tests/test_neural_ant_policy.nim
```

Training begins with a varied local-sensor curriculum, then uses REINFORCE in
a two-colony transfer world containing distributed fruit, carrying, trail decay,
a wash, mirrored obstacles, and contact attacks. Evaluation selects the best
self-play checkpoint instead of blindly keeping the final update. The checked-in
seed-260819 run delivered fruit in all 32 deterministic evaluation episodes,
averaging 5.125 deliveries. Four pinned full-engine 16-vs-16 seeds all harvested
and returned fruit. See [players/neural](players/neural/README.md) for the
checkpoint contract and experiment commands.

## Gameplay images

[![Both colonies rush their nests in the v0.1 certification replay](docs/images/emerg-ant-nest-rush.png)](https://api.observatory.softmax-research.net/v2/coworlds/replays/static/cow_82623c46-cd6a-4e39-a271-5874949d10ff/sha256%3Aed94ce9c56ea236611adce265668a5968f2d4c4bd96bb04c5df51fc83629efea/index.html?replay=https%3A%2F%2Fsoftmax-public.s3.amazonaws.com%2Freplays%2F1cee985b-7ec8-41a0-aa1b-b17462a3da19.replay&v=2)

*The original v0.1 8-vs-8 replay. v0.2 keeps the ant arena presentation but
replaces enemy caches and ranged CTF combat with neutral ecology.*

[![Ant colonies form competing pheromone trails](docs/images/emerg-ant-pheromone-race.png)](https://api.observatory.softmax-research.net/v2/coworlds/replays/static/cow_82623c46-cd6a-4e39-a271-5874949d10ff/sha256%3Aed94ce9c56ea236611adce265668a5968f2d4c4bd96bb04c5df51fc83629efea/index.html?replay=https%3A%2F%2Fsoftmax-public.s3.amazonaws.com%2Freplays%2F1cee985b-7ec8-41a0-aa1b-b17462a3da19.replay&v=2)

*The v0.1 public trail field. In v0.2 B/C choose the channel and each policy
sees only nearby marks.*

## Published Coworld

- Current hosted release: `emerg-ant:0.3.0`
- Coworld ID: `cow_8da8a524-da76-42ec-92d5-d1141add7427`
- Source: [Metta-AI/coworld-emerg-ant](https://github.com/Metta-AI/coworld-emerg-ant)
- v0.3 replay: [watch the certified learned-colony match](https://api.observatory.softmax-research.net/v2/coworlds/replays/static/cow_8da8a524-da76-42ec-92d5-d1141add7427/sha256%3A8d94af4f50c34a04d538c2dd5648540a37168fa4134e9fd868fc8e5c70fea378/index.html?replay=https%3A%2F%2Fsoftmax-public.s3.amazonaws.com%2Freplays%2F8b842013-3750-422b-a9aa-a216ded202f3.replay&v=2)

This release passed every hosted certification step and five hosted smoke
episodes.

## Competition league

League promotion requires a Softmax team administrator. The current publisher
can upload Coworlds but does not have that permission. A team admin can create
the league with:

```bash
uvx --from "coworld[auth]" coworld league create \
  emerg-ant emerg-ant "Emerg-ant" \
  --default-variant emerg-ant --json
```

The returned identifier gives the public league URL:

```text
https://softmax.com/observatory?tab=coworlds&logscope=league:<LEAGUE_ID>&detail=league:<LEAGUE_ID>
```

Until promotion, find the game in the
[Softmax Coworld Observatory](https://softmax.com/observatory?tab=coworlds).

## Run locally

```bash
nimby --global sync nimby.lock
nim c -d:release -r src/ctf.nim
```

The checked-in [config.json](config.json) launches 32 players, alternating 16
red and 16 blue seats. Run the full test suite from the repository root:

```bash
nim c -d:release -r tests/tests.nim
```

## Build the Coworld package

```bash
uvx --from "coworld[auth]" coworld build \
  --version 0.3.0 \
  --project . \
  --compose compose.yaml \
  --template coworld_manifest.json \
  --output build/coworld-package/coworld_manifest.json
```

After authenticating with `softmax login`, upload and wait for hosted smoke:

```bash
uvx --from "coworld[auth]" coworld upload-coworld \
  build/coworld-package/coworld_manifest.json \
  --timeout-seconds 900 \
  --wait-hosted-smoke \
  --hosted-smoke-timeout-seconds 1800
```

## Architecture

- `src/ctf/sim_types.nim` — replay contract, Emerg-ant constants, and `GameVersion`.
- `src/ctf/sim.nim` — neutral food, scoring, explicit trails, wash, and bites.
- `src/ctf/global.nim` — ant/food/trail rendering and local observations.
- `players/baseline/baseline/neural_ant.nim` — shared MLP inference and turns.
- `players/neural/train.py` — reproducible local curriculum + REINFORCE.
- `players/neural/checkpoint.json` — portable trained checkpoint and metrics.
- `config.json` / `coworld_manifest.json` — local and hosted 32-seat variants.
- `tests/test_emerg_ant.nim` — ecology, locality, combat, and determinism tests.

The engine retains CTF-derived replay and protocol infrastructure, and ordinary
`gameMode: "ctf"` behavior remains available for compatibility. This repository
publishes only the Emerg-ant ruleset.
