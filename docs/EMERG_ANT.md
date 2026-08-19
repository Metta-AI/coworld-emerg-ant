# Emerg-ant — competitive colony foraging

Emerg-ant is the multiplayer CoWorld mode built for the ERA @ ALIFE 2026
Emerg-ant hackathon. It turns the arena into a stigmergic food race: each bot is
an ant, each team is a colony, and the floor is shared memory.

The mode takes its constraint from [NAnts](https://github.com/ichko/nants):
individual ants act from local perception while the colony's durable behavior
emerges through a shared field. Here that field is competitive. Both colonies
can read every pheromone mark, and one colony's fresh deposit erases opposing
trail within 18 pixels.

## Win condition

- Two colonies field eight ants each in the supplied `config.json`.
- Every nest owns a replenishing food cache. Touch the enemy cache to carry it.
- Return carried food to your own glowing nest to score one forage point. The
  stolen cache immediately regrows, so routes and defenses must adapt.
- The first colony to five returns wins. If time expires, the unique score
  leader wins; a tied clock or simultaneous tied goal is a draw.
- A colony also wins by eliminating every opposing ant. Ants have five lives in
  the hackathon configuration, so combat disrupts foraging without replacing it.

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
food red cache
food blue carried
```

## Controls

- D-pad: move independently of aim.
- B / Select: rotate aim counter-clockwise / clockwise.
- A: fire paint; a hit interrupts a route by killing the carrier and returning
  its food to the source nest.
- C: charge and throw a carried grenade.

All movement, fog, weapons, pickups, replay, and Sprite v1 details not replaced
above follow [RULES.md](RULES.md) and [PROTOCOL.md](PROTOCOL.md).

## Configuration

```json
{
  "gameMode": "emerg-ant",
  "forageGoal": 5
}
```

`gameMode: "ctf"` preserves the original capture-the-heart rules. The mode and
goal are replay-pinned. Pheromone pacing, lifetime, erasure radius, and capacity
are catalogued in [ENV_VARIATION.md](ENV_VARIATION.md).

