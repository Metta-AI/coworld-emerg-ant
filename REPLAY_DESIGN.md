# REPLAY_DESIGN — Ctf

> Companion artifacts: `DEPTH_TARGET.md` (Phase 0r) + `REPLAY_BRIEF.md` (Phase 0 engine-traced brief +
> fidelity audit). This file is the Phase-2 unlock; the Phase-4 battery grades the build against it.

> ⚠️ **STALE-RULES CORRECTION (2026-07-28, GameVersion 22).** Rule claims here were traced at GV1. The
> timeout **tiebreak no longer exists** (removed GV2, fac8704): `checkMaxTicks` (src/ctf/sim.nim:5589)
> is an unconditional draw, and since GV21 (a768a0e) a time-limit draw pays `TimeoutReward = -1` to every
> player on both teams while a mutual-wipe draw stays 0/0. End-card copy like "tiebreak NAMING the key"
> and "the real tiebreak currency" (sections 5, scorebug, verdict fixture) must be re-based on the two
> draw classes: "mutual destruction" (0/0) vs "time expired — lose-lose" (-1/-1). See REPLAY_BRIEF.md's
> correction banner for the full list of stale claims.

## 1. PLATFORM + ARCHETYPE

Platform **A-plumbing, third-shape**: self-hosted Nim+mummy server (`src/ctf/server.nim`) serving
`/client/replay` + `/replay` WS on the bitworld engine (Crewrift fork). Archetype **#1 spatial arena**
(8v8 CTF shooter, drama on a map). Job = **ELEVATE-BY-REBUILD (L47)**: today the replay routes serve
bitworld's generic `global_client.html`, embedded at COMPILE time (`bitworldClient.serveClientFile`,
server.nim:560–569; `staticRead` in `~/.nimby/pkgs/bitworld/src/bitworld/client.nim:38`).

**Locked architecture (the thin-client split):**
- The **server sprite stream stays the BOARD renderer** — it already draws arena, team-tinted players,
  flags, tracers, splatters, sound rings, aim lines, fog POV. Replay-mode-only observation building may
  be elevated; the LIVE `/global` and `/player` paths stay byte-identical (rendering is outside
  `gameHash`, so determinism/replay hashes are untouched).
- A **new designed broadcast client** `client/replay_broadcast.html` lives in THIS repo, `staticRead`
  into `server.nim`, served for `ReplayClientRoute`/`CoworldReplayClientRoute` instead of bitworld's
  generic client. Single file for the markup/JS/CSS (broadcast_core.js is spliced in at compile
  time); it fetches `font.ttf` and the per-team cog PNGs (`soldier_<team>_front[_gun].png`) as
  separate assets at runtime.
- A **JSON state channel**: the server sends a TextMessage frame alongside the binary sprite blobs to
  replay viewers (tick, maxTicks, phase, team lives, flag states + carriers, per-player roster
  K/D/lives/HP, beat events, winner/isDraw/timeLimitReached, playback speed/playing). Binary = board;
  text = chrome. No bitworld fork.
- **Transport**: DOM controls send the existing chat-char commands (replays.nim:326–370); scrub-to-tick
  + POV-select added as ctf-side text commands (`s:<tick>`, `v:<slot>`) parsed where replayCommands are
  drained (server.nim:1021). Legacy server-drawn replay HUD layers (84×5 scrubber, 20px panels,
  scoreboard) are dropped from REPLAY-mode packets only — the DOM chrome replaces them.

PRODUCT_SCOPE: replay

## 2. REAL CONTAINER TARGET

Measured from `CoworldReplayFrame.tsx` + usage sites (not assumed): League Featured Match
(`LeagueDetail.tsx:1876`) = `aspect-video min-h-[320px] w-full` at detail-column width with
`height="auto"`; Episode detail = `min(680px,72vh)`/420px; standalone defaults `min(900px,88vh)`/360px →
**effective desktop aspects ~1.5 and ~1.9**, floor **640×360**. Phone / narrow middle column ≈390px
wide → the box goes PORTRAIT ~0.5:1.

