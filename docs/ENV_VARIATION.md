# Environment Variation Catalog

Every knob that changes what a level looks like or plays like — for procedurally
generating new levels / curricula. Two kinds of knobs:

- **`GameConfig` fields** — league-settable per game via JSON (`src/ctf/sim_config.nim`).
  This is the primary variation surface (~40 fields + `mapGen` + `slots[]`).
- **Compile-time consts** (`src/ctf/sim_types.nim`) — the defaults those fields
  fall back to, plus tuning constants that are *not* individually config-exposed
  but define the gameplay envelope. Varying these needs a code change (and usually
  a GameVersion bump if they enter `gameHash`).

Key files: [`src/ctf/sim_types.nim`](../src/ctf/sim_types.nim) (types + consts),
[`src/ctf/sim_config.nim`](../src/ctf/sim_config.nim) (config lifecycle/validation/JSON),
[`src/ctf/arena.nim`](../src/ctf/arena.nim) (maps + procedural generator),
[`src/ctf/map_pool.nim`](../src/ctf/map_pool.nim) (curated seeds),
[`src/ctf/roster.nim`](../src/ctf/roster.nim) (team/seat assignment),
[`src/ctf/sim.nim`](../src/ctf/sim.nim) (item spawn placement).

Struct: `GameConfig` at [sim_types.nim:828](../src/ctf/sim_types.nim#L828).
Defaults: `defaultGameConfig()` [sim_config.nim:10](../src/ctf/sim_config.nim#L10).
JSON read: `update()` [sim_config.nim:385](../src/ctf/sim_config.nim#L385).
Validation: `validate()` [sim_config.nim:295](../src/ctf/sim_config.nim#L295).
Serialize: `configJson()` [sim_config.nim:482](../src/ctf/sim_config.nim#L482).

Legend: **JSON key** is the config-file key when it differs from the field name.
Bounds are enforced by `validate()` unless noted "(gen)" = checked inside the map
generator.

---

## Map selection & generation — the richest variation surface

Pick an arena with `mapPath`, then (for `gen`/`pool`) shape terrain with `mapSeed`
+ the `mapGen` overrides.

| Field | Type / default | JSON key | Bounds | Effect |
|---|---|---|---|---|
| `mapPath` | string / `"arena"` | `map`, `mapPath` | resolved | Which arena: `"arena"`, `"arena-large"` (hand-authored), `"gen"` (procedural), `"pool"` (curated seeds). |
| `mapSeed` | int / `-1` | `mapSeed` | -1 = derive from game `seed` | Terrain seed for gen/pool maps. |
| `mapPoolIndex` | int / `-1` | `mapPoolIndex` | -1 = `mapSeed mod 20` | Explicit pool pick (pool = 20 seeds, `map_pool.nim:5`). |
| `mapGen` | `MapGenOverrides` | (per-field below) | per-field | Per-parameter generator locks. |
| `mapSpec` | string / `""` | `mapSpec` | must be JSON object | Frozen expanded geometry for replay determinism; **derived**, filled at parse, not authored. |

### `MapGenOverrides` — the procedural terrain knobs

Definition [sim_types.nim:796](../src/ctf/sim_types.nim#L796). Zero/`-1`/`""` value =
"unlocked, draw from seed". Validated inside `generateMapAttempt` (`arena.nim:1315+`).

| Field | Type / default | JSON key | Valid values / draw | Effect |
|---|---|---|---|---|
| `size` | string / `""` | `mapSize` | `small`/`standard`/`large`/`huge`/`giant` (scales 0.85/1.0/1.3/1.8/2.6 of 1235×659); `colossal`=5.2 override-only | Field dimensions. |
| `symmetry` | string / `""` | `mapSymmetry` | 2-team: `mirror`/`rot180` (coin); 4-team draws `rot90` (square), `quadmirror` override = rectangular board completed by both reflections (GV39) | How half/quadrant seed set completes. |
| `columns` | int / `0` | `mapColumns` | `3..24` (gen); draw 4-team 3–4, compact-endzone 6–8, else 4–6 | Obstacle column count per half. |
| `windows` | int / `-1` | `mapWindows` | `0..6` per half; -1 = draw | Glass-window count (walls transparent to fog). |
| `centerFeature` | string / `""` | `mapCenterFeature` | `bracket`/`ring`/`walls` | Central obstacle archetype. |
| `layout` | string / `""` | `mapLayout` | 4-team: `corners`/`plus` (coin); 2-team `""`/`sides` | Team placement (4-team). |
| `pits` | int / `-1` | `mapPits` | `0..64` (gen); -1 = density draw; even = symmetric pairs, odd = center pit; 4-team supports only 0/-1 | Exact trench count. |
| `pitDensity` | int / `-1` | `mapPitDensity` | `0..1000` percent (gen); -1 = 100; ignored if `pits` set | Trench density multiplier. |
| `puddles` | int / `0` | `mapPuddles` | `0..64` (gen), COUNT mode only — ≤0 = none (the default, no density draw); even = symmetric pairs, odd = center puddle; 4-team supports only ≤0 | Exact paint-puddle count (damage-over-time floor hazards; see `puddleDamagePct`). |
| `endzone` | string / `""` | `mapEndzone` | `column`/`disc`/`square`; 2-team draw ¼ disc / ¼ square / ½ column; 4-team forced column | Home capture-region shape. |
| `endzoneRadius` | int / `0` | `mapEndzoneRadius` | `90..width` (gen); needs disc/square; 0 = draw | Compact endzone scoring radius. |
| `baseDepth` | int / `0` | `mapBaseDepth` | `400..800` permille (gen); needs disc/square; 0 = draw | Home anchor depth. |

Generator internals (all `arena.nim`, config-gated, no GameVersion bump; change in code):
`MapGenMaxAttempts`=100 (re-rolls until validators pass), `MinCorridorWidth`=26,
cover-density band `CoverPermilleMin`=40..`CoverPermilleMax`=170,
`ColumnFamily` per column = one of `colStubs`/`colDiamonds`/`colDiscs`/`colChevrons`,
pit-candidate kinds `pitInstead`/`pitGap`/`pitEndzone`, curated `MapPoolSeeds` = 20 seeds.

### Hand-authored arenas (fixed geometry, selected by `mapPath`)

- **`arena`** (`arenaCtfMap()` [arena.nim:462](../src/ctf/arena.nim#L462)): 1235×659,
  `flagRing`=70, `captureClear`=210, `spawnClearW`=70, `spawnClearH`=130,
  `gunRange`=1050, 5 obstacle columns, 2 med-kit spawns.
- **`arena-large`** (`arenaLargeCtfMap()` [arena.nim:486](../src/ctf/arena.nim#L486)):
  1606×858, `flagRing`=91, `captureClear`=273, `spawnClearW`=91, `spawnClearH`=169,
  2 med-kit spawns.

Per-map descriptor `CtfMap` [sim_types.nim:733](../src/ctf/sim_types.nim#L733) carries
`width`/`height`, `flagRing`, `captureClear`, `spawnClearW/H`, `gunRange`, `endzone`
+ `endzoneRadius`, `homeDepth`, `symmetry`, `layout`, `genSeed`, `medKitSpawns`,
`leftObstacles`, `trenches` — mostly derived from the above, not separately config-set.

> **Note:** if the config omits `gunRange`, it is overwritten by the selected map's
> own `gunRange` ([sim_config.nim:454](../src/ctf/sim_config.nim#L454)).

---

## Teams & agents

| Field | Type / default | Bounds | Effect |
|---|---|---|---|
| `teams` | int / `2` | must be `2` or `4` | Active team count: 2 (classic sides) or 4 (corners/plus FFA). |
| `gameMode` | string / `"ctf"` | `"ctf"` or `"emerg-ant"` | Objective rules and actor art. Emerg-ant turns hearts into replenishing food caches and enables public pheromone trails. |
| `forageGoal` | int / `5` | `>=1` | Emerg-ant food returns needed for a colony win; inert in CTF mode. |
| `minPlayers` | int / `16` | `1..32` | Players required to start; effectively sets roster size on open join. |
| `closedRoster` | bool / `false` | needs ≥`minPlayers` named+tokened slots | Fixed named roster vs open join. |
| `slots` | `seq[PlayerSlotConfig]` / `@[]` | ≤32; unique names/tokens; `team < teams` | Per-seat overrides. |
| `handicaps` | `array[Team, int]` permille / all `0` | authored as `{team: 0.0..1.0}` | Per-team handicap: 0 = normal, 1 = 50% miss + 1 life + 1 hit point + ½ max speed, linearly interpolated. |
| `perks` | `array[Team, seq[PerkGroup]]` / all empty | perk names `armor scope grenade thruster luck`; flat list, list-of-groups, or policy-name object | Per-team perk groups: one unnamed group = team-wide, N unnamed = per-policy (CTF-Doubles) dealt to distinct policies in join order, named (object form) = pinned to exact policies. |
| `perkMods` | `PerkMods` struct / `DefaultPerkMods` | `armorHp` `0..100`, `luckDamage` `1..100`, fractions authored `0.0..1.0` (permille-stored) | Perk magnitudes: `armorHp` (1) extra hp, `scopeAim` (0.5) aim-sigma cut, `grenadeRange` (0.25) extra throw range, `thrusterSpeed` (0.1) extra speed, `luckChance` (0.1) lucky-shot odds, `luckDamage` (2) lucky-shot hp. |
| `puddleDamagePct` | int / `20` | `0..100` | Percent chance of 1 damage per full second of continuous paint-puddle occupancy; inert on maps without puddles (`mapPuddles`). |
| `barrierPickups` | int / `0` | `0..2` ([sim_config.nim](../src/ctf/sim_config.nim) validate, cap `MaxBarrierPickupsPerTeam`) | Cardboard-barrier pickups PER TEAM, staged between base anchor and map center ([sim.nim `barrierSpawnPoints`](../src/ctf/sim.nim)); 0 = none (the default — echo omitted, no GV bump). |

**Per-team handicap** ([sim_types.nim `handicaps`](../src/ctf/sim_types.nim), accessors
`hitPointsFor`/`livesFor`/`maxSpeedFor`/`missPermilleFor`): a single `0.0..1.0`
knob per team, authored as a float map `"handicaps": {"red": 0.0, "blue": 0.6}`
and stored internally as permille (`0..1000`) so every in-sim derivation is
integer-only (native/wasm agree). At `0` a team plays normally (byte-identical to
no handicap — no extra RNG, existing replays re-simulate unchanged); at `1` it
gets 50% of would-be gun hits dropped, 1 life, 1 hit point, and half max speed;
values between interpolate linearly from the base config toward that floor.
Omitted/inactive teams stay at 0. Intended for a league (Campaign) to weaken a
dominating team. Handicaps are OBSERVABLE to policies: the init snapshot
carries one `handicap <color> <permille> hp <n> lives <n> spd <n> miss <n>`
marker per team (every team, permille 0 included) stating the fraction and the
engine-resolved deltas — see docs/RULES.md. Design: [docs/plans/2026-08-05-per-team-handicaps-design.md](plans/2026-08-05-per-team-handicaps-design.md).

**Team perks** ([sim_types.nim `Perk`](../src/ctf/sim_types.nim), accessors
`maxHpFor`/`maxSpeedFor(team, perks)`/`grenadeRangeFor`; join resolution
`roster.nim perkSetForJoin`): named buffs assigned per team as
`"perks": {"red": ["armor", "scope"]}` (one team-wide group),
`"perks": {"blue": [["grenade"], ["thruster", "luck"]]}` (unnamed per-policy
groups, CTF-Doubles: the Nth distinct policy to seat on the team gets group N,
clamped to the last), or `"perks": {"blue": {"botA": ["grenade"], "botB":
["luck"]}}` (groups PINNED to policy names; an unmatched policy gets nothing).
Magnitudes are the `perkMods` block
(`{"armorHp": 1, "scopeAim": 0.5, "grenadeRange": 0.25, "thrusterSpeed": 0.1,
"luckChance": 0.1, "luckDamage": 2}`), fractions stored as integer permille.
armor = +hp per bot; scope = tighter gun aim; grenade = longer throws;
thruster = faster top speed; luck = a fraction of landed gun shots deal
`luckDamage`. Defaults (no perks) are byte-identical to an engine without the
feature — no extra RNG, existing replays re-simulate unchanged. Perks are
OBSERVABLE: one `perks <color> <group> [<group>…]` marker per team in the init
snapshot and per-seat `pk` arrays in the broadcast roster — see docs/RULES.md.
Design: [docs/plans/2026-08-07-team-perks-design.md](plans/2026-08-07-team-perks-design.md).

`Team` enum: Red, Blue, Green, Yellow ([sim_types.nim:637](../src/ctf/sim_types.nim#L637));
active teams are always the prefix `Red..Team(teams-1)`. Hard caps `MaxPlayers`=32,
`MinPlayers`=16. Seats deal round-robin over active teams (`roster.nim:11`) unless a
slot pins a team. **There is no "players-per-team" knob** — it emerges from
`minPlayers`/joins split across `teams`.

Per-slot config `PlayerSlotConfig` [sim_types.nim:787](../src/ctf/sim_types.nim#L787):
`name`, `token`, `team`, `color` (16-color palette), `skin` (`DefaultSkin`/`CrownSkin`).

---

## Items & pickups

Counts are **not** individually config-numbered — they scale with `teams` and map
layout, and trench count via `mapGen`. Spawn placement in `sim.nim`.

Obstacles and trenches are `ArenaShape`s in five kinds: `rect`, `disc`,
`diamond`, `diagonal`, and (GV37+) `polygon` — a closed ring of integer vertices
for curved/organic terrain. Trenches are also `ArenaShape` (the generator emits
`rect` pits; authored maps may use any shape).

| Item | Count | Key consts (sim_types.nim) |
|---|---|---|
| Flags/hearts or food caches | 1 per active team | `FlagPickupRange`=34 (covers either 60px objective), `CaptureZoneWidth`=40, `PedestalCoverSize`=96; Emerg-ant caches replenish after delivery |
| Grenades | exactly 4 corner pickups | `GrenadeRespawnTicks`=120, `GrenadeChargeTicks`=24, `GrenadeBlastRadius`=52, `GrenadeDamage`=2, `GrenadeTrenchDamage`=6, max throw = `MapWidth/5` |
| Med kits | 2 (sides) / up to 4 (4-team) | `MedKitPickupRange`=12, `MedKitRespawnTicks`=720 |
| Shields | 1 per team endzone | `ShieldRespawnTicks`=720, `ShieldLayerHp`=3, `ShieldFireSlowdown`=3 |
| Plasma arcs (spray) | 1 per team endzone | `PlasmaArcRespawnTicks`=720, `PlasmaArcReach`=5, `PlasmaArcDamage`=3 |
| Trenches | via `mapGen.pits`/`pitDensity` | `TrenchSize`=56, `TrenchSpeedDivisor`=5, `TrenchFireSlowdown`=3, `TrenchMissPct`=70 |
| Paint puddles | via `mapGen.puddles` (`mapPuddles`) | `PuddleSize`=64, `PuddleRollTicks`=24, `DefaultPuddleDamagePct`=20 (config `puddleDamagePct`), `MaxPuddles`=64 |
| Cardboard barriers | via `barrierPickups` (per team) | `BarrierHp`=10, `BarrierRadius`=24, `BarrierHalfThick`=2, `BarrierRespawnTicks`=720, `MaxBarriersPlaced`=16 ([sim_types.nim](../src/ctf/sim_types.nim)) |
| Pheromone marks | up to 512 in Emerg-ant mode | `PheromoneStepTicks`=24, `PheromoneLifetimeTicks`=720, `PheromoneEraseRadius`=18, `MaxPheromoneMarks`=512 |

To vary item counts today: change `teams` (scales per-team items), change `mapGen`
pits (trenches), or edit the per-map spawn lists / consts in code.

---

## Scoring & win conditions

| Field | Type / default | JSON key | Bounds | Effect |
|---|---|---|---|---|
| `scoring` | string / `"classic"` | `scoring` | `"classic"` or `"pot"` | Reward rule: classic (+1 win / −1 loss) vs pot (ante/pot split). |
| `gameMode` | string / `"ctf"` | `gameMode` | `"ctf"` or `"emerg-ant"` | CTF capture/elimination or repeated competitive foraging. |
| `forageGoal` | int / `5` | `forageGoal` | `>=1` | First colony to this many food returns wins; at the clock, a unique score leader wins. |
| `maxTicks` | int / `7200` (5:00) | `maxGameTicks` | `>=0` | Scheduled game end (0 = unlimited); with the barrage on it is not a hard end. |
| `gameOverTicks` | int / `360` | | `>=0` | End-screen dwell ticks. |
| `maxGames` | int / `0` | | `>=0` | Games before server stops (0 = unlimited). |
| `barrageMaxPerSec` | int / `0` (off) | | `0..50`; `>0` needs `maxTicks>0` | Grenade-barrage endgame: environment grenades rain from the edges inward, ramping to this rate across the whole board (see RULES.md "Grenade barrage"). |
| `barrageStartPerSec` | int / `4` | | `1..barrageMaxPerSec` | Launch rate at the latch, targeting a 40px band inside every edge. |
| `barrageStartSec` | int / `30` | | `>=1` | Clock seconds remaining that latch the barrage (4:30 elapsed on the default 5:00 clock). |
| `barrageSaturateSec` | int / `30` | | `>=1` | Seconds from latch to full saturation (whole board at `barrageMaxPerSec`); defaults land it exactly at the scheduled end. |

Reward consts: `WinReward`=+1, `LossReward`=−1, `TimeoutReward`=−1 (draw penalty).
GV41 removed the action-floor overtime: the clock never extends, and a game with
the barrage configured ignores `maxTicks` entirely (it ends only on capture/wipe). Win logic:
capturing a heart eliminates that team; last team standing wins; 2-team ends on
the first capture. In Emerg-ant mode a returned food cache immediately replenishes,
the forage goal wins, and tied simultaneous goal finishes or tied clocks draw.

---

## Combat

| Field | Type / default | Bounds | Effect |
|---|---|---|---|
| `lives` | int / `3` | `>=1` | Respawns per player before permanent death. |
| `hitPoints` | int / `3` | `>=1` | Hits to kill. |
| `respawnTicks` | int / `72` (~3s) | `>=0` | Delay before respawning at home. |
| `gunRange` | int / `1050` px | `>0` | Gun reach; also drives aim-jitter sigma. Falls back to map's `gunRange` if omitted. |
| `fireCooldownTicks` | int / `12` (~0.5s) | `>=0` | Ticks between shots. |
| `fireWindupTicks` | int / `5` (~0.2s) | `>=0` | Trigger-pull-to-shot delay; aim locks at pull. |
| `carrierSpeedPct` | int / `70` | `1..100` | Flag/heart carrier movement speed %. |

Non-config envelope consts (change in code): `BulletHalfWidth`=8.0,
`AimJitterCentralZ`=1.2815516, `CarrierFireSlowdown`=3.

---

## Aim & vision

| Field | Type / default | Bounds | Effect |
|---|---|---|---|
| `aimTurnRate` | int / `5` | `>=1` | Aim rotation speed in brads per tick. |
| `visionConeDeg` | int / `60` | `0..180` | Vision cone half-angle around aim. |
| `visionBubble` | int / `90` | `>=0` | Omnidirectional vision radius (px). |

Non-config: `FovCellSize`=8, `visionRange`=1.5×gunRange.

---

## Motion / physics

Integer fixed-point model — `accel` = thrust, `frictionNum/frictionDen` = drag,
`maxSpeed` = velocity clamp. No `mass`/`drag`/`thrust` fields.

| Field | Type / default | Bounds | Effect |
|---|---|---|---|
| `motionScale` | int / `256` | `>0` | Fixed-point subpixel scale; a pixel of movement per `motionScale` of carry. |
| `accel` | int / `76` | | Per-tick acceleration while a direction is held (1/256 px/tick). |
| `maxSpeed` | int / `704` | | Per-axis velocity clamp (~2.75 px/tick). |
| `frictionNum` | int / `144` | | Friction numerator (idle velocity ×144/256 ≈ 56%/tick). |
| `frictionDen` | int / `256` | `>0` | Friction denominator. |
| `stopThreshold` | int / `8` | | Below this idle abs velocity, snap to 0. |
| `playerBouncePct` | int / `40` | `0..100` | Restitution of player-player collisions (0 = dead stop, 100 = elastic). |

Non-config: `TrenchSpeedDivisor`=5 (climbing out of a trench caps that axis to 1/5),
`PlayerHalf`=6, `MovementSlideMaxScan`=3.

---

## Determinism, pacing & timing

| Field | Type / default | JSON key | Bounds | Effect |
|---|---|---|---|---|
| `seed` | int / `0xA6019` | `seed` | | Master sim RNG seed (spawns, shot jitter, trench misses, respawns). Also feeds map seed when `mapSeed=-1`. |
| `speed` | int / `1` | `speed` | in `[1,2,3,4,8,16]` | Playback/real-time multiplier (pacing only, not physics). |
| `fastMode` | bool / `true` | | | Advance frames early once all ready (pacing; never hashed). |
| `startWaitTicks` | int / `120` (5s) | `gameStartWaitTicks` | `>=0` | Countdown once roster full. |
| `lobbyJoinTimeoutTicks` | int / `0` | | `>=0` | Abort lobby if still short (0 = wait forever). |
| `showPlayerLabels` | bool / `true` | | | Cosmetic name labels. |

---

## What varies a level, ranked

1. **`mapPath="gen"` + `mapSeed` + `mapGen` locks** — by far the richest: field size
   (5 classes), symmetry, 2-vs-4 team layout, columns (3–24) & family, windows (0–6),
   center feature, endzone shape + radius + depth, trenches (0–64).
2. **`teams`** (2/4) — changes layout, item counts, and win logic.
3. **Combat/motion/vision fields** — same map, different game feel and skill ceiling.
4. **`scoring`, `maxTicks`, `lives`, `hitPoints`** — match structure and stakes.

Cosmetic FX-duration consts (`ShotFxTicks`, `HitFlashTicks`, `SplatterFxTicks`, …)
never enter `gameHash` and do not vary gameplay.
