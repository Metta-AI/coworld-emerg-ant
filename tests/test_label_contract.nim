import
  helpers,
  std/[algorithm, os, sequtils, sets, strutils, tables, unittest],
  bitworld/spriteprotocol,
  ctf/[global, labels, sim]

# Sprite-label VOCABULARY contract.
#
# Labels are the only observation schema a policy has: it finds objects by
# label string and steers off their positions. Nothing type-checks a label,
# nothing serializes one (so replays cannot catch a change), and
# `spriteObjectsWithLabel` answers a vanished name with an empty seq. So a
# rename is invisible in every direction — the engine keeps rendering, the bot
# keeps running, and the bot just stops seeing a category of object. Field
# symptoms look like a policy regression, not an engine change; the 2026-07-22
# sprite-id clobber (see test_sprite_collisions.nim) cost a whole league round
# exactly this way.
#
# Two guards over a full-feature frame:
#   1. the emitted vocabulary, normalized, must equal tests/label_manifest.txt
#      — so ANY label change (contract or chrome) shows up in review as a
#      paired REMOVED/ADDED diff instead of slipping through;
#   2. every label the reference policy exact-match scans (labels.nim's
#      PolicyScannedLabels) must actually be emitted somewhere in that frame.
#
# CRITICAL, if you extend this: sweep BOTH streams. The board/spectator stream
# and the per-player stream emit DIFFERENT vocabularies — the cog rig segments
# and the flag banners are board-only, while `weapon <token>`, `lives ...`, and
# `throw target` only ever appear in a player view. A one-stream sweep silently
# misses half the vocabulary and would happily bless a rename in the other half.

const ManifestPath = currentSourcePath.parentDir / "label_manifest.txt"