**Responsive model = ONE fixed-aspect composition (LOCKED).** The board AND every overlay are a single
unit that scales together, so overlays never drift from the graphics inside an arbitrary Observatory
embed container. `#viewport` fills the iframe box (`inset:0`, flex-centered) and `relayout()` sizes an
inner `#stage` in px to the board aspect (1235:659) with a contain-fit; the canvas fills the stage and
`--hudscale = clamp(0.5, 1.6, stageW/760)` derives ALL chrome sizing from the stage width, so scorebug,
kill feed, banner, and transport ride the composition at every size. Leftover embed space is a warm
near-black letterbox (`#120d09`, NEVER pure #000) — not a reflow. This SUPERSEDES the earlier
"reflow-to-stacked-portrait" plan (§6/§8 notes below): a portrait box now shows the full landscape stage
letterboxed and centered, overlays intact, rather than re-stacking. Iframe sandbox =
`allow-scripts allow-same-origin`, no CDN reachable. Verified inside a mock Observatory page
(`tools/mock_observatory.html`, driven by `tools/qa_mock_embed.cjs`) at three window sizes plus a direct
container-shape sweep (2.4:1, 16:9, square, 420×820 portrait, 640×360 floor): at every shape
`stageAspect≈1.87`, scorebug pinned to stage-top, transport pinned to stage-bottom, `--hudscale` tracks
stage width, zero 4xx, zero JS errors — geometry-probed and confirmed by looking.

## 3. ART-DIRECTION LOCK

**One sentence:** a retro pixel arena-shooter broadcast — warm CRT-phosphor pixel action on a warm-dark
broadcast stage, NES pixel type for every number, the two team colors the only saturated channels, amber
for drama.

Palette (warm, never pure #000): stage `#16110d` vignetting to `#241a12`; light text/paper `#f2e8d8`;
structural ink `#2a1f16` (the brand line — all strokes/shadows warm-dark, L31); team vermillion
`#e0523a` / team cerulean `#3f7cc4`; drama amber `#e8a33d`; ghost/fog `#8a7f72`. Framing: the arena
canvas full-bleed center-stage with a soft light pool on the board (L32 — focus, not a literal set);
chrome floats in reserved bands. Type: `nes-pixel.ttf` (already in repo, `data/atlas/nes-pixel.ttf`,
vendored as data-URI) for display + numbers; system sans only for fine print. Register: **broadcast
scorebug** (competition/arena, L23).

## 4. PER-ENTITY PALETTE

Grounded in the engine's own palette (`data/pallete.png`, team tints applied in
`buildSpriteProtocolActorSprite`) + the CTF broadcast grammar (TagPro/Halo research): **Red team**
vermillion `#e0523a`, home = LEFT, reads first in every pairing; **Blue team** cerulean `#3f7cc4`, home
= RIGHT; **carrier** = the highlighted actor — persistent amber aura + the carried banner riding ON the
carrier's BODY (offset to the facing side, `CarriedFlagLift`/`CarriedFlagSideX`, well below the head so it
NEVER floats up into the nameplate) + a **flag marker beside the carrier's nameplate** (`buildCarrierNameSprite`,
`blitNameFlag`), colored for the carried FLAG's own team (a red trooper hauling the blue flag shows a BLUE
marker next to the name) so who-holds-what reads from the label, not just the aura — the marker sits AFTER
the name, never behind it; **flags** = pure team color at full saturation (the most saturated thing on
the board); the HOME/planted banner is drawn `PlantedFlagScale`× bigger (`buildPlantedFlagSprite`, nearest-
neighbor so pixel edges stay crisp) so it reads as a real objective standing on the 96px pedestal, not a
thumbnail; **pedestals** neutral warm stone, glow when flag home; **capture zones** team-tinted edge
washes; **dead/ghost** desaturated `#8a7f72`, splatters dark warm rust; **tracers** hot white-amber
flash fading to team tint; **sound rings** low-alpha paper; **spawn protection** cool shimmer; **the
viewer's slots** marked with a paper chevron. Exact pixel values sampled from `pallete.png` in Phase 1
so chrome matches board.

