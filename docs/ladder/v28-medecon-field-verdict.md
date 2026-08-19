# Picasso:v28 (medEcon) — field verdict, 2026-07-29

VERDICT: **KEEP v28.** Do not revert to v26.

## Tenure
- v26: r1672..r1846 (174 rounds), v28: r1847..r1938 (92 rounds, all 19-22 ep, **0 zero-episode rounds** → no DQ).
- v28 is live champion now: `competing/active`, pv d1755958.

## The decision rule, evaluated
Revert trigger was "winrate vs the field below v26's 0.471 over 30+ rounds".
- v28 raw episode winrate: **0.4530** (833/1839, 92 rounds).
- v26 raw over its OWN tenure, measured identically: **0.4534** (1304/2876).
- The 0.471 figure is not reproducible as a same-window v26 number; v26's
  comparable last-92-round raw winrate is **0.4378**. Against that, v28 is UP.
- v28 trend is upward, not decaying: first half 0.4455 → last half 0.4604 →
  **last 30 rounds 0.4834**.

## Why the flat raw number understates the lever: the field re-armed
40.2% of v28's schedule is opposition that did not exist in v26's tenure, and it
is **27.3 pp harder** than the opposition it replaced (our wr vs churned-out
policies 0.5895 vs vs churned-in 0.3166). daveey v56→v62, beacon v28→v33,
Jordan v2→v9, Andre → alphashot:v67/v106.

Matched only on opponent versions present in BOTH tenures (n>=20 each):
- **+5.17 pp** weighted by min(nA,nB) over 915 matched episodes; 7 of 8 opponents improved.
- Pooled on those same 8 opponents: v26 0.4377 → v28 **0.5595**.

Top-3 baselines from the task all improved (and my v26 numbers reproduce the
recorded 17.2 / 24.0 / 10.4 baselines, which corroborates the method):
| opponent | v26 | v28 |
|---|---|---|
| daveey ctf-focusfire:v56 | 0.194 | 0.318 |
| Alex Smith ctf-h050:v1   | 0.251 | 0.350 |
| Andre alphashot-ghost-red | 0.107 | 0.141 |

Mean rank worsened (5.03 → 6.46) — consistent with the same re-arming, since
rank is relative to a field that got stronger, not an absolute skill measure.

## Mechanism: heals (partially answered — stated honestly)
v28 sample, 28 episodes re-simulated with hash validation:
- HEALS ours **2.11**/ep vs theirs **1.54**/ep → we now OUT-heal the field
  (pre-fix the field took 42 to our 11, ~3.8x against us; now 0.73x).
- K/D **1.028**; attrition window ticks 1000..3000 K/D **0.988** (was where 81%
  of the deficit was booked).
- ⚠️ NOT a controlled A/B: v26's replays (coworld <=0.7.94, GV22) **cannot** be
  re-simulated on the GV23 lab engine — version-label override fails hash
  validation at tick 1, so GV23 is genuinely behaviorally different. There is no
  shared build between the tenures. The v28 heal numbers are absolute, and they
  clear parity; the v26-side comparison is unavailable, not merely unrun.