proc fullFeatureGame(teams4 = false): SimServer =
  ## A game posed so that every label FAMILY is live in one frame — including
  ## the rare ones a quiet frame never reaches. The vocabulary guard is only as
  ## good as the corners this fixture lights up: a family that never renders
  ## here is a family a rename can break unnoticed. With `teams4` the same
  ## pose runs on a generated corner map, so the 4-team-only vocabulary
  ## (green/yellow room markers etc.) is emitted too.
  var config = defaultGameConfig()
  if teams4:
    config.teams = 4
    config.mapPath = "gen"
    config.mapGen.layout = "corners"
    config.mapSeed = 42
  config.slots.setLen(6)
  # The grenade-barrage endgame, configured ON but not latched: the stated
  # marker (`grenade barrage depth ...`) enters the vocabulary on both
  # streams (its digits normalize to <n>, so the unlatched depth-0 pattern
  # covers every state), while no environment shells rain on the posed
  # frame during the sweep's few steps.
  config.barrageMaxPerSec = 15
  # Team perks, one team per authored shape (flat = team-wide, nested =
  # per-policy groups): the PERKED marker patterns enter the vocabulary, so a
  # rename inside PerkNames diffs the manifest instead of slipping through.
  # The 4-team run keeps green/yellow bare, covering the unperked `-` form.
  config.perks[Red] = @[PerkGroup(perks: {PerkArmor, PerkScope})]
  config.perks[Blue] = @[
    PerkGroup(perks: {PerkGrenade}),
    PerkGroup(perks: {PerkThruster, PerkLuck})]
  # One cardboard-barrier pickup per team, so the folded-pickup label enters
  # the sweep (the stop list hovers next to barrierSpawns[0]).
  config.barrierPickups = 1
  result = initCtfForTest(config)
  for i in 0 ..< 6:
    discard result.addPlayer("p" & $i)
  result.startGame()
  for i in 0 ..< result.players.len:
    result.players[i].team = (if i mod 2 == 0: Red else: Blue)
  let
    cx = result.gameMap.center.x
    cy = result.gameMap.center.y
  # Viewer (0, Red) mid-map aiming east at a visible enemy (1, Blue).
  result.players[0].x = cx - 60
  result.players[0].y = cy
  result.players[0].aimBrads = 0
  # The enemy carries a shield, so the carry marker renders.
  result.players[1].x = cx + 60
  result.players[1].y = cy
  result.players[1].hasShield = true
  # A DIFFERENT seat holds a partly-spent ACTIVE layer, so the bar's
  # ` shield <s>` label family and its blue pips are live in the sweep.
  # Not the folded-carry seat — an active bubble suppresses the
  # `shield carried` marker (the bubble speaks for itself), which would
  # blind the PolicyScannedLabels emission guard — and not a Blue seat:
  # one is the posed corpse and another dies to the posed kill, which
  # zeroes its layer. Seat 2 (Red) survives the whole fixture.
  result.players[2].shieldHp = 2
  # Teammates in the viewer's bubble carrying the grenade and the spray can,
  # so both carry markers and both `cog <weapon>` rig sprites render.
  result.players[2].x = cx - 90
  result.players[2].y = cy - 20
  result.players[2].hasGrenade = true
  result.players[4].x = cx - 90
  result.players[4].y = cy + 20
  result.players[4].hasPlasmaArc = true
  # The shield carrier also carries a folded cardboard barrier, so the
  # `barrier carried` marker renders (a barrier excludes a GRENADE, not a
  # shield — seat 2 keeps the grenade).
  result.players[1].hasBarrier = true
  # A STANDING half-hex in the viewer's cone: injected directly with the
  # east-facing vertex set placeBarrier derives (the input path needs a
  # press-edge step this posed frame never takes). Its label carries
  # x,y/facing/hp, all of which normalize to <n>.
  block:
    let
      bx = cx + 30
      by = cy - 40
    var standing = PlacedBarrier(
      x: bx, y: by, facingBrads: 0, hp: BarrierHp, team: Blue,
      placedTick: result.tickCount
    )
    standing.verts = [
      (bx, by - BarrierRadius),
      (bx + 21, by - BarrierRadius div 2),
      (bx + 21, by + BarrierRadius div 2),
      (bx, by + BarrierRadius)
    ]
    standing.minX = bx - BarrierHalfThick - 1
    standing.maxX = bx + 21 + BarrierHalfThick + 1
    standing.minY = by - BarrierRadius - BarrierHalfThick - 1
    standing.maxY = by + BarrierRadius + BarrierHalfThick + 1
    result.placedBarriers.add standing
  # A CHARGING thrower right next to the viewer: `throw target` is drawn only
  # in a player view, only while throwCharge > 0, and only for a player the
  # viewer can see — three gates that a normal frame passes through untouched.
  result.players[2].throwCharge = 4
  # An AIRBORNE grenade over the viewer's own position, so `grenade air` is
  # inside the fog bubble. Injected directly: the throw path needs a two-tick
  # button release, and the orb would then be mid-flight somewhere unhelpful.
  result.airborneGrenades.add AirborneGrenade(
    sx: result.players[0].x,
    sy: result.players[0].y,
    tx: result.players[0].x + 8,
    ty: result.players[0].y + 8,
    launchTick: result.tickCount,
    flightTicks: 60,
    thrower: 2
  )
  # A live shout from each side: the bot attributes shouts by `<color> shout `
  # prefix, so both team spellings must be in the sweep.
  result.applyShout(0, "push mid")
  result.applyShout(1, "fall back")
  # A CORPSE in the viewer's line of sight. A dead player renders as a body
  # only for a GHOST viewer, so the corpse family is swept from a dead seat
  # further down rather than from seat 0.
  result.players[3].alive = false
  result.players[3].hp = 0
  result.players[3].x = cx - 30
  result.players[3].y = cy - 30
  # A carried objective: seat 0 runs the Blue heart, which lights the carried
  # banner, the carrier glow, the carry heart, and the carrier nameplate.
  result.flags[Blue].carrier = 0
  result.flags[Blue].x = result.players[0].x
  result.flags[Blue].y = result.players[0].y
  # The two AUDIO families. Both are player-observation only and both need an
  # event to have just happened, which no posed frame produces on its own — so
  # they were missing from the vocabulary until this was added, and a rename of
  # either would have slipped through the guard.
  #   `shot impact` — every recent shot leaves every living viewer a landing
  #   ring, in or out of sight. Injected as FX rather than fired for real: a real
  #   shot needs a windup and would also mint tracers/hit flashes that move with
  #   whoever it struck.
  result.recentShots.add ShotFx(
    x0: cx - 40, y0: cy, x1: cx + 40, y1: cy,
    firedTick: result.tickCount, color: teamColor(Red), hit: false
  )
  #   `grenade sound` — the jittered ring a viewer gets for a blast they could
  #   NOT see. Placed far away, out of seat 0's cone and bubble, because a blast
  #   in view renders `blast stage <n>` instead and never the sound ring.
  result.recentBlasts.add BlastFx(
    x: 40, y: MapHeight - 40, tick: result.tickCount, color: teamColor(Blue)
  )
  # The DEATH FX families. All four are emitted to living player views
  # (fog-gated: addSplatters / addDamagePops in global.nim) and are the only
  # on-map record of a kill a policy can read — but no posed frame produces
  # them, so until this kill was added none of them ever entered the manifest
  # and a rename of any of them would have slipped through the guard.
  #   A REAL kill, so the death path itself feeds the sweep: seat 5 (Blue,
  #   otherwise unposed) dies next to the viewer, leaving the long-dwelling
  #   death `splatter` and the floating `damage pop <color> KO` kill marker.
  #   Both outlive the sweep's few ticks by seconds of game time. keepPlaying()
  #   revives the seat; the FX persist independently of the victim.
  result.players[5].x = cx - 40
  result.players[5].y = cy + 30
  result.killPlayer(5, 0)
  #   The NON-fatal halves of the same two pools: the short-lived `hit splat`
  #   paint spark and the floating `-N` damage number. Injected directly like
  #   the shot/blast FX above — a real graze needs a windup and a live
  #   trajectory, and the fatal path just above covers the real mechanism.
  result.splatters.add SplatterFx(
    x: cx - 40, y: cy - 30, tick: result.tickCount,
    color: teamColor(Blue), hit: true
  )
  result.damagePops.add DamageFx(
    x: cx - 30, y: cy - 20, tick: result.tickCount,
    amount: 1, color: teamColor(Blue), kill: false
  )
  # PERMANENT terrain paint (`paint stain <color> variant <n>`) — the dried
  # marks left where shots/sprays/grenades hit the map. Board-stream only, and
  # unlike every other FX family these never expire, so a posed frame that
  # doesn't seed one leaves the whole family out of the vocabulary. Two colors
  # and two variants, so the sweep covers the color and variant axes.
  result.addPaintStain(cx + 20, cy - 40, teamColor(Red))
  result.addPaintStain(cx + 44, cy + 36, teamColor(Blue))

