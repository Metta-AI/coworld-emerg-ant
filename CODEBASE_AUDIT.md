# coworld-ctf codebase audit

*2026-08-01. Method: six parallel subsystem audits (sim.nim, global.nim, server/replay/support modules, client + replay-viewer, tools/scripts, tests/players) plus an independent external review, with every dead-code and drift claim re-verified by direct grep/diff against this worktree. Claims that did not survive verification are listed in the appendix, not in the body.*

## Verdict

You would not rewrite this codebase. The fundamental bets — Nim, input-based replays with per-tick hash verification, re-simulation everywhere, semantic label observations — are working, and the determinism engineering is genuinely strong. What you would change is where the seams are: the sim wants to become a headless, asset-free core instead of a two-file monolith; the policy observation wants to become a schema'd protocol instead of a rendered scene; and everything that exists today in two-plus hand-synced copies wants a single source of truth. Alongside that: ~1,100 lines of provably dead Nim, a stale-tool population, and several live config/docs/CI drifts — including one where **the hosted league plays different rules than every prose document describes**.

## What's genuinely good (keep in any restart)

- **Determinism/replay engineering**: explicit-field `gameHash` with GameVersion gating, two-stream RNG discipline (endzone archetypes on `seed xor const` so draw order never shifts), `mapSpec` pinning so generator changes cannot break old replays.
- **The contract modules**: `labels.nim` (zero-import observation vocabulary with a golden-manifest test), `events.nim` (one serializer shared by the live sink and the offline extractor — itself the fix for a previous duplication), and `replay_runtime.nim` (a 117-line seam that is the reason the wasm viewer adds zero renderer duplication).
- **Incident-driven hardening**: the wasm32 CI smoke job, `tools/ci/next_coworld_version.py` with its outage postmortem baked in, comments citing production failures.
- **Hygiene**: zero TODO/FIXME markers, no commented-out code, no `when false:` blocks, no orphaned test files (all 49 wired into CI shards), docs actively maintained.

---

## 1. Dead code to remove (all verified by independent grep)

### Whole files nothing imports (~700 lines, all untouched since the initial commit — Crewrift-fork residue)

| File | Lines | Note |
|---|---|---|
| `src/ctf/ais/` (openai, bedrock, claude, xai, gemini) | 445 | Zero importers; no config field can select a backend. The only live LLM use is the baseline bot's own Bedrock client in `players/baseline/baseline/taunts.nim`. `gemini.nim:19` also puts the API key in a URL query string. |
| `src/ctf/common/pathfinding.nim` | 150 | The baseline bot built its own, different pathfinder. |
| `src/ctf/texts.nim` | 96 | Only "texts" hits elsewhere are prose comments. |
| `src/ctf/common/scales.nim` | 11 | Drags in the `windy` desktop-windowing dependency. |

### Dead symbol clusters in live files (~200 lines)

- **`global.nim` pre-rig actor render path**: `crewSpriteForSlot` (:963), `buildSpriteProtocolActorSprite` (:1292), `buildCrewProtocolActorSprite` (:1332), `spriteActorSpriteId` (:3859), plus transitively-dead helpers `isSolid` (:1286), `crewSpriteIsSolid` (:914), `putCrewPixel` (:921). Superseded by the articulated-rig path.
- **`sim.nim` zero-reference symbols**: `MapVoidColor` (:213), `RigSegCount` (:1529), `ScoreboardRightLayerId/Type` (:431), `SelectedTextSpriteId` (:446), `SelectedViewportSpriteId/ObjectId` (:447/:450), `SpriteDrawOffX/Y` (:194), `asciiIndex` (:5294), `findSpawn` (:6420), `blitCenteredAsciiText` (:5307) + transitively `blitAsciiText` (:5298).
- **`hud:on`/`hud:off` viewer command is a vestigial no-op**: only sets `GlobalViewerState.broadcastHud` (`global.nim:1246`), which nothing reads — chrome moved to the unconditional binary channel. Remove flag, handler, and the client send (`replay_broadcast.html:1421`).
- **`server.nim` dead routes**: the four top-down `soldier_<team>.png` routes (server.nim:98–102) have no consumer; clients fetch only `_front`/`_front_gun`, and the JS fallback never requests the top-down file despite the server comment claiming otherwise.
- Minor unexport candidates: `replays.nim` `ReplayKeyframeTicks`/`ReplayEndHoldSeconds`/`resetReplay`/`ReplayKeyframe`; `server.nim` `generatedPlayerName`/`anonymousPlayerIdentity`/3-arg `hasPlayerCredentialParams`; `global.nim` `ShoutLinger` type exports. ~124 of 428 `sim.nim` exports are internal-only (low-value churn to fix; note enum-member and field-type caveats before unexporting types).

