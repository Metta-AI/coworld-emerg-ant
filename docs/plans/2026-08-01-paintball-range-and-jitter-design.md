# Paintball range cap + aim jitter + vision range (GV34)

## Goal

Three coupled changes — two to the paintball gun, one to vision:

1. **Fixed max range on every map**: the small generated map's field width,
   `round(1235 * 0.85) = 1050 px`. Today every map def scales `gunRange` with
   the field (`s(1300)`: 1300 on the arena, 1690 on arena-large, 3380 on
   giant), so the gun is effectively map-wide everywhere. After this change
   the gun is map-wide **only on the smallest field**; on anything larger,
   paint falls short and closing distance matters.
2. **Aim jitter**: each released shot's direction is perturbed by Gaussian
   angular noise, calibrated so a **fully visible** body at **max range** is
   hit **80%** of the time. Closer targets are hit near-deterministically;
   partially covered targets get the same noise on top of the existing
   exposure sampling.
3. **Vision range**: the fog-of-war cone (previously unlimited,
   LOS-permitting) cuts off at **1.5× the gun range** (`visionRange`,
   1575 px stock) — sight outranges paint by half again, and both scale
   together under a config `gunRange` override. The ~90 px close-quarters
   bubble is exempt, and the first-person strip's wall march follows
   `visionRange`. Broadcast-only (fog never enters the game hash), and every
   fixture map's diagonal is under 1575 px, so the recorded fixtures'
   episodes are unaffected. On the default arena (diagonal ~1400 px) the cap
   is invisible; it bites on large/huge/giant generated maps.

## Noise derivation

The hit window: the bullet corridor has half-width `BulletHalfWidth = 8 px`,
and a fully exposed body presents silhouette samples across
`±PlayerHalf = ±6 px`, so a shot connects iff the target center sits within
`W = PlayerHalf + BulletHalfWidth = 14 px` of the shot ray (verified against
`selectFireTarget`'s sampling: offsets −6,−3,0,3,6 with an 8 px corridor give
a continuous ±14 px acceptance window).

An angular error θ displaces the ray by `d·sin θ` at target distance `d`.
For a centered aim at `d = R` (max range):

```
P(hit) = P(|sin θ| ≤ W/R) = 0.80
θ ~ N(0, σ);  P(|θ| ≤ z·σ) = 0.80  ⇒  z = Φ⁻¹(0.90) = 1.2815516
σ = asin(W/R) / 1.2815516
```

With `W = 14`, `R = 1050`: `σ = asin(0.0133333)/1.2815516 = 0.0104 rad ≈
0.60° ≈ 0.42 brads`. σ is computed from the **live** `config.gunRange`, so a
league config that overrides the range keeps the "80% at max range"
calibration automatically.

Resulting hit probability vs a fully visible target (R = 1050):

| distance (px) | 1050 | 900  | 700  | 525  | ≤300 |
|---------------|------|------|------|------|------|
| P(hit)        | 80%  | 86%  | 94%  | 99%  | ~100%|

Gaussian (not uniform) noise was chosen for the smooth distance falloff and
because `std/random.gauss` on the seeded sim RNG is deterministic — same
seed, same match, same replays.

## Implementation

- `GunRange* = 1050` (was 1300), and every map def stops scaling it:
  `arenaCtfMap` (1300), `arenaLargeCtfMap` (1690), and both `scaledGenShell`s
  (`s(1300)`) all use the constant. The `gunRange` config/map-JSON override
  keeps working; old replays deserialize their recorded value.
- New const `AimJitterCentralZ = 1.2815516` documents the calibration.
- `selectGunShot` draws `jitter = gauss(sim.rng, 0, σ)` once per released
  shot (before the trench duck rolls, a fixed RNG order), rotates the locked
  aim vector by it, and carries the perturbed unit direction in
  `PendingGunShot`. `selectFireTarget` and the tracer/stain march in
  `applyFire` both use that direction, so what the viewer sees is where the
  paint actually went. Events keep the **intended** `headingBrads`.
- **Broadcast decouple**: the first-person strip's wall march in
  `broadcast.nim` used `config.gunRange` as its depth cap. Vision is
  LOS-limited with unlimited range (`computeFovVisible`), so the strip now
  marches to `MapWidth + MapHeight` (≥ any sightline) instead — the range
  nerf must not silently blind agents on large maps.
- `GameVersion` 33 → 34 with a GV34 note; RULES.md gun section updated;
  replay/broadcast fixtures re-recorded per the standard GV-bump recipe
  (`tools/record_fixture.sh`).

## Tests

New `test_gun_jitter.nim` (open-lane scene verified wall-free like
`test_shot_exposure` does):

- beyond 1050 px a fully exposed target is **never** hit; within range the
  tracer never exceeds `gunRange`.
- Monte-Carlo calibration: ~5000 shots at exactly max range hit 77–83%
  (SE ≈ 0.57%, so the band is ~5σ); at half range ≥ 97%; point-blank 100%.
- determinism: two sims with the same seed produce identical shot outcomes.

Existing suites re-run; fixtures re-recorded (jitter draws shift the RNG
stream and hit outcomes, so GV33 fixtures no longer re-simulate — expected
on a version bump).
