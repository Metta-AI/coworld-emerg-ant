# Emerg-ant v0.4 — Two Brains, 32 Bodies

Emerg-ant is a competitive artificial-life Coworld for the ERA @ ALIFE 2026
Emerg-ant hackathon. Two policies each inhabit a colony of 16 independent ant
bodies. Every body runs another copy of the same policy image; no process is a
colony manager and no hidden state is shared between copies.

The experiment asks a compact question: can useful colony organization emerge
from local sensing, repeated rules, and marks left in the world?

The bundled starter instantiates that question as one shared trained MLP.
Each ant receives a rotated 5×5×7 neighborhood (walls, allies, enemies, food,
two friendly trail channels, rival trails), carry/bite state, displacement from
its own wake point, and a periodic clock. It does not receive a slot, absolute
coordinates, a hard-coded nest location, or another ant's memory. The network
produces movement, pheromone, and bite actions from identical weights in every
body. Expected steering preserves sustained task-directed motion; a wake-seeded
correlated random walk supplies uncued exploration, and local stall escape keeps
carriers moving around cover. Training and its portable checkpoint live under
`players/neural/`.

Every ant wakes on a symmetric 2×8 lattice inside its colony's scoring zone.
This makes “displacement from wake” truthfully mean “direction home,” as it
does in NAnts; the inherited CTF fan placed outer seats well away from a
compact nest and was incompatible with that local contract.

## Win condition and ecology

- Two neutral fruit patches begin at opposite sites in an eight-site interior
  circuit. Either colony may harvest either patch by touching it.
- An ant carries one item. Returning it to that ant's own endzone scores one
  forage point, empties the source patch, and starts its regrowth timer. When
  it regrows, that patch advances to the next walkable site, so colonies must
  continue exploring upper, lower, left, right, and center-field regions.
- The published variant regrows an empty patch after 240 ticks (10 seconds),
  ends when one colony reaches 10 deliveries, and seats 16 ants per colony.
- At the time limit a unique forage leader wins; equal scores draw.
- A colony also wins if contact combat leaves no enemy ants in play. Published
  ants have five lives, so biting disrupts the food race without replacing it.

The top score reads `RED FOOD 3/10`. Existing tournament results use each
ant's `captures` field for its delivered-food count.

## Stigmergy and disruption

Pheromones are actions, not an automatic movement exhaust:

- hold `B` to lay the colony's **home/scout** channel;
- hold `C` to lay the colony's **food** channel;
- each ant can add at most one mark every 24 ticks;
- marks live for 720 ticks (30 seconds);
- simultaneous opposing marks within 18 pixels cancel;
- a surviving fresh mark erases older enemy marks within that radius;
- at tick 1800 in the published match, rain clears the entire field once.

That wash is the resilience test. A colony that merely memorizes one mature
trail should collapse; a colony whose local rule keeps exploring and repairing
routes can recover.

Food patches and pheromones are visible only within `antSenseRadius` (180 px
in the published variant). Other ants use the ordinary vision cone, bubble,
walls, and fog. Static terrain stays map-absolute and known for Sprite v1
compatibility, but there is no global live resource or pheromone feed.

Policy-visible labels are:

```text
neutral food patch
neutral food carried
pheromone red scout
pheromone red food
pheromone blue scout
pheromone blue food
```

## Contact combat

There are no guns or combat pickups in Emerg-ant mode. A fresh `A` press bites
the nearest enemy whose body center is within `AntBiteRange` (18 px). Bites on
the same tick resolve from one post-movement snapshot, so mutual kills and
many-on-one attacks are possible without input-order advantage.

A successful bite deals `biteDamage` and starts `biteCooldownTicks`. Missing
at range spends no cooldown. Death loses carried food; its source patch starts
the ordinary regrowth timer.

## Controls

| Input | Meaning |
| --- | --- |
| D-pad | Move and point the ant's vision heading |
| A | Bite one enemy in physical contact |
| B | Deposit home/scout pheromone |
| C | Deposit food pheromone |
| Select | Reserved / no-op |

The CTF-derived engine remains available behind `gameMode: "ctf"`, where its
original aim, weapons, hearts, and pickups are unchanged.

## Published configuration

```json
{
  "gameMode": "emerg-ant",
  "minPlayers": 32,
  "forageGoal": 10,
  "foodRespawnTicks": 240,
  "pheromoneWashTick": 1800,
  "antSenseRadius": 180,
  "biteDamage": 1,
  "biteCooldownTicks": 18
}
```

All fields above are replay-pinned. The complete variation catalog is
[ENV_VARIATION.md](ENV_VARIATION.md), and the implementation contract is
[the v0.2 design](plans/2026-08-19-emerg-ant-v2-design.md).
