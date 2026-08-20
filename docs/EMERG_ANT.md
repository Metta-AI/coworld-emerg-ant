# Emerg-ant v0.6 — Two Queens, Growing Colonies

Emerg-ant is a competitive artificial-life Coworld for the ERA @ ALIFE 2026
Emerg-ant hackathon. Two policies each occupy 16 fixed seats. A match begins
with one crown-marked queen and seven workers per colony; the other connected
policy seats are dormant brood. Every active worker runs another copy of the
same policy image. Colony memory remains in the world, not in a manager.

The experiment asks a compact question: can useful colony organization emerge
from local sensing, repeated rules, and marks left in the world?

The bundled starter instantiates that question as one shared trained MLP plus
a minimal carrier reflex.
Each ant receives a rotated 5×5×7 neighborhood (walls, allies, enemies, food,
two friendly trail channels, rival trails), carry/bite state, displacement from
its own wake point, a periodic clock, and the bearing/intensity of globally
diffusing fruit odor. It does not receive a slot, absolute coordinates, a
hard-coded nest location, or another ant's memory. The network
produces movement, pheromone, and bite actions from identical weights in every
body. A carrier follows only its own wake displacement and lays the food trail;
it still relies on local wall sensing and stall escape, and receives no nest
coordinate or global path. Expected steering preserves sustained task-directed motion; a wake-seeded
correlated random walk supplies uncued exploration, and body-width antenna probes
start a persistent wall-following response when progress stalls. Training and its portable checkpoint live under
`players/neural/`.

Every seat has a distinct wake point on a symmetric 2×8 lattice inside its
colony's nest. Founders wake there at kickoff; brood hatch there later.
This makes “displacement from wake” truthfully mean “direction home,” as it
does in NAnts; the inherited CTF fan placed outer seats well away from a
compact nest and was incompatible with that local contract.

## Win condition and ecology

- Two neutral fruit patches begin at a random rot180-paired pair of eight
  distributed interior sites. Either colony may harvest either patch by touching it.
- An ant carries one item. Returning it to that ant's own endzone scores one
  delivery, adds one food to the colony store, empties the source patch, and
  starts its regrowth timer. When it regrows, replay-deterministic randomness
  selects another unoccupied site, so food keeps popping up across the arena.
- A queen reserves her last food ration. Every two surplus deliveries spend two units to
  hatch a dormant policy seat as a new worker. Never-hatched seats are chosen
  before previously killed workers.
- The queen first becomes hungry after 1,800 ticks (75 seconds), then every 1,440
  ticks (60 seconds). Each check consumes one stored food. With no food she
  starves, and if combat kills her the same collapse occurs immediately.
- Queen loss eliminates every worker in that colony. Emerg-ant does not use the
  inherited per-player lives setting: a worker death is permanent until food
  funds another hatch.
- The published variant regrows an empty patch after 240 ticks (10 seconds),
  ends when one colony reaches 5 deliveries, and reserves 16 policy seats per
  colony.
- At the time limit a unique forage leader wins; equal scores draw.
- A colony also wins when the enemy queen dies or starves.

The top score reads `FOOD 3/5 · STORE 1`; the queen and active brood count are
also carried in replay state. Existing tournament results retain the internal
`captures` field name solely as a compatibility container for deliveries.

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

Every living ant smells the location of every currently available food patch.
The bundled controller reduces this to an egocentric bearing and a
distance-compressed intensity. Exact local patch contact, pheromones, and other
ants remain bounded by `antSenseRadius` (180 px in the published variant),
ordinary vision, walls, and fog. The replay's ANT SENSE inset visualizes that
same split: distant food on the antenna rim, with exact local detail inside.

Policy-visible labels are:

```text
neutral food patch
neutral food carried
neutral food carrier glow
queen red left|right
queen blue left|right
self queen red left|right
self queen blue left|right
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

The old CTF engine remains available only as a separate compatibility mode; it
is not part of an Emerg-ant match or its fiction.

## Published configuration

```json
{
  "gameMode": "emerg-ant",
  "minPlayers": 32,
  "forageGoal": 5,
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
