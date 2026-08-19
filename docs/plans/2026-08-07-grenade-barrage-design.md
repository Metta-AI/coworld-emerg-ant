# Grenade barrage — escalating-bombardment endgame

## Problem

Timed games that reach `maxTicks` without a capture or wipe end in a scoreless
draw (`checkMaxTicks`). Passive play can ride the clock out. We want an
endgame forcing function that shrinks the safe space and forces the fight —
without a hard kill-wall. (A first iteration of this feature was a solid
"paint flood" band closing in from the edges; it was replaced by this design:
an escalating rain of ordinary paint-bomb grenades, which reuses the whole
existing grenade pipeline, reads on every stream for free, and pressures the
edges probabilistically instead of walling them off.)

## Behavior

- When the game clock has **`barrageStartSec` seconds remaining** (default
  30 — 4:30 elapsed on the default 5:00 clock), the barrage latches on:
  environment grenades start landing at **`barrageStartPerSec`/second**
  (default 4) inside a **40px band along every map edge**
  (`BarrageEdgeBandPx`).
- Over **`barrageSaturateSec` seconds** (default 30) the barrage
  **escalates linearly**
  (`barrageProgressPermille`): the target band deepens to **full board
  coverage** and the launch rate ramps to **`barrageMaxPerSec`** (0 = mode
  off — the default; hard cap `BarrageAbsMaxPerSec` = 50). At the moment the
  nominal clock would expire, the whole arena is under maximum bombardment.
- The escalation is **monotonic from the latch tick**, and with the barrage
  configured the time limit no longer ends the game at all (GV41 also removed
  the GV23 action-floor overtime): past 0:00 the full-intensity bombardment
  grinds on until at most one team stands. A draw requires the last players
  of two teams to die on the same tick.
- Shells are **ordinary grenades** through the ordinary pipeline
  (`AirborneGrenade` → `updateGrenades` → `explodeGrenade`): same blast
  radius, damage, trench amplification/shielding, shield soak, paint stains,
  and FX as a player lob, with the same fixed fuse
  (`GrenadeFlightMultiple × fireWindupTicks`).

## Environment attribution

Shells carry `thrower/throwerSlot/throwerAccount = -1`. In `explodeGrenade`:
- the splat color cycles the active team colors by launch tick (never calls
  `teamForSlot(-1)`, which would index `Team(-1)`);
- kill credit, team-kill records, multi-kill counters, and reward-account
  kills are all already gated on `throwerSlot >= 0`;
- a fatal blast logs `<color> shelled by the grenade barrage` via
  `killPlayer`'s `cause` parameter instead of "killed by unknown".

## Config

| Field | Default | Bounds |
|---|---|---|
| `barrageMaxPerSec` | 0 (off) | 0..50; > 0 requires `maxTicks > 0` |
| `barrageStartPerSec` | 4 | 1..`barrageMaxPerSec` (when on) |
| `barrageStartSec` | 30 | >= 1 |
| `barrageSaturateSec` | 30 | >= 1 |

`configJson` emits the keys **only when the mode is on** (handicaps pattern),
so a default game's replay config echo is byte-identical.

## Determinism

- `SimServer.barrageStartTick` (latch, -1 before) and `barrageAccum` (permille
  launch accumulator: each tick adds `barrageRatePermille()`, every
  `TargetFps * 1000` units launches one shell — even pacing at any integer
  rate, zero drift). Reset in `initSimServer`/`startGame`/`resetToLobby`.
- Landing points draw from the deterministic sim RNG (side, along-edge
  coordinate, inset within the current depth).
- `gameHash` mixes `barrageStartTick` + `barrageAccum` **only once latched**.
  (The GV41 overtime removal did change every game's hash stream —
  `overtimeTicks` left the hash — so the fixtures were re-recorded with the
  GameVersion bump; the barrage fields themselves stay latch-gated.)
- Launches are capped at `MaxPlayers` concurrent shells (the drawn-orb pool),
  with the accumulator still draining so a capped stretch never banks a burst.

## Observability

No new rendering: shells are `grenade air` orbs and `blast stage <n>`
landings on both streams. One invisible 1x1 stated marker per stream
(`BarrageMarkerSpriteId`/`ObjectId`) declares the schedule whenever the mode
is configured: `grenade barrage depth <n> rate <n> start <n>` (depth/rate 0
until the latch). In the label manifest; posed in the label-contract sweep.

## Testing

`tests/test_barrage.nim`: config lifecycle + validation + echo gating; latch
timing; ramp math at 0/500/1000 permille; overtime-never-unwinds; accumulator
cadence + band targeting + unowned shells; environmental kill without credit;
the no-timeout-draw guarantee; hash gating; mid-barrage keyframe round-trip;
marker emission on both streams. Existing fixtures prove the default path.

## Known adjacent issue (pre-existing)

Keyframed replay seeks leave ~4.7k stale diamond-stamp pixels in
walk/wall masks (donor-mask vs keyframe `diamondPatches` disagreement), which
can surface as a replay hash-mismatch banner after scrubbing once an endgame
mode funnels players through the center. Tracked separately.