## 5. RANKED BEAT → SURFACE

| Beat (engine-traced, REPLAY_BRIEF) | Spectator surface that stages it |
|---|---|
| CAPTURE (ends game) → | capture-zone floods team color on board + full-width CURTAIN banner + hold → end-card transition |
| WIPE / final kill → | kill-feed row at curtain weight + "TEAM WIPED" banner → end-card |
| FLAG STEAL → | scorebug flag icon flips HOME→TAKEN with pulse + banner chip "RED FLAG TAKEN" + carrier aura begins + scrubber marker |
| CARRIER KILL + FLAG RETURN (composite) → | feed row marked ⚑ + flag icon flips back with settle pulse + banner chip "FLAG RETURNED" |
| KILL → | kill-feed row (killer ▸ glyph ▸ victim, team-colored; TEAM-KILL badge; same-tick trade renders both rows) + victim lives pip dims + scrubber marker |
| NON-FATAL HIT → | ~player-sized PAINT SPLAT in the SHOOTER's team color lands on the target (`buildHitSparkSprite`, `HitSplatSize`): wet glossy blob + flung droplets + sheen + a same-hue dark contour so it pops off the dark floor. Fades by ALPHA ONLY over `HitFxTicks` (~1.4s) and never darkens toward brown, so it reads as paint not blood, and shooter-color stays legible for enemy-tag vs friendly-fire the whole life |
| RESPAWN → | board rematerialize + protection shimmer (engine 24 ticks); roster row un-dims |
| PHASE Lobby→Playing → | countdown treatment from engine "game starting in N" |
| GAME OVER verdict → | end-card: plain-language HOW (capture / wipe / tiebreak NAMING the key + values / draw kind), final roster with +100s applied, momentum ribbon, hold forever |

## 6. ART MANIFEST + PROVENANCE

ART_PROVENANCE: mixed · **COUNT: 7 wired board-art subjects (server-streamed) + 16 reused crew sprites**

> **Correction (art-batch pass).** The first build RECOLORED the procedural arena (flat rect/diamond/disc/
> chevron shapes on a flat-fill floor) and counted SVG chrome as "art" — the dashboard-reskin failure the
> lessons name (PD3/L57; a flat-rect board + one backdrop is NOT the bar). Cogs vs Clips is the bar: a
> textured excavated-stone floor, ILLUSTRATED 3-D cover objects, a diegetic in-world panel. The board
> renderer already loads real `.aseprite`/`.png` assets and `loadMapLayers` builds the floor as a `pixie`
> Image, so generated art composites straight into the server-streamed board. This manifest is the batch.

**BOARD ART BATCH — generated (nanobanana), the primary batch (7 wired subjects).** Style sentence locked
for coherence across the batch: *"hand-illustrated painterly game-art, warm torch-lit dungeon palette (warm
charcoal-brown, ember-orange rim light), STRICT TOP-DOWN orthographic bird's-eye view from directly
overhead — minimal side face, flat-lay footprint — soft ambient-occlusion contact shadow, isolated object
on a plain flat dark background, no text no border."* All seven are wired in `sim.nim:loadMapLayers` and
composited into the server-streamed board (see the WIRING note below); each verified by looking:
- **Floor texture** `data/arena_floor.png` — seamless flagstone, fine cracks + rubble. Tiled per non-wall
  pixel via `tileSample`. No flat half-board territory wash (L98 #4 — a translucent tint over an entire
  half muddied the floor into "gradient columns"); broad team identity stays diegetic (pedestals + flags +
  scorebug).
