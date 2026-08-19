# DEPTH TARGET — Ctf replay broadcast (Phase 0r artifact)

> The written read-first gate (PD1). This is the bar the Phase-4 audit grades against.
> Reference implementation studied: **Agricogla** (`metta/packages/cogweb/games/agricogla/src/client/animation/`
> — `TownTable.tsx` / `replayTiming.ts` / `assets.ts` / `living.css`), extracted by a dedicated reader agent.

## 1. Lessons read (this platform + archetype)

All read IN FULL this run: `layout-legibility.md` (L22/L27/L34/L48/L49/L65/L68/L70/L71/L72/L73/L81/L83/L84/L88/L89),
`motion-and-life.md` (L4/L5/L6/L6b/L11/L12/L19/L20/L35/L52), `platform-and-architecture.md`
(L9/L10/L14/L15/L16/L21/L24/L25/L26/L29/L47/L51/L54/L64/L78/L85/L94/L95), `fidelity-and-broadcast.md`
(L7/L17/L18/L23/L44/L50/L59/L60/L61/L62/L63/L67/L75/L76/L77/L97), `process-and-depth.md` (DEPTH BAR +
PD1–PD15), `visual-art-direction.md` (L30–L47/L74/L87), `turn-flow-and-station-IA.md` (TF1–TF7).
Platform shape: **A-plumbing, elevate-by-rebuild (L47)** — self-hosted Nim server, viewer HTML embedded at
compile time via bitworld `staticRead`. Archetype: **spatial (arena shooter)** — smooth motion essential (L6),
reuse the live renderer if one exists (L9).

## 2. What the reference actually hit (the Agricogla bar, quantified)

- **Art: 194 distinct PNG assets** — 2 ground, 8 buildings/tiles, 5 crop growth stages, 7 animals,
  8 resource tokens, 14 town landmarks, 2 props, **128 farmer animation frames** (7 motions × 4 frames ×
  4 team recolors), 1 wordmark. Not one backdrop — a full per-entity, per-motion, per-team batch.
- **Choreography grammar: 7 staged beat sequences**, each an ordered multi-step motion: WALK-IN
  (L-path → bob-walk → fade-in → settle to work loop), FLY-HOME ARC (wait-for-arrival delay → 6-keyframe
  arc that scales 2.4× at peak with a read-pause hold), BIG GAIN POPUP (burst → 40–82% hold-to-read →
  float away), ROUND-END WALK HOME (reverse path + carried-good bob), NEW-ROUND CURTAIN (dim → card pop →
  74% hold → fade), ACTION CHIP (overshoot pop), FARM PIECE POP (spring from base), END-CARD (dim + hold
  forever).
- **Timing levers**: `BASE_TURN_MS 2600`, `ANIM_MAX 2` (beats never play faster than 2× no matter the
  replay speed), `READ_PAUSE 600ms` floor, `turnDwellMs = max(base/speed, walk+120+fly+READ_PAUSE)` —
  **speed collapses dead time between beats, never truncates a beat below readability**.
- **Ambient life**: 6 idle systems (animal bob+roam, crop sway, chimney smoke, active-glow breathe,
  turn pulse), all compositor-only transforms, desynchronized per node via a `--phase` custom property,
  paused while a beat plays (`beats-active`), disabled under `prefers-reduced-motion`.
- **HUD register**: persistent top-band scorebug INSIDE the SVG (rank ordinal + team dot + clipped name +
  big mono VP + leader crown + margin `▲ +N`), a clock pill, and an end-card with a plain-language verdict
  for cold viewers. Every number carries rank/margin context.
- **Skeleton**: ONE `<svg viewBox="0 0 2098 1180" preserveAspectRatio="xMidYMid meet">`, top band reserved
  by a shared constant, 14-layer explicit paint order. (Known gap in the reference: no portrait reflow —
  L88 was learned after; we must exceed it there.)

## 3. Measured container contract (L70/L48/L88 — the real boxes this must fill)

| Surface | Box | Effective aspect |
|---|---|---|
| League **Featured Match** (`LeagueDetail.tsx:1876`) | `aspect-video min-h-[320px] w-full` wrapper + `CoworldReplayFrame height="auto" minHeight="320px"` | 16:9 at the detail-column width; narrow column → the `min-h` makes it TALLER than 16:9 |
| Episode detail (`EpisodeRequestDetail.tsx:1084`) | `height="min(680px, 72vh)" minHeight="420px"` | ~1.5–1.9 on desktop |
| Standalone replay pages (frame defaults) | `height="min(900px, 88vh)" minHeight="360px"` | ~1.5–1.9 on desktop |
| Floor | **640×360** | 16:9, everything must stay legible |
| Phone / narrow middle column | ≈390px wide, box goes **portrait ~0.5:1** | landscape `meet` shrinks to a strip → needs a **stacked REFLOW**, not a scale |