### Broken / machine-specific tools

- `tools/dump_hd_preview.nim` — **cannot compile**: imports `../src/ctf/hd`, which does not exist.
- `tools/replay_diverge.nim:4` — hardcodes `setCurrentDir("/Users/daveey/code/coworld-ctf-hd")`, a different checkout.
- `tools/ladder/ctfapi.py:11` — hardcodes `/Users/maxwellstarr/projects/...`, another person's home directory.
- `tools/ladder/heals.py` — requires `/tmp/medcheck/extract_events` built "from the GV23 lab worktree" (a deleted temp worktree); its `in_range` filter is also a no-op (computes the round number, then unconditionally keeps every event).
- `tools/taunt_driver.nim` — requires a `mock_sidecar.py` that is not in the repo.
- `tools/render_plasma_frame.nim` — byte-level clone of `render_frame.nim` (17 diff lines of 124), still carrying the original's doc header and an irrelevant tracer-crop epilogue.
- `players/baseline/coplayer_manifest.json` — referenced by nothing in-repo, resource numbers contradict the live manifests. Confirm no external `coplayer` CLI consumes it by path, then delete.
- **~32 of 56 tools are referenced nowhere** (the forensic probe family: aim/blue/carrier/diamond/fov/glowfade/nade/spray×4/stain/stuck/window probes, movie renderers, etc.). Cheap to keep individually, but they rot silently: three probes hardcode `array[16, ...]` and silently truncate 32-player colossal replays; `window_audit.nim:1` still claims a GameVersion-13 contract at GV32. Delete the broken/machine-specific ones outright; triage the rest.

### Dead assets and docs