- **Capture endzones** (`endzoneColorAt` + `emberThroughCracks`) — the ONE deliberate floor tint, confined
  to the narrow score-columns from `checkWinConditions` (Red `x≤teamHomeX(Red)+20`, Blue
  `x≥teamHomeX(Blue)−20`; a live carrier scores the instant its center-x crosses the threshold, at any
  height). Painted IN the floor (not HUD chrome) so it rides the board sprite and scales with the locked
  composition (§2). This is the OPPOSITE of the removed flat wash: team ember seeps up only through the
  DARK crack/seam pixels (luminance-gated, cubed) with a home-anchored falloff — brightest at the pedestal
  edge, dimming toward a crisp solid team **capture line** at the exact threshold x a carrier must cross.
  Lit stone faces keep their flagstone hue, so it reads as "the pedestal lighting its endzone", not a
  gradient column. Cosmetic over `mapImage` → collision masks + `gameHash` untouched; verified legible from
  the 1400-wide stage down to the 640×360 floor.
- **Walls = ONE procedural carved-stone material** (`carvedStoneColor`, not a texture PNG). Every wall pixel
  — border frame, `shapeRect` stub, `shapeDiamond`, `shapeDisc`, `shapeDiagonal` chevron alike — is shaded
  from its distance to the nearest floor pixel: a warm-ink carve line at the floor seam, a graded highlight
  on up-left faces, a graded shadow on down-right faces, flat face inside. Because the shading is derived
  from the collision mask, **the art matches every collider EXACTLY and is identical on both halves by
  construction** (Gungeon/Nuclear-Throne top-down convention). This REPLACED (a) the old side-view brick
  `arena_wall.png` tiled into the mask — its brick course sliced mid-pattern at shape edges → "torn ribbon"
  chevrons; and (b) three clashing prop sprites blitted as squares over non-square colliders
  (`crate.png`/`machinery.png` on diamonds, `barrel.png` on discs) — a per-side crate-vs-pipe split because
  the crate/machinery alternation ran over the flattened `[left, mirror, …]` list.
- **Pedestal red** `data/ped_red.png` + **Pedestal blue** `data/ped_blue.png` (→ flag homes) — carved
  stone dais, glowing team-emblem inlay, top-down. The only cover-object blit that remains.
- Reuses (existing, kept): 16 team-tinted crew sprites `data/spritesheet.aseprite`, flag/self/splatter/tracer/
  sound-ring/aim-dot/fog sprites (`global.nim`), palette, fonts.

> **WIRING — server-streamed board (A-plumbing third-shape, §1).** Unlike an R1 client-inlined renderer,
> this platform's board art is composited into `mapImage` inside `sim.nim:loadMapLayers`, flows to the
> true-color `mapRgba` buffer, and streams to the broadcast client as the single `MapSpriteId` sprite
> (`global.nim:buildMapSpritePixels`). The art is therefore wired in Nim source + `data/*.png`, NOT inlined
> in `replay_broadcast.html`. The battery's A15/A16 scan the CLIENT source only, so they read 0 client-inlined
> assets by construction; the authoritative art-depth gate for a server-rendered board is the RENDER pass
> **A22 board-not-blank** (PASSES, 326KB painted frame) plus the by-looking verification at all four §2
> aspects. Collision (walk/wall masks) is byte-identical to the pre-art build — the art is cosmetic over the
> exact same geometry, so determinism/replay hashes are untouched.