proc normalizeLabel(label: string): string =
  ## Collapses one emitted label to its stable PATTERN, so the manifest is a
  ## vocabulary and not a snapshot of one tick's numbers and player names.
  ##   digits         -> <n>       (stages, counts, ticks, hp segments)
  ##   team/player color token -> <color>
  ##   Greek slot name         -> <name>
  ##   " right" / " left"      -> " <side>"
  ##   endzone shape token     -> <shape>   (endzone-marker labels only)
  ##   shout payload after ": " -> dropped (arbitrary player text)
  ## Everything else is preserved verbatim — a real rename must survive.
  var text = label
  # Shouts: drop the arbitrary payload, KEEP the shouter token so the Greek-name
  # pass below can normalize it to `<name>`. That token used to be the shouter's
  # connection address — i.e. the policy's own name, broadcast to every listener
  # in earshot — and this normalizer erased the whole tail, so the manifest could
  # not tell an address from a slot letter and a regression back to leaking one
  # would diff clean. Cutting at the FIRST ": " is exact: a slot letter never
  # contains one, so anything after it is payload.
  let shoutCut = text.find(" shout ")
  if shoutCut >= 0:
    let payloadCut = text.find(": ", start = shoutCut)
    if payloadCut >= 0:
      text = text[0 ..< payloadCut]
  # Numbers before words, so a color like "light blue" is not chopped up by a
  # stray digit substitution.
  #
  # ONE exception: a "/<total>" tail keeps its literal number — for the team
  # score labels, whose denominator is a FIXED contract value (the win
  # target) that a silent retune must surface as a manifest diff. The hp bar
  # is exempt from the exception since the true-hit-point redesign: its
  # denominator is per-seat DATA (the seat's own armor-adjusted max, 3 and 4
  # coexist in one frame), so it normalizes to <n> like any other
  # interpolated number — pinning it would make the manifest a snapshot of
  # whichever hp configs the fixtures pose.
  var digitless = ""
  var i = 0
  while i < text.len:
    if text[i].isDigit:
      let afterSlash = i > 0 and text[i - 1] == '/' and
        not text.startsWith(LabelPrefixHp)
      if afterSlash:
        while i < text.len and text[i].isDigit:
          digitless.add(text[i])
          inc i
      else:
        digitless.add("<n>")
        while i < text.len and text[i].isDigit:
          inc i
    else:
      digitless.add(text[i])
      inc i
  text = digitless
  # Endzone shape tokens, on endzone labels ONLY: the closed shape vocabulary
  # normalizes to <shape> so the manifest holds one stable endzone-marker line
  # instead of one line per shape the sweep's fixtures happen to cover (the
  # sweeps pose column and corner maps; disc/square/arm would surface as
  # phantom additions the first time a fixture used one). Token-wise and
  # gated on the prefix because a blanket replace would eat the same words
  # elsewhere — "cog arm <color>" keeps its "arm".
  if text.startsWith(LabelPrefixEndzone):
    var tokens = text.split(' ')
    for i in 0 ..< tokens.len:
      if tokens[i] in LabelEndzoneShapes:
        tokens[i] = "<shape>"
    text = tokens.join(" ")
  # Facing side, before the color pass: "red right" must not become
  # "<color> right" and then have "right" survive as a bare word.
  text = text.replace(" " & LabelSideRight, " <side>")
    .replace(" " & LabelSideLeft, " <side>")
  # Color tokens: longest first, so "light blue" wins over "blue".
  var colorNames = PlayerColorNames.toSeq()
  colorNames.sort(proc (a, b: string): int = cmp(b.len, a.len))
  for name in colorNames:
    text = text.replace(name, "<color>")
  for name in IdentityNames:
    text = text.replace(name, "<name>")
  text