`client/art/badge_backstab.png`; `data/letters.png`, `data/numbers.png` (+ `.aseprite`); `data/logo.png` (one design-doc mention, zero code refs); `data/tiny5.aseprite` (the font actually used is bitworld's embedded copy); `art-direction-research.md` (repo root, referenced by nothing).

### Dead client branches

- `broadcast_core.js:505` `0x07` parse branch — no such message type in the pinned bitworld protocol.
- `broadcast_core.js:445` uncompressed-sprite fallback — advances the wrong byte count; if it ever fired it would desync. Better to fail loudly.
- Vendored SnappyJS **compressor** (~⅓ of the blob) — only `uncompress` is called.
- `websocketPathForClientPage` mappings for pages never served with this file (`/client/rewards`, `/client/admin`, `/client/global`, `/client/player`).
- `.feed-row .badge.carrier` CSS rule (no code creates it); write-only `maxTick` (`league_replayer.html:511`); `endcardWinCondition` non-draw time-limit branch (unreachable — `checkMaxTicks` is always a draw in the current sim).

---

## 2. The duplication ecology

- **Tests**: `initCtfForTest` copy-pasted **36×** (~320 lines), `const GameDir` 43×, `twoTeamGame()` 11×, plus a dozen smaller repeated helpers (`buildGlobalMessages` ×4, `segmentBlocked` ×3, `chargeAndThrow` ×3, ...) — several byte-identical (diff/hash-verified). One `tests/helpers.nim` absorbs ~600–700 lines.
- **Tools**: 18 of 19 replay-loading tools re-implement boilerplate that `replay_runtime.initReplayRuntime` already encapsulates (only `replay_config_dump.nim` uses it). The chdir dance ×15, the sprite-packet→PNG compositor ×9 independent implementations, `spriteToImage` ×3 identical. A small `tools/toolutil.nim` collapses most of it. Also: `record_*.sh` share scaffolding but only two got the port-wait robustness fix (`record_fixture.sh` still uses bare `sleep 1.5`); the five `qa_*.cjs` share a copy-pasted preamble and require an undocumented `tools/.qa` Playwright install.
- **Two full browser chromes**: `replay_broadcast.html` and `league_replayer.html` hand-mirror a large helper family — team tables, clock (same "Honest countdown" comment), momentum graph, scrubber/beat markers, transport wiring — several carrying the literal comment "Mirrors replay_broadcast.html". Extract a shared `chrome_common.js` inlined the same way `broadcast_core.js` already is.
- **Three parallel derivations of the kill/steal/capture/phase story**: sim's tier-2 `emitEvent` sink; `broadcast.nim stepEvents` state-diffing (header: "mirrors tools/expand_replay.nim exactly" — by hand); `expand_replay.nim`'s own diff pass. Byte-consistency is maintained by discipline plus one test.
- **`sim.nim` internal**: the pickup quartet (`tryPickup{Grenades,MedKits,Shields,PlasmaArcs}`), the respawn-refill triple, the reset quartet, near-duplicate spawn-point pair, `rigGunPixels`/`rigSprayCanPixels` pair, 7 near-identical FX prune loops in `step`, axis-swapped `canSlideHorizontal/Vertical`. (Refactor byte-identically; `gameHash`/GameVersion gate replay compat. In passing: `startGame` calls all resets *except* `resetMedKits` while `initSimServer`/`resetToLobby` call all four — confirm intended.)
- **`server.nim` internal**: pending-join resolution loop twice (:1274 vs :1434), per-player frame-send block twice (:1486 vs :1572) — and the reset-path copy **lacks the `try`/`markSocketClosed` guard**, so consolidating fixes a latent silent-failure path.
- **Cross-language constants synced by comment only** (drift table verified): chrome sprite id 4090, `PlaybackSpeeds` [1,2,3,4,8,16] (+ speed-char map), 24 fps, board 1235×659, `ShotFxTicks` 12, `TrailFalloff` 1.6, seat-suffix regex, the full command vocabulary, and the entire state-JSON schema — all re-typed in both HTML files. Nim-internal versions of the same disease: `MaxSmoothStepTicks = 16` (global.nim:6137) duplicating the top of `PlaybackSpeeds`; `ChunkCap` (frame_size_audit.nim:26) mirroring `MaxWsFrameBytes`; the Bedrock model ID duplicated between `taunts.nim` and (dead) `bedrock.nim`; `replays.nim`'s speed mapping duplicated within itself (:547 vs :637).
- **Resolved 2026-08-06:** one `coworld_manifest_paintbot.json` now serves both leagues; CTF variants are namespaced in the Paintbot schema.

---

## 3. Architecture

### 3.1 The monolith

`sim.nim` (9.8k lines, 366 procs, touched by 163 of 501 commits) + `global.nim` (6.4k) hold ~79% of `src/`. `SimServer` is a god object mixing hashed gameplay state, render assets (crew sprites, fonts, map RGBA, dark-bg pixels), FX seqs, and analysis channels — you cannot construct a sim without the art pipeline, which blocks fast property tests, fuzzing, and training-speed self-play, and already caused the >2 GB keyframe wasm incident (fixed by stripping bakes, PR #189, rather than by separating the state). ~18 process-global mutable map vars (`MapWidth...`, `Arena*`) make "one map per process" a comment-enforced invariant, installed by an **import-time side effect** (`selectCtfMap(arenaCtfMap())`, sim.nim:4204).

The seams are already clean (sole-consumer verified by grep):

| Candidate module | Lines | Sole consumers today |
|---|---|---|
| Broadcast-only art (soldier/rig/cog-drive, sim.nim 1328–1965) | ~640 | global.nim + preview tools/tests; explicitly "no sim state, no GameVersion bump" |
| Procgen generator + validators + mapSpec (2864–4151) | ~1,300 | tools + map tests; gameplay only via `loadCtfMap` (`generateMapAttempt` alone is one 579-line proc) |
| Map art bake (4442–5316) | ~875 | global.nim + one tool |
| Config parse/serialize (5317–5863) | ~550 | everything, but self-contained |
| Join/roster/reward machinery (6449–7020) | ~570 | server.nim only |

**Target layering** (external review's framing, consistent with all the evidence): `core` (rules + fixed-point math + hash, zero asset deps) / `mapgen` / `obs` (fog + the observation-shaping rules, see 3.2) / `render` / `server`, with the hashed state as its own small struct. Enabling first move: an explicit `arena.nim` owning the installed-map globals, killing the import-time side effect.

### 3.2 Rendering is the API

Policies observe rendered sprites plus label strings, so the sprite emitter is load-bearing for gameplay: two published observation rules are implemented in the renderer — `fuzzedAimBrads` (global.nim:1513, ±14-brad aim fuzz held per ~12-tick window) and `shotImpactOffset` (global.nim:1531, the jittered shot-impact reveal). And the observation is lossy in ways bots must route around: **a bot's own aim angle is not observable** — `baseline.nim:1303`: "Our own aim is PURE dead reckoning: the observation carries no absolute [aim]" — so the reference bot open-loop-integrates its own turret (`estAim`, baseline.nim:338). The hard client knowledge (aim dead-reckoning, frame-drain semantics, ready pacing) lives as comments in `baseline.nim`, not in `docs/PROTOCOL.md`.

A schema'd semantic observation protocol (typed entities, own aim included), with pixels for spectators only, dissolves the label-fragility class, the ~530-line protocol-client tax on every non-Nim policy, and the folklore traps at once. Short of that: move `fuzzedAimBrads`/`shotImpactOffset` into the sim/obs layer, add own-aim to the observation, and promote the baseline.nim folklore into PROTOCOL.md.

### 3.3 Make the contracts structural

- **`labels.nim` is bypassed by its own producer**: half its vocabulary consts have zero external references because `global.nim` hardcodes the same strings at ten verified sites (`"corpse "`, `"blast stage "`, `"weapon "`, ...) and the baseline bot builds its own. Switch producer and consumer to the consts; the golden-manifest test then guards the const table instead of coincidence.
- **One chrome protocol source**: generate a JS constants file from Nim at build time (or carry constants in the init packet), and converge the beat stream onto the tier-2 event sink (or share the diff code) to collapse the three parallel event derivations.
- **Replay-viewer bundle**: `--preload-file data@data` ships the entire ~13 MB `data/` (including `.aseprite` masters and the dead assets above) to every browser viewer. Also `Dockerfile.replay-viewer:31` copies only red/blue soldier art while the board requests all four teams — in the static bundle green/yellow 404 and GV32 4-team replays silently lose PiP cog art (CI dist assertions also check only red/blue).

---

## 4. Config / docs / CI drift (live, user-visible)

1. **The hosted league played 45° vision while every prose source said 60°. Resolved 2026-08-01:** the owner confirmed 60° is intended and every variant now pins 60°.
2. **The CTF schema lacked Paintbot's four-team fields. Resolved 2026-08-06:** both leagues now use the Paintbot superset schema.
3. **A red test run did not stop the CTF upload. Resolved 2026-08-06:** the single Paintbot upload runs only after the test workflow succeeds on current `main`.
4. Doc drift, minor: REPLAY_DESIGN.md calls the broadcast client "single self-contained file" (it fetches font.ttf + up to 8 PNGs); `window_audit.nim` claims GV13; `render_plasma_frame.nim` carries `render_frame`'s header; the server comment claiming top-down PNGs are a live fallback.

---

## 5. Bugs found in passing

- Reset-path frame send missing the socket-close guard (`server.nim:1572` vs the guarded main-loop copy at :1486).
- League shell handles an `esc` postMessage the board never sends (`league_replayer.html:526`) — Esc does nothing while focus is inside the board iframe.
- `syncBoardAspect` (league:345) reads `boardW/boardH` fields never emitted — the theater aspect is permanently the 1235×659 default, contrary to its comment.
- `broadcast_core.js:180` forwards `name`/`slot`/`token` query params onto viewer sockets, where the server 403s them — foot-gun for embedders.
- Three forensic probes truncate replays with >16 seats silently (`array[16, ...]`).
- `tools/ladder/heals.py` `in_range` is a no-op (round-range parameters filter nothing).

---

## 6. Ranked roadmap

**Cheap wins (no restructuring, each a small PR):**
1. ~~Fix the 45°/60° drift~~ — done on this branch (owner confirmed 60°; manifests changed 45 → 60).
2. Gate `upload-coworld*.yml` on the test workflow.
3. Delete the dead code of §1 (mechanical; `nim check` + test shards prove it).
4. Add `teams`/`scoring` to the ctf manifest schema (or document the lockout as intended).
5. Promote the baseline.nim protocol folklore into `docs/PROTOCOL.md`; add own-aim to the observation.
6. De-hardcode `tools/ladder/` (paths to another user's home dir and a deleted temp worktree); fix the `heals.py` no-op filter.
7. Fix the `server.nim` reset-path socket guard while consolidating the duplicated blocks.

**Consolidation (pure refactors):**
8. `tests/helpers.nim` (~600–700 lines back). — **done** (−760 lines, 44 files)
9. `tools/toolutil.nim`; delete `render_plasma_frame` clone. — **done** (≈−200 lines, 24 tools; `initReplayRuntime` adoption deliberately rejected: it starts at the post-lobby tick and would shift every probe's tick numbering)
10. Wire-constants single-sourcing from Nim. — *revised*: full chrome unification is **reclassified as a redesign needing product review** — a whitespace-normalized diff shows all 31 mirrored functions between `replay_broadcast.html` and `league_replayer.html` have diverged (zero byte-identical), so a shared module is a semantic reconciliation of a product surface, not an extraction.
11. Make `labels.nim` the actual producer vocabulary. — **done** (engine + baseline bot both call the builders)

**Structural (each wants its own design pass):**
12. Split `sim.nim` along the verified seams. — **done** (stages 1–5 of docs/plans/2026-08-01-sim-split.md: sim.nim 9,828 → 2,827 lines of pure gameplay across sim_types / rig_art / arena / map_art / sim_config / sim_state / roster, acyclic DAG, zero consumer changes, warning-clean imports). Remaining follow-ups, deliberately deferred: stage 6 (explicit map init instead of the import-time default-arena install) and hashed-state-as-own-struct (a GameVersion-bump project).
13. Schema'd semantic observation protocol for policies; move `fuzzedAimBrads`/`shotImpactOffset` into the obs layer. — *needs a product decision; not attempted autonomously.*
14. Single-source the two league manifests (generate both schemas from `GameConfig`, validate `config.json` in CI). — *needs a product decision on the generation direction; not attempted autonomously.*

---

## Round 2 (2026-08-01, post-fix re-audit)

Two fresh agents re-audited the finished tree: a cohesion audit of the split
modules and an adversarial regression scan of the whole branch diff
(instructed to trace, not to confirm). Everything they confirmed was fixed
in the same round:

**Fixed:**
- **CI upload pwn-request path**: the `workflow_run` `branches` filter
  matches the triggering run's *head* branch, so a fork PR from a branch
  named `main` could have fired a production league upload — with repo
  secrets — of unreviewed fork code. The upload workflow now requires
  `event == 'push'` and `head_repository == this repo`, plus a freshness
  step that skips (with a `::notice::`) when the certified SHA is no longer
  main's HEAD (re-running an old green run must not republish old code).
- Module cohesion: hashed spinning-diamond geometry moved out of the art
  module into `arena.nim`; endzone colors deduped into `sim_types` (cutting
  the hash module's dependency on the art bake); `overTint`/`distSq`
  rehomed; dead `actorColor` deleted; the `placeWalkablePickups` template
  no longer re-evaluates its targets expression per use.
- Stale post-split docs: AGENTS.md layout section, sim_types/map_art
  headers, the replays.nim PlaybackSpeeds note, the plan doc's as-built
  deviations, and a build.yml warning about the by-name workflow coupling.

**Verified faithful by the regression scan** (no action): the sim template
dedup (exact mutation/event/log ordering), the labels adoption
(byte-for-byte), wire-constants rendering (`1.6` renders and parses
identically), the server admission interleave change (replay bytes
identical), and the sim split itself (`--color-moved` sweep: only headers,
imports, re-exports, and `*` additions differ from pure moves).

**Accepted, deliberately not churned:**
- ~40 exported symbols referenced only inside their own module (catalogued
  by the re-audit; most predate this branch). Un-exporting is API churn
  with no behavioral value; revisit opportunistically.
- `labels.nim`'s internally-unreferenced prefix consts stay — the module is
  a published contract surface.
- The intra-arena designed twins (`mapWallAt`/`rasterizeWallMasks` annulus
  walk; int vs float protected-floor predicates) are self-documented
  bit-identity contracts.
- `decodeGridFont`/`loadShoutFont` remain in sim.nim (broadcast-only font
  loading; moving them buys little).

**External dependency introduced (needs an Observatory-side change):** the
league shell now relays Esc to its host as
`postMessage({src:'ctf-shell', type:'esc'})`. The Observatory theater page
must listen for it to close the theater on Esc — untestable from this repo.

## Appendix: external-review claims not verified against this worktree

- "The fast-ready trap is documented **backwards** in PROTOCOL.md" — partially vindicated on closer read: the trap is real and quantified (`baseline.nim` `fastReadyEnabled` comment: ready-sends in league play collapse accuracy 44–54% → 13–23%, p=0.0039), and PROTOCOL.md's "sending it is optional" framing was misleading by omission. Fixed: PROTOCOL.md now carries the warning plus the own-aim/frame-drain/lobby-detection contracts.
- "A sprite-id collision once silently stopped every bot from firing" — historical incident, not verifiable from the repo; consistent with the existence of `tests/test_sprite_collisions.nim`, so plausible.
- "Magic-object-id lobby detection" in the baseline bot — not located by grep; unverified.
- Minor stat corrections: sim.nim has 366 procs (not 382) and 163 sim.nim-touching commits of 501 (not 126); fixture-touching commits number 46 (not ~44); "~900 lines of Crewrift residue" is ~850–900 counting the global.nim dead cluster with the four dead files.