> **ART-BATCH VERIFICATION (adversarial pass, 2-auditor).** An independent board-art audit re-captured the
> live board at ticks 300/1400/2000 and confirmed all four reported defects RESOLVED: walls are ONE coherent
> carved-stone material, symmetric across the midline and matching every collider (rect/diamond/disc/chevron)
> by construction; the crew is a weaponless symmetric top-down trooper (the game's aim-dots are the sole gun —
> no baked second gun, no phantom on flip); the floor is clean flagstone with no "gradient column" territory
> wash; the whole board passes the squint test as a warm torch-lit arena (warm ink, no pure #000/#fff).
> Verdict: SHIP. A separate chrome/responsiveness pass confirmed **no JS errors** and correct landscape
> render at ~1.9 and ~1.5, and — verified directly against the fixture event ledger — the banner + scorebug
> flag-flip fire correctly at the real steal tick 1646 ("BLUE FLAG TAKEN", carrier tag, scrubber marker). Two
> of that pass's "empty feed / empty banner" flags were SEEK ARTIFACTS, not defects: `capture-seed7` carries
> zero Kill events (only joins + 2 steals + 1 capture), so an empty kill feed is correct data; and the clock's
> "WAITING FOR PLAYERS" reading was captured at ticks 0–303, before players join at tick 465. The one
> chrome finding that pass raised — *portrait ≈390px left the board at its native landscape aspect with
> dead space below* — has since been RESOLVED by the fixed-aspect-composition rework (§2): the whole
> replay (board + overlays) is now one locked unit that scales together and centers with a warm letterbox,
> so a portrait box is intended landscape-letterboxed, not a defect. The earlier §8 "reflow to stacked
> portrait" idea is superseded.

**Chrome — authored SVG/CSS in the client (28), NOT counted as generated art.** Scorebug plates, 4
flag-state icons, clock pill, squad pips, kill-feed glyphs, banner chips, capture curtain, end-card +
4 verdict badges, 7 transport icons, speed strip, 3 beat-marker glyphs, momentum ribbon, POV badge,
capture-chase gauge. These carry the broadcast register; the BOARD batch above carries the art depth.

## 7. CHOREOGRAPHY GRAMMAR

Spatial-archetype grammar = interpolated locomotion → impact → objective consequence. **Locomotion is
engine-native**: the server streams every 24Hz tick of continuous movement (no sparse frames to lerp —
the sim IS the interpolation; L6 satisfied at the source). Chrome beats are staged sequences, each with
a read-hold, never a bare CSS fade:

- **KILL**: board tracer flash (engine) → feed row slides in from edge with overshoot → 250ms settle →
  victim's roster pip dims → row holds ≥2.4s at 1× before scroll-away.
- **STEAL**: flag lifts onto thief (board) → scorebug icon flip (3-frame pixel flip + pulse) → banner
  chip pops (overshoot → 60% hold → fade) → carrier aura persists until return/capture.
- **RETURN (composite with the kill)**: feed row ⚑ + flag arcs home on the scorebug icon → settle pulse.
- **CAPTURE**: zone flood (board) → curtain slams in (dim + card pop, 74%-hold like the reference
  curtain) → end-card crossfade.
- **RESPAWN**: shimmer for the engine's 24 protection ticks; roster row re-lights.
- **END-CARD**: dim → verdict line types on → roster finalizes with +100 counting up → holds forever.

## 8. HUD LIST + REGISTER

Register: **broadcast scorebug** (arena game). Panels, each in a **reserved slot** so the layout never
jumps on a quiet frame (L84):

1. **Top band scorebug**: team plates (name, TEAM LIVES aggregate — the real tiebreak currency, F1 —
   as pips+numeral, flag-state icon), center clock pill counting to `config.maxTicks` tiebreak (F3,
   honest label "TIEBREAK IN M:SS") + phase.
2. **Kill feed**: bottom-right column (clear of the scorebug above + transport below), `column-reverse`
   so the newest kill sits lowest, fixed 4-row reserve, team-colored rows. Rows size to CONTENT and are
   right-anchored (grow leftward), so full player names show WITHOUT ellipsis truncation; leftward growth
   is bounded by a compact pixel font (`8 * var(--u)`) + the pre-bounded 10-char `shortName()`. All in
   `--u` units → scales with the board (verified full-name at desktop 1330×700 and the 640×360 floor).
3. **Banner lane**: one reserved center lane under the scorebug for beat chips (steal/return/wipe);
   capture uses the full curtain.
4. **Roster rails** (wide aspects only): 8 per side — name, lives pips, K/D, carrier/dead state; click →
   POV inspect (fog honesty lens, `v:<slot>`). Collapses into tap-roster on portrait.
5. **Transport**: bottom bar — play/pause, restart, −1 tick, +5s, end, loop, speed chips 1–16×, and a
   **click-to-seek scrubber** with beat markers + a **lives-lead momentum graph** (L44); fully
   CLICKABLE (TF7), keyboard shortcuts mirrored. The momentum graph is an SVG step-line + difference
   shading on the SAME `tick / maxTicks` x-axis as the seek track (0→full timeline), so a point's x IS
   its tick and the playhead crosses it 1:1 with the timeline — Red-lead deflects above an even-lives
   midline (red fill), Blue-lead below (blue fill). Samples are keyed by tick and accumulate for the whole
   replay (deterministic), NOT a scrolling observed-window, so the curve stays put while only the playhead
   moves — this REPLACES the earlier rolling-60-cell ribbon whose `(t−firstObserved)/(lastObserved−…)`
   axis scrolled/rescaled independently of the timeline (read as noise). All in `--u` → scales with the
   board; verified axis-exact (curve endpoint == played tick, playhead% == seek%) and static-when-paused
   at desktop 1330×700 and the 640×360 floor.
6. **End-card** (owns the frame at GameOver).

**Bounded-embed plan (L82/L83)**: the whole replay is ONE fixed-aspect composition (§2) — the board and
every overlay scale together as a locked unit, so overlays never drift from the graphics regardless of
the embed container. `--hudscale` is computed off the contain-fit `#stage` width (proportional to the
CONTAINER, not the viewport); a portrait box centers the landscape stage in a warm letterbox rather than
re-stacking. Verified in a mock Observatory page (League `aspect-video min-h-[320px]`, Episode column,
narrow single-column) and a shape sweep down to the 640×360 floor and a 420×820 portrait.

## 9. PERSON/ROLE MODEL

Not applicable: team arena shooter — no hidden roles, no person-vs-card split. The only hidden
information is fog-of-war vision, handled as the POV-inspect lens (§8) and audited in §13/F5.

## 10. DRAMA-COMPLETE FIXTURE

Existing `tests/replays/ctf.bitreplay` expands to ZERO events (verified via `tools/expand_replay.nim`)
— cert fixture only, unusable. Phase 1 records real full-scale episodes: `COGAME_HOST=0.0.0.0
COGAME_PORT=2000 COGAME_CONFIG_URI=file://$PWD/config.json nim r src/ctf.nim` + 16 baseline bots
(`players/baseline`, `ws://localhost:2000/player?slot=$i&token=0xBADA55_$i`) with the replay writer on;
verify with expand_replay that ≥1 fixture covers Kill, FlagSteal, FlagReturnHome, Capture, Respawn,
PhaseChanged, ScoreChanged, GameOver-by-capture (re-seed/re-run until a capture ending lands; baseline
bots are built to convert steals into captures). Additionally record a `maxTicks:300` short-config
fixture to exercise the TIEBREAK/draw end-card (certification config proves 300 works), and keep a
wipe-ending fixture if one occurs. Every §5 beat exercised ≥1× across the fixture set (PD7).

## 11. TEMPO + AMBIENT PLAN

Both levers, reference philosophy at shooter values: **animFactor cap** — chrome beat animations never
play faster than 2× no matter the replay speed (feed rows, icon flips, banners keep read time at 8–16×);
**dwell floor** — beat holds have minima (feed row ≥2.4s-equivalent, banner ≥1.8s, curtain ≥2.4s,
READ_PAUSE ≥600ms) and speed collapses only the dead time between contacts (both flags home, no
tracers). Board tempo is the engine's own 24Hz. **Ambient life** (idle systems, paused under beats,
`prefers-reduced-motion` honored): pedestal glow breathe, capture-zone low wash pulse, scorebug leader
pulse when lives lead ≥3, CRT grain drift on the stage backdrop, clock pill soft tick. The 16 moving
players ARE the board's life; ambient dresses the set only.