Iframe is `sandbox="allow-scripts allow-same-origin"`; no CDN reachable (L13) — vendor everything.

## 4. The CTF depth target (what "hitting the bar" means for THIS game)

Translate the bar, don't transplant the desk (visual-art-direction rule): Agricogla's 194 assets are a
*board game's* physical inventory. Ctf is a **pixel arena shooter watched from above** — its equivalent
depth axes:

- **Art batch target (~40–60 wired subjects, not 1 backdrop):** the arena itself as a DESIGNED set
  (lit ground, cover shapes with edge treatment, mirrored-arena readability, base pockets + capture zones
  as painted zones, pedestal art per team), player sprites with team identity + facing + carry pose +
  ghost/dead state, flag art (on-pedestal, carried, returning), muzzle flash, tracer treatment, hit spark,
  death splatter, sound-ring, spawn-protection shimmer, self/POV markers, HUD chrome (scorebug plates,
  flag-state icons ×3 states ×2 teams, kill-feed glyphs, clock pill, speed/transport icons, end-card set),
  wordmark. Server sprite-sheet art counts toward this only where we elevate it deliberately.
- **Choreography grammar (per-beat staged sequences, spatial-archetype form — motion is interpolated
  locomotion → impact → objective consequence):**
  - **KILL**: tracer flash along the locked aim ray → hit spark on victim → victim collapses to splatter +
    ghost fade → kill-feed row slides in (killer ▸ weapon glyph ▸ victim, team-colored; TEAM-KILL marked) →
    victim's scoreboard lives pip dims.
  - **FLAG STEAL**: pedestal flag lifts onto the thief → carrier aura + slow-trail begins → scorebug
    flag-state icon flips home→taken with a pulse → banner chip ("RED FLAG TAKEN").
  - **FLAG RETURN**: carrier death splatter → flag arcs home to pedestal (fast, readable) → scorebug icon
    flips back with a settle pulse.
  - **CAPTURE (the match point)**: carrier crosses the capture zone → zone floods team color → banner +
    hold (this ends the game, give it the curtain treatment) → transition to end-card.
  - **RESPAWN**: home-edge materialize + spawn-protection shimmer for its real 24-tick duration.
  - **GAME OVER / END-CARD**: dim → verdict in plain language (capture / wipe / **tiebreak wins name the
    tiebreak** / draw) → final scoreboard with +100s applied → hold forever.
  - **LOBBY→PLAYING**: countdown treatment (engine logs "game starting in N").
- **Tempo levers (Agricogla philosophy, shooter values):** 24 ticks/s base; replay speeds 1–16× exist in
  the engine (`PlaybackSpeeds`). Beats must not truncate below readability at high speed — kill-feed rows
  and banner chips get real hold times; dead mid-game time (both flags home, no contact) is where speed
  collapses.
- **Ambient life:** this game's board is ALIVE by nature (16 moving players) — ambient axis = the set,
  not the pieces: capture-zone breathing, pedestal glow, subtle fog-of-war texture drift on the POV view,
  scorebug leader pulse. Idle systems pause under drama per the reference.
- **HUD/scorebug:** broadcast register (competition/arena per L23): top-band scorebug with team plates,
  lives-remaining aggregate per team (the ACTUAL tiebreak currency), flag-state icons (home/taken ×2),
  clock counting toward the REAL 10,000-tick tiebreak limit, kill feed, and a "score" that is honest:
  **0–0 until someone wins +100** — kills are recorded, never scored.

## 5. Architecture note carried into 0d (thin-client special case)

The shipped viewer is bitworld's generic `global_client.html` — a thin canvas renderer for SERVER-drawn
sprite-layer packets, embedded at COMPILE time (`staticRead`) from the nimby.lock-pinned SHA. The
server-drawn HUD (84×5 scrubber, 7px scoreboard rows, 20px panels) cannot survive 640×360 legibly, and
cannot reflow to portrait. The design decision for 0d: keep the server sprite stream as the **board**
renderer (it already draws the arena, fog, tracers, POV-on-click), and build the **designed broadcast
chrome client-side** in the served HTML (scorebug, kill feed, banners, end-card, transport per TF7),
which requires the client to KNOW game state — via a server-added state/event channel in the packets or
a parallel JSON event stream derived the way `tools/expand_replay.nim` derives its timeline. Both the
board elevation (server sprites) and the chrome (client) are in scope; the split is locked in
REPLAY_DESIGN.md.
