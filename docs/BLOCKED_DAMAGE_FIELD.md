# Tier-2 `blocked` field — damage a shield absorbed (for James / engine review)

**What / why.** The Observatory Logs *Healing* tab wants to show "damage blocked"
beside "HP recovered" and "HP lost" — the third defensive lever. That was NOT
derivable from the old event schema (no shield/carrier field; `hit` events keep
`hp:-1`). This change makes it a first-class, first-hand engine fact.

## The change (option (a): one numeric field, the clean one)

`SimEvent` gains `blocked*: int` — on a `Damage` event, how many of that hit's
HP the victim's **shield** absorbed. `0` on every non-Damage kind and on any hit
where the victim held no shield HP.

Derivation is exact and first-hand. `main` models the shield as a separate
`shieldHp` layer (`0..ShieldLayerHp`, depleted before base hp) and routes every
hit through `absorbDamage`, which already computes how much the shield soaked:

```nim
proc absorbDamage*(sim, targetIndex, amount): int =   # returns fromShield
  let fromShield = min(players[targetIndex].shieldHp, amount)
  players[targetIndex].shieldHp -= fromShield
  players[targetIndex].hp       -= amount - fromShield
  fromShield                                           # == blocked, exactly
```

That `fromShield` **is** `blocked` — no heuristic. The three `Damage` emit sites
(gun, spray, grenade) capture `absorbDamage`'s return value and pass it as
`blocked = …`. Rides the analysis-only event sink — NOT in `gameHash` (a test
asserts this), so replays stay deterministic and live servers pay nothing
(`collectEvents` still gates it).

`tools/extract_events.nim` serializes it as `"blocked"` in each JSONL row.

## Tests

- `tests/test_blocked_damage.nim` (new): a full shield layer soaks 1; walking a
  shielded carrier down proves blocked stops once the shield layer empties
  (`ShieldLayerHp` total); a shieldless cog blocks 0; `blocked` never enters the
  game hash.
- `tests/test_extract_events.nim`: invariants `0 <= blocked <= amount` on Damage,
  `blocked == 0` on every other kind, and every JSONL row carries the key.

## Downstream (already merged on the web side)

`derivations.ts` `blocksBySeat`/`blocksByPolicy` sum `blocked` by the protected
victim (`target`); `HealingTab` renders a **Blocked** column + episode total,
gated so it only appears when the episode recorded any (no dead zero column,
honest note otherwise). `EpisodeEvent.blocked?` is additive — pre-field streams
read 0.

## Note for the ingestion path

Real episodes light this up automatically once the EVENTS artifact carries
`blocked` (the extractor emits it now). The seed fixture models shieldless 3-HP
cogs, so seeded episodes correctly show the honest "no damage blocked" state.

## Rebase-onto-main reconciliation — DONE

This originally landed on `maxwell/logs-event-substrate` (PR #83), which predated
`main`'s shield refactor and derived `blocked` from an `hp-above-base` heuristic
(`shieldBlocked()`). On the rebase onto current `main` (GV22, shield-armor layer)
that heuristic was **replaced** by `absorbDamage`'s exact `fromShield`:

1. ✅ `shieldBlocked()` dropped — superseded by `absorbDamage`'s shield arithmetic.
2. ✅ `absorbDamage` now returns `fromShield`; the three Damage sites capture it
   and pass `blocked = …`.
3. ✅ `test_blocked_damage.nim` rewritten for the two-field model (`shieldHp`
   layer vs base `hp`); `test_extract_events.nim`'s HP-trace invariant updated to
   `hp == lastHp - (amount - blocked)` since base hp now steps down only by the
   part the shield let through. `SimEvent.blocked`, the `emitEvent` param, and the
   extractor serialization are unchanged.
