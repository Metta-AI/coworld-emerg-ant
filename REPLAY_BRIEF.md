# REPLAY BRIEF — Ctf (Phase 0 artifact)

> ⚠️ **STALE-RULES CORRECTION (2026-07-28, GameVersion 22).** This brief was traced at HEAD 5994eb0
> (GameVersion 1). The **timeout tiebreak described below NO LONGER EXISTS**: the lives-then-flag-progress
> tiebreak was removed at GV2 (commit fac8704, 2026-07-14). On the current sim, `checkMaxTicks`
> (src/ctf/sim.nim:5589) is an **unconditional draw** — "no tiebreak, no rewards" — and since GV21
> (a768a0e, 2026-07-22; same commit set `MaxTicks* = 5000`) a time-limit draw pays **`TimeoutReward = -1`
> to every player on both teams** (sim.nim:118, 5455-5473), while a **mutual-wipe draw stays 0/0**
> (sim.nim:5587 vs 5594). So there are TWO draw classes with different costs, and any "wins the
> tiebreak on lives/progress" narrative is an impossible outcome class on GV2+. `teamLivesRemaining` /
> `teamFlagProgress` survive only as broadcast chrome. Sections affected below: "What the game IS",
> "Standing axis", beat 8, F1/F3/F4/F10. Scoring scale is also stale: `WinReward* = 1` now (sim.nim:116),
> not +100. Re-trace before reusing any rule claim from this file.

> Every claim below is traced to engine source (`file:line` in this worktree, HEAD 5994eb0) or to the
> real-player research (TagPro competitive vocabulary + FPS CTF broadcast grammar + fog-honesty
> precedents, gathered this run). Nothing is derived-from-vibes.

## What the game IS (one sentence)

A 16-player 8v8 top-down capture-the-flag arena shooter with fog-of-war: steal the enemy flag and carry
it home — or wipe the enemy team — under a real time limit with a lives-then-progress tiebreak.

## Standing axis — "who is winning"

Scoring is **win-only**: `WinReward* = 100` awarded per winning player at `finishGame` (sim.nim:72,
2743–2778). Losers and draws get 0. So the SCORE is flat 0–0 for the whole match — the honest live
standing axis is the **tiebreak currency**, exactly what `checkMaxTicks` (sim.nim:2860–2880) consults
at the limit:

1. **Team lives remaining** — `teamLivesRemaining` (sim.nim:2790): sum of `p.lives` + 1 per currently
   alive player. This is the number the scorebug leads with.
2. **Flag states** — each flag is either HOME (on pedestal) or TAKEN (carried). There is **no dropped
   state**: carrier death returns it instantly (`sim.nim:1815, 2251, 2441` "flag returned home";
   RULES.md "a flag is never left loose on the ground").
3. **Flag progress** — `teamFlagProgress` (sim.nim:2799): how far the enemy flag has been advanced
   toward home while carried; 0 on the pedestal. Second tiebreak key.

## The board

Mirrored symmetric arena, `MapWidth 1235 × MapHeight 659` (sim.nim:15–16). Red home = left edge, Blue =
right. Home capture zones are the edge columns (`CaptureZoneWidth* = 40`, sim.nim:75); base pockets kept
traversable by `ArenaCaptureClear = 210` (sim.nim:467). Named rooms: Center, Red Base, Blue Base
(sim.nim:553–558). Flag pedestals via `flagHome` (sim.nim:578). Dense staggered cover — no straight
sightline crosses the field (RULES.md).

## Entities + how the real game groups them for reading (L50)

- **16 players in 2 teams of 8** (config.json slots alternate red/blue). The real-player grammar groups
  them by ROLE-IN-THE-MOMENT, not roster order: the CARRIER (highlighted persistently — TagPro/Halo
  convention), the chasers, the defenders, the dead-waiting-to-respawn. Scoreboard groups by team.
- **2 flags** — home pedestal or carried; carried = on the thief, moving at 70% speed
  (`carrierSpeedPct: 70`, config.json:9).
- **Combat ephemera** — hitscan tracers (windup 5 ticks, cooldown 12 ticks, range 1300px ≈ map-wide;
  config.json:6–8, 149; spectator-only, hits draw full-bright while misses draw pre-faded), hit → HP
  loss (3 HP/life) with a white flash ring over the struck target, death splatters, landing impact
  rings (a shot's only player-audible trace), aim-indicator lines (visible on ALL players in
  spectator view — RULES.md "Aim").
- **Lives**: 3 per player (config.json:3); respawn 72 ticks ≈ 3s; spawn protection 24 ticks ≈ 1s
  (config.json:5–6). Out of lives = ghost for the round.

## "You"

The watching player's entrant policy drives specific slot(s) on one team. The broadcast marks the
viewer's team/slots when the embed provides identity; the existing server feature — click a player →
render THEIR fogged POV (`toggleSelectedJoinOrder` → `buildSpriteProtocolPlayerUpdates`, global.nim) —
is the "you" lens and must be kept and made discoverable.

## Dramatic beats — ranked, engine-traced, grounded in what real fans call dramatic

The repo's own timeline tool already enumerates the taxonomy (`tools/expand_replay.nim:9` —
PlayerJoined, PhaseChanged, Kill, FlagSteal, FlagReturnHome, Capture, Respawn, ScoreChanged, GameOver).
Ranked by drama:

1. **CAPTURE** (`Capture`; sim.nim:2840–2848) — carrier crosses the home capture zone → game ends. THE
   money shot. Fans' signature moment is "the flag run": a carrier at 70% speed surviving the chase
   (TagPro "cap", Halo's "can he make it?!"). Stage it with the biggest treatment + hold.
2. **WIPE / final kill** (sim.nim:2849–2858) — a team's last life extinguished ends the game (both
   wiped same tick = draw). The kill that ends it deserves capture-grade weight.
3. **FLAG STEAL** (`FlagSteal`; carrier diff, expand_replay.nim:197) — "the grab". Scorebug flag icon
   flips HOME→TAKEN; carrier highlight begins.
4. **CARRIER KILL → FLAG RETURN** (`Kill` + `FlagReturnHome` same tick) — the "snipe/reset" beat
   TagPro fans prize; the flag snaps home instantly. Must read as one composite beat.
5. **KILL** (`Kill`; deaths diff, expand_replay.nim:131) — kill feed row. **Friendly fire is ON**
   (RULES.md Combat) → team-kills happen and must be marked, not mislabeled. **Same-tick mutual kills
   resolve simultaneously** (RULES.md) → the feed must render both.
6. **RESPAWN** (`Respawn`) — home-edge rematerialize + 24-tick protection shimmer. Low drama, high
   legibility value (explains where players went).
7. **PHASE / COUNTDOWN** (`PhaseChanged`; Lobby→Playing→GameOver; "game starting in N" sim.nim:1316).
8. **GAME OVER verdict** (`GameOver` + `ScoreChanged` +100s at the same moment) — the end-card must say
   HOW it ended: capture / wipe / **time-limit tiebreak naming the key** (lives, else flag progress) /
   draw.

## Tempo map

24 ticks/s (`ReplayFps`). `maxTicks 10000` ≈ 6:56 of game time (config.json:13 — but certification runs
`maxTicks 300` ≈ 12.5s in `coworld_manifest_paintbot.json` certification, so the clock derives from `sim.config.maxTicks`,
never a hardcode). Engine playback speeds `[1,2,3,4,8,16]` (replays.nim:40). Dead time = both flags
home, no contact — where speed collapses; contact windows and any beat hold their read time
(DEPTH_TARGET tempo levers).

## FIDELITY AUDIT — the traps, named

| # | Trap | Engine truth | Rule for the broadcast |
|---|---|---|---|
| F1 | **Kills rendered as score** | Only winning +100 exists (sim.nim:72, 2766). Kills/captures recorded for analysis only (RULES.md Scoring) | Kill feed + per-player K/D yes; the SCORE axis shows 0–0 until the win. Standing = team lives + flag state |
| F2 | **"Dropped flag" state** (FPS convention) | No loose flag ever: carried or home (sim.nim flag returns; RULES.md) | Flag iconography has exactly 2 states: HOME / TAKEN. No drop markers (L17 invented mechanic) |
| F3 | **Clock vs cap (L75)** | `maxTicks` IS a real limit with a real tiebreak (`checkMaxTicks` sim.nim:2860) | A countdown to tiebreak is HONEST here — label its consequence (tiebreak), derive from config |
| F4 | **Tie that's really a tiebreak (L76)** | Draw only after lives tie AND progress tie (sim.nim:2871–2880); `finishGame(Red, isDraw=true)` stores a winner even on draws (sim.nim:2858, 2880) | Verdict must check `isDraw` BEFORE `winner`; a time-limit win names its key ("wins on lives 9–7") |
| F5 | **Flag arrows / global tracking (L77)** | Deliberately none — fog replaced tracking intel (RULES.md, docs note "no flag arrows") | The omniscient spectator MAY show the carrier (aim lines are already spectator-visible per RULES), but nothing may imply PLAYERS see it — fog honesty via the POV-click lens + optional vision-cone rendering (SC2/Dota spectator precedent) |
| F6 | **Team-kills mislabeled** | Friendly fire ON (RULES.md) | Feed marks team-kills distinctly |
| F7 | **Kill attribution on multi-kill ticks** | `killerThisTick` (expand_replay.nim:124) returns the FIRST kill-count increase — ambiguous when 2+ players kill on one tick | Payload derivation must attribute per-victim from sim state, or degrade honestly ("traded") — do not guess |
| F8 | **Chat** | `allowChat=true` in the spec but consumed without applying (replays.nim:209–212) | No chat surface — there is no in-game chat |
| F9 | **Score events mid-game** | `ScoreChanged` fires only with the win award | Never animate score mid-match |
| F10 | **Draw = mutual wipe OR full tiebreak tie** | sim.nim:2857–2858, 2880 | End-card distinguishes the two ("mutual destruction" vs "dead-even at the limit") |

## Fog honesty (the audit's core)

The spectator/replay view is omniscient (RULES.md: aim indicators drawn "for everyone in the spectator
view"; ghosts see all). Players see a ±45° cone + 90px bubble, walls block, teammates fogged. Precedents
(SC2 observer toggle, Dota spectator fog toggle): the honest move is to make per-player vision
*inspectable* — the existing click-to-POV server feature — and optionally render vision cones on the
omniscient view, while the default broadcast stays omniscient and never implies players share it.
