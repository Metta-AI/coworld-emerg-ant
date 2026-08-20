# Emerg-ant — competitive colony foraging

Emerg-ant is the multiplayer CoWorld mode built for the ERA @ ALIFE 2026
Emerg-ant hackathon. It turns the arena into a stigmergic food race: each bot is
an ant, each team is a colony, and the floor is shared memory.

The mode takes its constraint from [NAnts](https://github.com/ichko/nants):
individual ants repeat a small policy while colony behavior emerges from their
shared environment. Food location arrives as a colony-wide scent; obstacles,
other ants, contact threats, and the route itself still have to be discovered
and navigated locally. Both colonies can read every pheromone mark, and one
colony's fresh deposit erases opposing trail within 18 pixels.

## Win condition

- Gameplay is always one submitted policy versus one submitted policy. Softmax
  starts eight connected copies per colony, but only its queen and one founding
  worker are active at the beginning; six copies wait as dormant brood.
- Each queen is a large, winged ant fixed at her glowing nest. She is alive,
  visible, and can bite enemies touching her, but cannot move.
- Two neutral food patches begin at deterministic-random, walkable positions
  outside every nest. They are not owned by either colony.
- Every living ant smells every loose patch: its observation includes the
  patch's map position even outside visual range. Scent does not solve the path;
  the ant still has to search around walls and moving bodies to reach it.
- Touch either patch to carry it. Return it to your own glowing nest to score one
  forage point, feed the queen, and hatch one dormant copy of your policy. The
  patch immediately reappears at a different field position, so a memorized
  route cannot solve the episode.
- The first colony to five returns wins. Every round produces one winner. At a
  tied goal, mutual queen death, or the clock, the game compares food score,
  living ants, total colony health, and contact kills in that order. A still
  perfect tie uses replay-seed parity, which is deterministic and balanced
  across episode seeds.
- Kill the enemy queen and every ant in her colony dies. Workers do not respawn
  on a timer; only a living queen can replace one by receiving food. There are
  no guns, grenades, spray cans, shields, med kits, barriers, or bombardment: an
  ant can damage a rival only by holding A while their bodies physically touch.

The top-center score reads `RED FOOD 2/5`, and `captures` in results/replays is
the per-ant food-return count.

## Stigmergy

Every moving ant deposits one pheromone mark per second. Marks last 30 seconds:

- a small team-colored mark means an ordinary scouting trail;
- a larger bright-centered mark means the ant was carrying food;
- new opposing marks within 18 pixels cancel simultaneously;
- a surviving new mark erases older enemy trail in that radius;
- all pheromones are public, including through fog of war.

That last rule is deliberate: pheromones are environmental state, not private
team chat. A trail can coordinate your colony, reveal a successful enemy route,
or become bait.

Player observations expose stable sprite labels:

```text
pheromone red scout
pheromone blue food
food patch
food carried
weapon mandibles
queen red left
self queen red left
```

## Controls

- D-pad: move independently of aim.
- B / Select: rotate aim counter-clockwise / clockwise.
- A: bite. A mandible strike lands only while touching a living enemy and deals
  one damage, then waits for the configured attack cooldown.
- C: unused in Emerg-ant.

Movement, fog, replay, and Sprite v1 details not replaced above follow
[RULES.md](RULES.md) and [PROTOCOL.md](PROTOCOL.md). The original CTF weapon and
pickup rules remain available only when `gameMode` is `ctf`.

## Configuration

```json
{
  "gameMode": "emerg-ant",
  "forageGoal": 5
}
```

`gameMode: "ctf"` preserves the original capture-the-heart rules. The mode and
goal are replay-pinned. Emerg-ant rejects any `teams` value other than `2`.
Pheromone pacing, lifetime, erasure radius, brood cost, and starting colony
size are catalogued in [ENV_VARIATION.md](ENV_VARIATION.md).
