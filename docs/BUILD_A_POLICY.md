# Build an Emerg-ant policy

One submitted policy image is replicated across a colony's 16 seats. Each
container receives only its own Sprite v1 observation and sends one input
mask. There is no shared process, shared memory, or colony-wide observation.
Coordination must survive that boundary.

## 1. Start from the reference policy

Read the [v0.4 rules](EMERG_ANT.md), [Sprite protocol](PROTOCOL.md), and the
shared network in
[`neural_ant.nim`](../players/baseline/baseline/neural_ant.nim). The observation
adapter and explicit handwritten ablation are in
[`baseline.nim`](../players/baseline/baseline.nim). The rest
of the baseline contains reusable websocket, delta-frame, walkability, and
pathfinding code inherited from CTF; its gun and flag strategy is inactive in
Emerg-ant mode.

The mode-specific object labels are:

```text
neutral food patch
neutral food carried
pheromone red scout
pheromone red food
pheromone blue scout
pheromone blue food
bite ready
bite cooldown
```

Food and pheromone objects disappear when outside the ant's 180 px sensing
radius. Other ants disappear outside normal fog/vision. Sprite frames are
deltas: retain an object until the server deletes or clears it.

The input mask is:

| Bit | Input | action |
| ---: | --- | --- |
| 0 | Up | move north |
| 1 | Down | move south |
| 2 | Left | move west |
| 3 | Right | move east |
| 5 | A | fresh press: contact bite |
| 6 | B | hold: home/scout pheromone |
| 7 | C | hold: food pheromone |

Select is reserved. Movement also points the ant's vision cone. A bite is
edge-triggered, so release A before trying again.

## 2. Design a local rule

A useful first controller needs four states, whether they are hand-authored,
learned, or recurrent:

1. **Explore:** disperse when no local food evidence exists; lay B so a loaded
   ant can orient toward home without a global nest beacon.
2. **Recruit:** follow locally sensed friendly food marks outward. Do not assume
   the oldest or strongest trail still reaches stocked food.
3. **Return:** while carrying, navigate home and lay C. Nearby replicas can
   reinforce the route without reading the carrier's private state.
4. **Contest:** bite only at contact where removing an enemy protects food or a
   return path. Chasing kills away from the ecology usually loses the race.

The fruit patches advance through eight distributed sites as they regrow, and
the mid-match wash deliberately destroys mature trails. Keep an exploration
probability, recurrent uncertainty, or another recovery mechanism that can
find newly stocked regions and rebuild information after tick 1800.

All 16 containers run identical code. The reference network deliberately has
no slot feature. Its private random stream is seeded from its own wake point,
which breaks clone symmetry without assigning roles or a commander.

## 3. Train a turn rule

The bundled checkpoint is reproducible:

```bash
python3 players/neural/train.py
```

This rewrites `players/neural/checkpoint.json` and the generated Nim checkpoint
compiled into the image. Use `--smoke` while editing the training loop. The
three output heads choose movement (stay + eight egocentric directions), mark
(none/scout/food), and bite (no/yes).

The default seed uses local curriculum initialization followed by REINFORCE in
a competitive transfer world. Improve the objective, observation channels, or
optimizer, but keep training inputs aligned with the deployed local contract.
Do not smuggle absolute coordinates, the seat number, or another container's
state into training-only features.

## 4. Implement and build

Fork the repository. Either replace the checkpoint/trainer, edit the ant
observation adapter, add modules under
`players/baseline/baseline/`, or copy the complete baseline player directory
and point its Dockerfile at your new entrypoint.

Keep policy behavior deterministic for a given observation history and seat.
Do not depend on process start order, wall-clock timing, another container's
filesystem, or an external coordinator.

```bash
docker build --platform linux/amd64 \
  -f players/baseline/Dockerfile \
  -t emerg-ant-policy:dev .
```

The image must start the player from `CMD` or `ENTRYPOINT`; the supplied image
runs `/bin/baseline` and reads `COWORLD_PLAYER_WS_URL`.

For the v0.2 handwritten comparison, set `EMERG_ANT_POLICY=heuristic`. It is an
ablation only; the default container runs the learned checkpoint.

## 5. Test complete colonies

Run engine/protocol tests first:

```bash
nimby --global sync nimby.lock
nim c -d:release -r tests/tests.nim
```

Then scrimmage the image in the published Coworld and verify its replay:

```bash
uvx --from "coworld[auth]" coworld scrimmage \
  cow_8da8a524-da76-42ec-92d5-d1141add7427 \
  emerg-ant-policy:dev \
  --variant emerg-ant \
  --output-dir build/scrimmage \
  --verify-replay
```

For several seeds, measure:

- food discovery time, deliveries, and stock lost to duplicate arrivals;
- path length before and after recruitment;
- useful B/C deposits, cancellations, and time to recover after the wash;
- carrier survival and contact attacks near food/return routes;
- crowding, deadlocks, idle time, and dependence on a single replica.

Compare behavior, not only final score. The ALife contribution is the local
rule and the colony-level pattern it produces.

## 6. Upload and submit

```bash
uvx --from "coworld[auth]" softmax login
uvx --from "coworld[auth]" coworld upload-policy \
  emerg-ant-policy:dev --name YOUR_POLICY_NAME

uvx --from "coworld[auth]" coworld submit \
  YOUR_POLICY_NAME:v1 \
  --league LEAGUE_ID \
  --no-open-browser
```

Submit the immutable uploaded version that produced your reviewed replay. The
league URL format is:

```text
https://softmax.com/observatory?tab=coworlds&logscope=league:<LEAGUE_ID>&detail=league:<LEAGUE_ID>
```

League creation still requires a Softmax team administrator; the repository
README carries the admin command and current publication status.
