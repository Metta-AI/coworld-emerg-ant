# Four-team CTF (red / blue / green / yellow)

STATUS: implemented on this branch. Design points that moved during the
build (with daveey, 2026-07-29/30) — where this plan and the code disagree,
the CODE is what shipped:

- No alliance/2v2 game mode: 4-team play is pure FFA, and "2v2" is two
  policies splitting one classic team's seats (doubles seating, which the
  platform and viewer already support).
- Scoring generalized to one zero-sum rule: winner +1 per losing team,
  each loser -1 — classic stays +1/-1, 4-team FFA pays +3/-1.
- Corner endzones are DIAGONAL (a 45-degree L1 threshold across the
  corner), not the axis-aligned corner boxes planned below.
- Plus maps have OPEN corners (no blocker rects); their endzones are
  arm-mouth boxes.
- `enemy()` was deleted outright, not kept for 2-team paths.
- RewardAccount's per-team counters became `wins`/`games`:
  `array[Team, int]`, not added scalars.
- The 4-team scorebug is ONE row of four plates, not stacked pairs.
- The label vocabulary needed no green/yellow additions beyond the room
  markers — colors normalize to `<color>` in the manifest, which now also
  unions a 4-team sweep.

Goal: engine-side 4-team support behind a config gate, 4-team map generation
(corner and plus symmetric layouts), demo replays verified in the already-landed
2-4 team viewer (commit 30ba667). Default 2-team behavior stays byte-identical
(same tick states, same gameHash, same broadcast chrome), so no GameVersion bump
— matching the procgen precedent (d53de9a).

## Team model

- `Team = enum Red, Blue, Green, Yellow` (2-team prefix preserved).
- New `GameConfig.teams: int` (default 2; validated 2 or 4), parsed/serialized in
  `update`/`configJson` so replays reproduce it. Read BEFORE
  `resolveCtfMapMetadata` (it shapes generation).
- `CtfMap.layout: TeamLayout = layoutSides | layoutCorners | layoutPlus`.
  `teams: 2` requires sides (arena / arena-large / 2-team gen); `teams: 4`
  requires corners or plus (gen/mapSpec only — the hand-built arenas stay
  2-team). Config knob `mapLayout` ("corners" | "plus"; empty = drawn from the
  map seed) in MapGenOverrides.
- Active teams: `teamCount(layout)` (sides=2 else 4); everything iterating
  `for team in Team` moves to the active slice `Red .. Team(count-1)`.
  Process-global render code gets an `ArenaTeamCount` global installed by
  `selectCtfMap` (same invariant as MapWidth).
- `teamForSlot` default: `Team(order mod teamCount)`. Intra-team rank
  (`order div 2` sites) becomes `order div teamCount`.
- `enemy()` survives for 2-team-only paths but the flag rules generalize:
  steal = touch ANY other active team's pedestal flag; `teamFlagProgress` =
  progress of the closest-to-captured enemy flag measured toward MY home anchor
  (axis distance for sides — identical numbers to today).
- Win: capture = carrier of any enemy flag inside their own capture region.
  Wipe: teams with live players among active; exactly 1 -> that team wins,
  0 -> draw (encoding stays winner=Red + isDraw).
- RewardAccount: winsRed/winsBlue/gamesRed/gamesBlue stay; add
  winsGreen/winsYellow/gamesGreen/gamesYellow (+ wire metrics emitted only when
  4-team). eventActionId's game ordinal = sum over all four (identical for
  2-team).

## Geometry

Replace the two `teamHomeX` scalars with per-team 2D anchors:

- `teamAnchor(gameMap, team): MapPoint`
  - sides: exact current teamHomeX formulas at center.y.
  - corners: 30%-in point on BOTH axes — Red TL, Blue TR, Green BL, Yellow BR.
  - plus: Red W, Blue E, Green N, Yellow S (30%-in on the home axis, centered on
    the other).
- `flagHome = anchor`. `spawnAimBrads`: sides E/W as today; corners point at the
  diagonal (224/160/32/96); plus 0/128/192/64. `flipH` = aim points west-ish.
