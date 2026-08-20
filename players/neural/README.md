# Shared neural-ant policy

This directory is the reproducible learning artifact for the bundled Emerg-ant
player. `train.py` emits two representations of the same checkpoint:

- `checkpoint.json`: portable weights, dimensions, seed, training settings,
  and evaluation metrics;
- `../baseline/baseline/neural_ant_checkpoint.nim`: generated constants linked
  into the dependency-free tournament binary.

The model is a 182→48→14 tanh MLP shared by every active worker. Its input is a rotated
5×5×7 patch plus carry state, bite readiness, displacement from the body's own
wake point, distance from that point, and a sine/cosine clock. Output heads are
movement (9), pheromone (3), and bite (2). The model never receives the seat,
absolute coordinates, a predefined nest, or data from another container.
The queen is an explicit caste around that learned worker rule: the crown-marked
first seat holds its wake/nest position and contact-bites intruders. Dormant
policy connections run no body until stored food hatches them. A carrier follows
its own wake-displacement vector and lays the food channel; local wall/stall
escape can override that reflex, and no global nest coordinate is exposed.

## Reproduce

From the repository root:

```bash
python3 players/neural/train.py
nim c -d:release -r tests/test_neural_ant_policy.nim
```

The default run is deterministic with seed `260819`. It performs local-sensor
curriculum initialization and 20 REINFORCE updates in a compact two-colony
transfer world. The world includes distributed fruit, return-to-wake delivery,
two-channel pheromones, decay, a mid-episode wash, mirrored obstacles, and
contact attacks. Deterministic evaluation every five updates retains the best
checkpoint, preventing late policy-gradient regression. `--smoke` checks the pipeline quickly without replacing the
published files if `--output` and `--nim-output` point to temporary paths.

The JSON checkpoint records the transfer evaluation. It is a sanity check for
learning and serialization, not a claim that the simplified trainer is the
Coworld engine. Use the full-engine replay test below for final judgment.

## Full-engine comparison

```bash
players/neural/run_engine_smoke.sh build/neural-vs-heuristic.replay neural heuristic
```

This builds the real game and player, seats the neural policy as Red and the
v0.2 handwritten ablation as Blue, accelerates one 16-vs-16 episode, and saves
a normal replay plus server log. Swap the final arguments or run several seeds
before drawing a performance conclusion. The ablation is selected only by the
process environment variable `EMERG_ANT_POLICY=heuristic`; neural is default.

Set `SEED`, `MAX_TICKS`, and `WASH_TICK` to run reproducible multi-seed
gauntlets. The checked-in policy delivered fruit on pinned full-engine seeds
101, 202, 303, and 404; seed 404 required the longer 2400-tick horizon.

The most informative measurements are discovery time, food deliveries,
distance traveled per delivery, deposits by channel, recovery time after the
wash, and contact attacks near food or return trails. Final score alone hides
the emergent behavior the hackathon is about.
