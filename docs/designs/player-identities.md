# Player identities (alpha–theta)

## Problem

Players are anonymous on the board beyond team color: within a team, all eight
soldiers render identically. Spectators cannot follow an individual across the
match, and policies cannot re-identify a specific enemy after a fog gap.

## Design

Each team's eight slots get a fixed identity, **alpha** through **theta**,
assigned by slot order within the team (a slot's rank among same-team slots in
the config). Identity is derived from the slot, not stored: deterministic
across matches, reconnects, and replays, with no new sim state and no
`gameHash` impact.

### Badge object (policy-visible)

Each **living** player carries one badge object anchored to their sprite —
the same attach-by-proximity pattern the overhead HP pip bar uses:

- **Sprite:** an 11px round badge — dark ink disc, team-tinted rim, and the
  uppercase Greek glyph (Α Β Γ Δ Ε Ζ Η Θ) in the team color mixed toward
  white. The bundled fonts have no Greek coverage, so the eight glyphs are
  hand-authored 5×7 pixel bitmaps embedded in source (like the code-drawn HP
  bar), rasterized at `boardScale` on emission. One definition per team ×
  identity × **aim step** (the glyph is baked turned to the aim — see
  Placement), ids 4200..4711; object pool 19040..19055.
- **Label:** `identity <color> <name>`, e.g. `identity red alpha`. New,
  additive vocabulary — existing `player <color> <side>` labels are untouched,
  so exact-match label readers (the baseline bot) keep working. Policies
  attach a badge to a player by proximity, exactly as they do `hp <n>/3` bars.
- **Placement:** clear of the overhead HP-bar/name stack; z just above its own
  body in the y-sort. The two streams place it differently:
  - **Broadcast board:** painted onto the cog's head plate — a few px BEHIND
    the rotation hub along the aim, because the hub is the head cube's center
    and the cube's leading face is the visor, so a hub-centered badge sat on
    the cog's face. The glyph is baked to the head's own aim step, so the
    letter turns with the cog instead of hovering upright over it.
  - **Player view (the observation):** centered on the body and upright, at
    every aim — RULES.md documents it as "centered on its player's body:
    attach it by proximity", so the board's cosmetics stay off the wire a bot
    reads. Byte-identical to the pre-head-plate badge.
- **Visibility:** fog-gated with its player in POV views (visible player ⇒
  visible identity — it is intel, like HP); always shown in the global
  viewer/replays; living players only, drops with death like the HP bar.

### Non-goals

- No per-identity player-body sprites (would 8× the soldier sprite pool and
  break the documented label vocabulary).
- No sim, protocol, config, or `GameVersion` changes — rendering only.

## Touched surfaces

- `src/ctf/sim.nim`: `IdentityNames` const + `slotIdentityIndex` (rank of a
  slot among same-team slots, via the existing `teamForSlot`).
- `src/ctf/global.nim`: glyph bitmaps, badge sprite builder, an
  `addIdentityBadges` pass in both the global-board and POV builders
  (replay/broadcast reuse those builders and get it for free).
- `docs/RULES.md`: identity assignment under Teams & spawns; the new
  `identity <color> <name>` label beside the player-sprite label docs.

## Validation

Build the server and baseline bot; run 16 bots locally and verify badges in
the global viewer; verify a POV client only receives `identity` labels for
players inside its vision; expand an existing replay to confirm no regression.
