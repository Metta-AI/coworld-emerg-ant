# Emerg-ant

Emerg-ant is a competitive artificial-life Coworld for the
[ERA @ ALIFE 2026 Emerg-ant hackathon](https://emerging-researchers-alife.github.io/alife26-era-workshop/#hackathon).
Two policies each inhabit 16 identical ant bodies. The replicas forage finite
neutral food, coordinate through locally sensed pheromones, recover after rain
erases the shared trail field, and attack enemies only through physical
contact.

The v0.3 package keeps the v0.2 ecology and replaces its scripted starter with
a learned NAnts-style controller. One shared 182→24→14 MLP is copied into all
16 bodies. Each copy sees only a rotated 5×5 local patch, carried-food and bite
state, displacement from its own wake point, and a clock. Discrete turns are
sampled from the learned policy with a replay-deterministic private random
stream. There is no slot feature, absolute position, predefined nest location,
pathfinder, global live-resource feed, or cross-container communication.

Read the [complete v0.2 rules](docs/EMERG_ANT.md) or
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
| sampled left/straight/right turn | sampled stay/eight-way turn, pheromone, and bite heads |
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
a two-colony transfer world containing food, carrying, trail decay, a wash,
mirrored obstacles, and contact attacks. The checked-in seed-260819 run used 20
policy-gradient updates; its reproducible 32-episode evaluation delivered food
in 50% of episodes. A subsequent full-engine 16-vs-16 smoke ended with a
learned colony returning food to its nest. See [players/neural](players/neural/README.md) for the
checkpoint contract and experiment commands.

## Gameplay images

[![Both colonies rush their nests in the v0.1 certification replay](docs/images/emerg-ant-nest-rush.png)](https://api.observatory.softmax-research.net/v2/coworlds/replays/static/cow_82623c46-cd6a-4e39-a271-5874949d10ff/sha256%3Aed94ce9c56ea236611adce265668a5968f2d4c4bd96bb04c5df51fc83629efea/index.html?replay=https%3A%2F%2Fsoftmax-public.s3.amazonaws.com%2Freplays%2F1cee985b-7ec8-41a0-aa1b-b17462a3da19.replay&v=2)

*The original v0.1 8-vs-8 replay. v0.2 keeps the ant arena presentation but
replaces enemy caches and ranged CTF combat with neutral ecology.*

[![Ant colonies form competing pheromone trails](docs/images/emerg-ant-pheromone-race.png)](https://api.observatory.softmax-research.net/v2/coworlds/replays/static/cow_82623c46-cd6a-4e39-a271-5874949d10ff/sha256%3Aed94ce9c56ea236611adce265668a5968f2d4c4bd96bb04c5df51fc83629efea/index.html?replay=https%3A%2F%2Fsoftmax-public.s3.amazonaws.com%2Freplays%2F1cee985b-7ec8-41a0-aa1b-b17462a3da19.replay&v=2)

*The v0.1 public trail field. In v0.2 B/C choose the channel and each policy
sees only nearby marks.*

## Published Coworld

- Current hosted rules release: `emerg-ant:0.2.0`
- Coworld ID: `cow_0cc30e03-77d3-4960-8426-372927038b89`
- Source: [Metta-AI/coworld-emerg-ant](https://github.com/Metta-AI/coworld-emerg-ant)
- v0.2 replay: [watch the certified match](https://api.observatory.softmax-research.net/v2/coworlds/replays/static/cow_0cc30e03-77d3-4960-8426-372927038b89/sha256%3Ab6d11dc478d534483720fc276e49df174cb65b1761ccc7268630e322dd6624c5/index.html?replay=https%3A%2F%2Fsoftmax-public.s3.amazonaws.com%2Freplays%2F5ae546d3-2872-4929-9f92-8f80d77f2533.replay&v=2)

The v0.3 publication keeps these v0.2 game rules and upgrades the bundled
starter policy; its hosted replay will be linked after certification.

## Competition league

League promotion requires a Softmax team administrator. A team admin can
create it with:

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

- `src/ctf/sim_types.nim` — replay contract, v0.2 constants, and `GameVersion`.
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
