# Per-team handicaps

## Goal

Let each team carry a single **handicap** scalar in `0.0 .. 1.0` that weakens
that team by a smoothly-interpolated bundle of effects. The Campaign league
brain sets a dominating team's handicap up to make lopsided matches fun again;
map authors and experiments can set it directly. CTF owns the mechanic (how a
handicap maps to gameplay); Campaign only chooses the number.

- `handicap = 0.0` → normal settings, **byte-identical to today**.
- `handicap = 1.0` → 50% of shots miss, 1 life, 1 hit point, half max speed.
- Values between interpolate linearly from the config's own base values toward
  the `h = 1` floor.

## Interpolation

Given a team's handicap `h` (stored as an integer permille `p = round(h*1000)`,
`0..1000`) and the game's base config values:

| effect     | h = 0          | h = 1              | formula (integer)                                  |
|------------|----------------|--------------------|----------------------------------------------------|
| miss rate  | 0%             | 50%                | drop a would-be hit when `rand(999) < p div 2`     |
| lives      | `cfg.lives`    | 1                  | `max(1, cfg.lives - (cfg.lives-1)*p div 1000)`     |
| hit points | `cfg.hitPoints`| 1                  | `max(1, cfg.hitPoints - (cfg.hitPoints-1)*p div 1000)` |
| max speed  | `cfg.maxSpeed` | `cfg.maxSpeed div 2` | `cfg.maxSpeed * (2000 - p) div 2000`             |

`accel`, `gunRange`, `fireCooldown`, vision, and every other knob are
untouched: a handicap only dials the four levers above.

## Why integer permille (determinism)

`maxSpeed` is recomputed every movement tick and the miss roll fires per shot;
both feed the hashed simulation. Floating-point interpolation would risk a
one-ULP divergence between the native recorder and the wasm replay viewer —
the exact silent team-unfairness `AGENTS.md` warns about. So the handicap is
converted from its authored `0..1` float to an integer permille **once at
config parse**, and every in-sim derivation is pure integer arithmetic. The
authored float is bit-identical on both platforms (same JSON string), so the
one parse-time `round` is safe.

## Config surface

`GameConfig` gains `handicaps*: array[Team, int]` (permille, `0..1000`,
default 0). Authored as a per-team float map:

```json
{ "handicaps": { "red": 0.0, "blue": 0.6 } }
```

Omitted teams and the whole omitted block default to 0. `update()` parses the
float map into permille; `validate()` bounds each authored value to `[0,1]`;
`configJson()` echoes only the non-zero teams (as floats), so a default game's
replay config is unchanged. Inactive teams (index `>= config.teams`) are
ignored, like `slots`.

## Read sites (accessor-routed)

Three pure accessors on `GameConfig` (`sim_types.nim`, beside `teamText`):
`livesFor`, `hitPointsFor`, `maxSpeedFor`, plus `missPermilleFor`. Each returns
the exact base value when the team's permille is 0 (no arithmetic, no drift).

- HP: `sim.nim` startGame spawn, respawn, med-kit heal cap; `roster.nim` join.
- Lives: `sim.nim` startGame; `roster.nim` join.
- Max speed: `sim.nim` movement update (before carrier scaling).
- Miss: new gated roll in `selectFireTarget` (gun only; spray unchanged),
  drawn only when the shooter's permille > 0 so the RNG stream is untouched at
  `h = 0`.
- HP bar render (`global.nim`, broadcast-only): max-HP denominator moves
  per-player so a handicapped team's bar scales to its own max.

## No GameVersion bump / no fixture regen

`GameVersion` gates changes that alter deterministic re-simulation of existing
replays. Old replays carry no `handicaps` key → all permille 0 → every
accessor returns the base value and the miss roll draws no RNG → byte-identical
gameHash. The committed `.bitreplay` fixtures (JSON config + inputs + hash
checkpoints) re-simulate clean. Guarded by the existing `test_replay` "hashes
match" test plus a new default-equivalence test.