## 12. GENRE_RESEARCH

Researched this run (agent dispatch): **TagPro** competitive fans' vocabulary — grab/cap/return/snipe/
regrab/contain; carrier gets a persistent outline; scorebug = caps + countdown clock with flag icons on
team names; the signature moment is the **snipe → regrab → cap chain** ("the flag run" — a carrier
surviving the chase). **Halo/TF2 broadcast grammar** (the genre-peer spectator UI we borrow): top-center
scorebug with per-team flag-state icons, event banners with 1–3s holds ("X has the flag!", "TEAM
SCORES!"), corner kill feed `killer [glyph] victim` with carrier-kills highlighted (we place ours
bottom-right, clear of the scorebug). **Fog-honesty
precedents**: SC2 observer + Dota spectator expose per-player vision on demand (toggle/lock-to-player)
while the default cast stays omniscient — exactly our POV-inspect model. Players of the source genre
find the CARRIER CHASE dramatic above all; the broadcast therefore spends its strongest highlight on
the carrier (aura + feed weight + curtain on capture).

## 13. FIDELITY_AUDIT

Full audit table in `REPLAY_BRIEF.md` (F1–F10), engine-traced. Headlines: **kills are never score** —
scoring is win-only +100 (sim.nim:72,2766); the standing axis is team lives + flag state (the actual
tiebreak keys, sim.nim:2860–2880). **No dropped-flag state exists** — carried or home only; no drop
iconography (invented-mechanic trap L17). **The clock is a REAL limit, not a safety cap** —
`checkMaxTicks` runs a lives→progress tiebreak, so a countdown labeled with its consequence is honest
(L75); the end-card names the tiebreak key (L76), checking `isDraw` before `winner` (a draw stores
winner=Red internally). **No flag arrows / global tracking** — fog replaced intel; nothing may imply
players see what the omniscient cast sees (L77/F5); fog honesty = POV-inspect. **Friendly fire ON** —
team-kills marked; **same-tick trades** render both kills; multi-kill tick attribution derived from sim
state per-victim, degrading honestly to "traded" if ambiguous (F7). No chat surface (chat recorded but
never applied, replays.nim:209).