- Capture zone becomes a region predicate `inCaptureZone(sim, team, cx, cy)`:
  - sides: exact current x-column tests.
  - corners: past the anchor toward the corner on BOTH axes (a corner box),
    inclusive thresholds at anchor +/- CaptureZoneWidth/2.
  - plus: past the anchor on the home axis (like sides but for N/S teams the
    axis is y); the plus corner blocks bound the rest.
  `randomEndzonePosition` samples the matching box.
- `isProtectedFloor`: per-active-team spawn pockets + capture strips + center
  ring, from an `ArenaTeamAnchors` global; sides output must be identical to
  the current `[ArenaRedHomeX, ArenaBlueHomeX]` code.
- spawnPosition: stagger perpendicular to the home axis (vertical for E/W
  teams, horizontal for N/S); corners stagger vertically like sides.
- Pickups: shields and spray cans become per-team (array[Team, PickupSpawn],
  active prefix used): placed on the endzone back line per anchor, sides
  placement byte-identical to today's two points. Grenades stay 4 corners on
  sides; on corner layouts (corners are endzones) they move to edge midpoints;
  plus keeps corners of the center block. Med kits stay generator-placed,
  symmetric under rot90 (center point / rot90 orbit).

## Generator

- `MapSymmetry` gains `symRot90` (square maps only): full set = quadrant shapes
  x {id, rot90, rot180, rot270} about the center.
- 4-team maps are square: side lengths small 820 / standard 960 / large 1180,
  clearances scaled like scaledGenShell.
- Corner layout: obstacle columns generated in the left half restricted to the
  top-left quadrant (band x in [clear+50, cx-52], y in [border, cy]), rot90
  replicated. Sightline validator: no straight horizontal ray between W/E
  capture strips and no vertical ray between N/S — for corners, no straight
  diagonal-free requirement beyond connectivity + cover budget; flood fill must
  connect all four flag homes and the center.
- Plus layout: four corner blocker rects (from the arm edges to the map corner)
  as fixed shapes + column obstacles inside the west arm, rot90 replicated.
- mapSpec gains "layout" ("sides" default when absent — old replays fine); the
  quadrant shape list rides in leftObstacles unchanged.
- Pool: 4-team stays gen/mapSpec-only for now (no curated 4-team pool yet).

## Art

- Soldier + rig masters are parametric tints of the white CvC shell
  (scripts/art/build_cvc_{masters,rig,front}.py): add GREEN (69,168,94) and
  YELLOW (221,197,49) entries, rerun -> soldier_green/yellow*.png,
  rig_real/green|yellow/.
- Hearts + pedestals have no master: build-time hue-map script converts the red
  master's hue band to green/yellow (luminance preserved) ->
  heart_green/yellow.png, ped_green/yellow.png.
- teamColor: Green=10 ("green"), Yellow=8 ("yellow"). Endzone rgba constants
  match the viewer palette: green #45a85e, yellow #ddc531.
- Sprite id pools: renumbered contiguously for 4 team slots (flags 700..703,
  auras 704..707, planted 708..711, gameover icons 712..715, carry hearts
  600..663, soldier skin stride 4x16). Sprite ids are render-process
  internals — NOT part of the policy contract (labels are; labels.nim) and
  not stored in replays (replays re-render on playback) — so red/blue ids
  moving does not break compatibility; the byte-compat bar covers tick
  state, gameHash, and the broadcast chrome JSON, all of which are
  unchanged (fixture tests prove it).
- Scoreboard: 4-team games stack two teams per roster panel (Red+Green left,
  Blue+Yellow right, matching the viewer's 0/2-left 1/3-right convention); k/d
  strip builds one sprite per active team.
- labels: readSlotTeam + slotTeamText accept green/yellow; flag/room label
  vocabulary gains green/yellow tokens; label_manifest.txt re-recorded.
- server.nim static FPV art: add green/yellow routes; viewer COG_ART fallback
  checked during the demo pass.

## Verification

- Full test suite green from repo root; 2-team fixture replays must pass
  UNCHANGED (that is the byte-compat proof).
- New tests: 4-team mapgen validity (both layouts over seed sweep: symmetry,
  connectivity, cover), teamForSlot/anchor/capture-region math, 4-team win by
  capture and by wipe, config round-trip.
- Record demo episodes (corners + plus) via a record_four_team_demo.sh; verify
  in replay_broadcast.html + league_replayer.html; fix viewer issues found.