proc collectLabels(sim: var SimServer): HashSet[string] =
  ## Every label emitted across BOTH streams over a short run, normalized.
  ##
  ## Sprite definitions are deduped per connection and many are lazy (a floor
  ## pickup defines its sprite the first time it is in somebody's vision), so
  ## the sweep walks the viewer past each pickup family and accumulates. It
  ## also runs the player stream from a LIVING seat (own HUD, own fog) and from
  ## a DEAD one (ghost view: corpses, the whole map unfogged).
  ##
  ## THE SWEEP MUST NOT LET THE GAME END. Teleporting the viewer around the map
  ## walks it through the enemy flag and the capture zone, which scores a capture
  ## and flips the phase to GameOver — and most of the own-HUD families (the
  ## weapon readout, the fire icon, the lives counter) are gated on
  ## `player.alive` inside a `Playing`-phase branch, so every frame after that
  ## silently stops carrying them. That is how a "full feature" sweep ends up
  ## missing `weapon spray` while looking like it ran fine. Re-pinning the phase
  ## after each step keeps the posed frame the thing under test.
  var
    gstate = initGlobalViewerState()
    livingState: PlayerViewerState
    ghostState: PlayerViewerState
  let none = newSeq[InputState](sim.players.len)

  proc keepPlaying(sim: var SimServer) =
    ## Undo any round-ending side effect the teleporting sweep caused. Seat 3 is
    ## left DEAD on purpose — it is the ghost viewer, and corpse labels only
    ## render for a dead seat.
    sim.phase = Playing
    sim.isDraw = false
    sim.gameOverTimer = 0
    for team in Team:
      sim.flags[team].carrier = -1
    for i in 0 ..< sim.players.len:
      sim.players[i].carryingFlag = false
      if i != 3:
        sim.players[i].alive = true

  proc absorb(into: var HashSet[string], messages: seq[SpritePacketMessage]) =
    for message in messages:
      if message.kind == spkSprite:
        into.incl(message.sprite.label.normalizeLabel())

  # Board/spectator stream: the cog rig, the flag banners, the roster, and
  # every skin master live only here.
  result.absorb(sim.buildGlobalMessages(gstate))

  let stops = [
    (sim.players[0].x, sim.players[0].y),
    (sim.grenadeSpawns[0].x, sim.grenadeSpawns[0].y),
    (sim.shieldSpawns[0].x, sim.shieldSpawns[0].y),
    (sim.plasmaArcSpawns[0].x, sim.plasmaArcSpawns[0].y),
    (sim.medKitSpawns[0].x, sim.medKitSpawns[0].y),
    (sim.barrierSpawns[0].x, sim.barrierSpawns[0].y),
  ]
  for stop in stops:
    # Hover NEXT TO each spawn, never on it, so nothing is picked up (a pickup
    # would remove the floor sprite this sweep is here to see).
    sim.players[0].x = stop[0] + 40
    sim.players[0].y = stop[1]
    sim.players[0].aimBrads = 128            # aim west: the spawn is in the cone
    sim.players[0].throwCharge = 0           # only seat 2 charges (see fixture)
    sim.keepPlaying()
    result.absorb(sim.buildPlayerMessages(0, livingState))
    result.absorb(sim.buildGlobalMessages(gstate))
    sim.step(none, none)
    sim.keepPlaying()
    result.absorb(sim.buildPlayerMessages(0, livingState))

  # Ghost view from the dead seat: corpses render for ghost viewers only.
  result.absorb(sim.buildPlayerMessages(3, ghostState))
  result.absorb(sim.buildGlobalMessages(gstate))

  # Spray FX + the shooter's own weapon HUD: give seat 0 the can and fire it.
  # `weapon spray` is gated on the seat being alive in a Playing-phase frame, so
  # the phase pin has to hold right here or this family goes missing.
  sim.keepPlaying()
  sim.players[0].hasPlasmaArc = true
  sim.players[0].fireCooldown = 0
  sim.tryFireArc(0)
  result.absorb(sim.buildPlayerMessages(0, livingState))
  result.absorb(sim.buildGlobalMessages(gstate))
  sim.players[0].hasPlasmaArc = false
  result.absorb(sim.buildPlayerMessages(0, livingState))