## 14. CONTRACT COVERAGE

Chain: **writer** = server-side input recorder (`openReplayWriter` server.nim:784, `.bitreplay`
COWLDCTF v1) → **primary** = our broadcast client at `/client/replay` (server re-simulates
`stepReplay`+hash-verifies, streams board packets + JSON state) → **fallback** = board-only degradation
(binary sprite stream renders even if a state frame is missed; chrome hydrates on next state frame;
missing state entirely → board + transport still usable) → **live** = `/global` spectator keeps
bitworld client + unchanged packets (replay-mode-only divergence; live game byte-identical).

| Field | writer → primary → fallback → live | Assertion |
|---|---|---|
| winner/isDraw/timeLimitReached → | sim finishGame → state JSON → end-card verdict; fallback: board freeze on GameOver phase | fixture: capture-end + tiebreak-end cards render correct verdict text |
| team lives → | re-sim per tick → state JSON → scorebug pips/numerals; fallback: roster dims from board only | fixture: pip count equals expand_replay death ledger at 3 sampled ticks |
| flag state/carrier → | sim.flags carrier diff → state JSON → icon flip + carrier aura | fixture: steal tick flips icon within 1 tick; return restores |
| kills (incl. team-kill, trade) → | per-victim sim diff server-side → state events → feed rows | fixture: feed rows == expand_replay Kill events, team-kill flagged |
| tick/maxTicks → | sim.tickCount + config → state JSON → clock pill | clock shows config-derived limit (10000 main / 300 short fixture), never hardcoded |
| transport/seek → | chat-char commands + `s:<tick>` → applyReplayCommand/seekReplay → keyframe restore | scrub to tick N lands within keyframe interval; play/pause/speed reflect in state JSON |

Risk checkpoint (Phase 2): confirm whether viewer WS blobs are snappy-compressed; if so, vendor the
decoder inline in the client (no `/client/snappyjs.min.js` fetch through the proxy).

## 15. WHOLE-PRODUCT SURFACE MATRIX

Not required — PRODUCT_SCOPE: replay (§1). Live/player/global surfaces are explicitly out of scope and
guarded unchanged (§14 live column).