suite "sprite label contract":
  test "the emitted label vocabulary matches tests/label_manifest.txt":
    var game = fullFeatureGame()
    # ONE sweep, reused. collectLabels CONSUMES the fixture's transient state —
    # it steps the sim, which spends the charging throw (`throw target`), lands
    # the carried objective (`<color> flag carried`), and expires the carrier
    # nameplate. Sweeping the same sim twice therefore yields a SMALLER second
    # vocabulary, and comparing the two would report a phantom rename. Every
    # check below either shares this set or builds its own fresh fixture.
    # The golden is the UNION of the classic and 4-team vocabularies, so the
    # 4-team-only labels (green/yellow room markers) are contract too. The
    # 4-team sweep runs FIRST: fixtures install their map process-wide, and
    # every later test in this binary poses on the classic arena.
    var game4 = fullFeatureGame(teams4 = true)
    var emitted4 = game4.collectLabels()
    game = fullFeatureGame()
    var emitted = game.collectLabels()
    for label in emitted4:
      emitted.incl(label)
    # Trenches never appear in EITHER fixture above: the hand-authored
    # default arena ships none (see test_trenches.nim, "the default arena
    # digs no trenches") and 4-team maps never dig any either — so the
    # `trench <n>,<n> <n>,<n>` marker family needs its own minimal fixture.
    # Reuses test_trenches.nim's exact deterministic recipe (mapPits:1,
    # mapSeed 4242 — one pit, anchored at the generated map's center by the
    # odd-count rule) and just the INIT snapshot (the marker is stated once
    # at t=0, in addMapMarkers, not re-emitted per frame — the full
    # collectLabels() walk is unneeded here). Player names match "p0"/"p1"
    # (fullFeatureGame's convention): a literal "red"/"blue" name collides
    # with the color-token normalization pass below and salts in unrelated
    # ADDED lines. Only the `trench ` family is merged in — this fixture's
    # 2-player roster also emits a differently-shaped team-score denominator
    # than fullFeatureGame's 6-player one, which is roster noise this
    # addition has no business dragging into the golden vocabulary.
    var trenchConfig = defaultGameConfig()
    trenchConfig.update("""{"mapPath": "gen", "mapSeed": 4242, "mapPits": 1}""")
    var trenchGame = initCtfForTest(trenchConfig)
    discard trenchGame.addPlayer("p0")
    discard trenchGame.addPlayer("p1")
    trenchGame.startGame()
    doAssert trenchGame.gameMap.trenches.len == 1,
      "trench label fixture rolled zero trenches — recheck the seed"
    var trenchViewer = initGlobalViewerState()
    for message in trenchGame.buildGlobalMessages(trenchViewer):
      if message.kind == spkSprite:
        let normalized = message.sprite.label.normalizeLabel()
        if normalized.startsWith(LabelPrefixTrench):
          emitted.incl(normalized)
    # Puddles are config-gated exactly like trenches — no fixture above has
    # any — so the `puddle <n>,<n> <n>,<n>` marker family gets the same
    # minimal treatment: mapPuddles:1 anchors its odd puddle dead center
    # (deterministic regardless of seed), and only the `puddle ` family is
    # merged in.
    var puddleConfig = defaultGameConfig()
    puddleConfig.update("""{"mapPath": "gen", "mapSeed": 4242, "mapPuddles": 1}""")
    var puddleGame = initCtfForTest(puddleConfig)
    discard puddleGame.addPlayer("p0")
    discard puddleGame.addPlayer("p1")
    puddleGame.startGame()
    doAssert puddleGame.gameMap.puddles.len == 1,
      "puddle label fixture placed zero puddles — recheck the seed"
    var puddleViewer = initGlobalViewerState()
    for message in puddleGame.buildGlobalMessages(puddleViewer):
      if message.kind == spkSprite:
        let normalized = message.sprite.label.normalizeLabel()
        if normalized.startsWith(LabelPrefixPuddle):
          emitted.incl(normalized)
    # Regenerating: `nim r -d:writeLabelManifest tests/test_label_contract.nim`
    # rewrites the golden from what the engine emits NOW, and the resulting git
    # diff is the artifact to review. Deliberately opt-in — if the test could
    # heal itself on a normal run it would rubber-stamp every accidental rename,
    # which is the failure it exists to catch.
    when defined(writeLabelManifest):
      var text = """# The sprite-label vocabulary the engine emits, normalized to patterns
# (<n> a number, <color> a team/player color, <name> a slot letter, <side> a
# facing, <shape> an endzone shape token). GENERATED — regenerate with:
#   nim r -d:writeLabelManifest tests/test_label_contract.nim
# A diff here is a change to the observation contract every policy reads.
"""
      for label in emitted.toSeq().sorted():
        text.add(label & "\n")
      ManifestPath.writeFile(text)
      echo "rewrote ", ManifestPath
    let
      golden = ManifestPath.readFile().splitLines()
        .filterIt(it.strip().len > 0 and not it.startsWith("#"))
        .toHashSet()
      removed = (golden - emitted).toSeq().sorted()
      added = (emitted - golden).toSeq().sorted()
    if removed.len > 0 or added.len > 0:
      var report = "\nSPRITE LABEL VOCABULARY CHANGED.\n"
      if removed.len > 0 and added.len > 0:
        report.add("\nThis reads as a RENAME. Pair each REMOVED line with the " &
          "ADDED line that replaced it:\n")
      if removed.len > 0:
        report.add("\n  REMOVED — the engine no longer emits these labels:\n")
        for label in removed:
          report.add("    - " & label & "\n")
        report.add("""
    Any policy that scans for a REMOVED label is now SILENTLY BLIND to that
    category of object. `spriteObjectsWithLabel` returns an empty seq for a
    name nothing emits: no exception, no warning, no failing assertion — the
    bot simply never sees kits, or shields, or enemies, forever. That is the
    whole reason this test exists.
""")
      if added.len > 0:
        report.add("\n  ADDED — newly emitted labels:\n")
        for label in added:
          report.add("    + " & label & "\n")
      report.add("""
If the change is intended, update ALL FOUR surfaces in the SAME commit:
  1. src/ctf/labels.nim        — the shared vocabulary (consts + label procs)
  2. tests/label_manifest.txt  — this golden list
  3. docs/RULES.md             — the published observation spec policy authors read
  4. players/baseline/         — the reference consumer's scans
Skipping (3) or (4) leaves the docs lying and the reference bot blind, and
neither failure surfaces until a league round comes back wrong.
""")
      checkpoint(report)
      fail()

  test "every policy-scanned label is actually emitted":
    # PolicyScannedLabels is the set the reference policy matches EXACTLY. An
    # exact match against a label the engine stopped emitting is the quietest
    # bug in the codebase, so assert the producer still emits each one.
    var game = fullFeatureGame()
    let emitted = game.collectLabels()
    for wanted in PolicyScannedLabels:
      let pattern = wanted.normalizeLabel()
      if pattern notin emitted:
        checkpoint("\nPOLICY-SCANNED LABEL IS NOT EMITTED: \"" & wanted &
          "\" (pattern \"" & pattern & "\")\n" & """
    The reference policy calls spriteObjectsWithLabel with this exact string.
    Nothing in the engine emits it, so that call returns an EMPTY SEQ on every
    tick of every game, forever — and nothing else fails: no exception, no
    warning, no other test. The policy is simply blind to whatever this label
    named.
    Either restore the emission in src/ctf/global.nim, or — if the label is
    genuinely retired — drop it from PolicyScannedLabels in src/ctf/labels.nim
    AND from the scans in players/baseline/ in the same commit.
""")
        fail()

  test "the hp bar carries true hit points, shield layer spelled apart":
    # The bar is TRUE hit points since the redesign: `hp <hp>/<maxHp>` with
    # the denominator the seat's OWN armor-adjusted max, and a held shield
    # layer appended as ` shield <s>` — never folded into the base count.
    # The reference policy parses these by prefix (actorsFor in
    # players/baseline/baseline.nim), so what this guards is the SHAPE: every
    # emitted hp label must be exactly a labelHp spelling, and the fixture's
    # armor split must surface as coexisting denominators — an armored seat's
    # `hp 4/4` next to a bare seat's `hp 3/3`. RAW labels on purpose: the
    # normalized pattern collapses both to `hp <n>/<n>` and could not see an
    # armor seat silently losing its wider bar.
    var game = fullFeatureGame()
    # The fixture's posed kill leaves a Blue seat dead and a dead seat draws
    # no bar; revive everyone but the deliberate ghost (seat 3, matching
    # collectLabels' keepPlaying) so every bar spelling is in the one frame.
    for i in 0 ..< game.players.len:
      if i != 3:
        game.players[i].alive = true
        game.players[i].hp = max(1, game.config.maxHpFor(
          game.players[i].team, game.players[i].perks))
    var gstate = initGlobalViewerState()
    var raw: HashSet[string]
    for message in game.buildGlobalMessages(gstate):
      if message.kind == spkSprite and
          message.sprite.label.startsWith(LabelPrefixHp):
        raw.incl(message.sprite.label)
    # fullFeatureGame perks Red with armor (+1 max hp) and poses an active
    # shield layer on one armored Red seat: armored seats read /4, bare
    # ones /3, and the shielded seat appends its layer — denominators and
    # the shield tail coexisting in ONE frame is the redesign's whole claim.
    check labelHp(4, 4) in raw
    check labelHp(3, 3) in raw
    check labelHp(4, 4, 2) in raw
    for label in raw:
      # Every spelling must be a labelHp rebuild: `hp <hp>/<max>[ shield <s>]`
      # with hp <= max and a positive shield tail — a hand-spelled variant
      # (aggregated shield, a stray denominator) fails here by shape.
      let tail = label[LabelPrefixHp.len .. ^1]
      let slash = tail.find('/')
      check slash > 0
      let shieldCut = tail.find(LabelHpShieldSep)
      let denomEnd = if shieldCut >= 0: shieldCut else: tail.len
      let hp = parseInt(tail[0 ..< slash])
      let maxHp = parseInt(tail[slash + 1 ..< denomEnd])
      var shield = 0
      if shieldCut >= 0:
        shield = parseInt(tail[shieldCut + LabelHpShieldSep.len .. ^1])
      check label == labelHp(hp, maxHp, shield)
      check hp <= maxHp
      check maxHp >= 1

  test "the endzone markers state each team's capture zone exactly":
    # The vocabulary diff proves the PATTERN is emitted; this pins the VALUES:
    # both streams must carry, for every team, the exact label labelEndzone
    # builds from captureZone — corners and shape token alike. A marker whose
    # numbers drift from the zone the sim actually scores in would pass the
    # manifest check while feeding every policy wrong geometry.
    #
    # RAW labels on purpose (no normalizeLabel), and no sim stepping: one
    # init-frame build per stream. The 4-team fixture runs FIRST — fixtures
    # install their map process-wide, and every later test in this binary
    # poses on the classic arena.
    proc checkZones(sim: var SimServer, shape: string) =
      var
        gstate = initGlobalViewerState()
        pstate: PlayerViewerState
      for stream in [sim.buildGlobalMessages(gstate),
                     sim.buildPlayerMessages(0, pstate)]:
        var raw: HashSet[string]
        for message in stream:
          if message.kind == spkSprite:
            raw.incl(message.sprite.label)
        for team in sim.gameMap.teams():
          let zone = sim.gameMap.captureZone(team)
          check labelEndzone(
            teamText(team), shape, zone.xLo, zone.yLo, zone.xHi, zone.yHi
          ) in raw

    proc genGame(endzone = ""; layout = ""; teams = 2): SimServer =
      ## A minimal fixture on a generated map with the endzone archetype or
      ## team layout locked — only the init frame matters here, so no posing.
      var config = defaultGameConfig()
      config.slots.setLen(6)
      config.teams = teams
      config.mapPath = "gen"
      config.mapSeed = 42
      config.mapGen.endzone = endzone
      config.mapGen.layout = layout
      result = initCtfForTest(config)
      for i in 0 ..< 6:
        discard result.addPlayer("p" & $i)
      result.startGame()

    var game4 = fullFeatureGame(teams4 = true)
    game4.checkZones(LabelEndzoneShapeCorner)
    var plusGame = genGame(layout = "plus", teams = 4)
    plusGame.checkZones(LabelEndzoneShapeArm)
    var discGame = genGame(endzone = LabelEndzoneShapeDisc)
    discGame.checkZones(LabelEndzoneShapeDisc)
    var squareGame = genGame(endzone = LabelEndzoneShapeSquare)
    squareGame.checkZones(LabelEndzoneShapeSquare)
    # The classic fixture LAST, restoring the arena for the tests that follow.
    var game = fullFeatureGame()
    game.checkZones(LabelEndzoneShapeColumn)

suite "own-aim marker":
  test "the player stream states the exact aim angle":
    var sim = twoTeamGame()
    sim.players[0].aimBrads = 137
    var pstate: PlayerViewerState
    var raw: HashSet[string]
    for message in sim.buildPlayerMessages(0, pstate):
      if message.kind == spkSprite:
        raw.incl(message.sprite.label)
    check labelOwnAim(137) in raw
    # And it tracks a change on the next frame.
    sim.players[0].aimBrads = 12
    var raw2: HashSet[string]
    for message in sim.buildPlayerMessages(0, pstate):
      if message.kind == spkSprite:
        raw2.incl(message.sprite.label)
    check labelOwnAim(12) in raw2
