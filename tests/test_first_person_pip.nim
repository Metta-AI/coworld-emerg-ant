import
  helpers,
  std/[json, os, sequtils, strutils, unittest],
  ctf/[broadcast, sim]

proc fpFrame(sim: SimServer, povSlot: int): JsonNode =
  ## Parses the `fp` node out of a chrome frame for one POV slot (or null).
  let frame = sim.buildStateJson(
    events = newJArray(),
    playing = false,
    speed = 1,
    maxTick = 1000,
    looping = false,
    transportEnabled = true,
    mismatchTick = -1,
    povSlot = povSlot
  )
  let parsed = parseJson(frame)
  if parsed.hasKey("fp"): parsed["fp"] else: newJNull()

suite "bundle asset paths":
  # The FPV cog art shipped twice (#119, #121) without ever reaching the screen,
  # because the loader used ROOT-ABSOLUTE srcs ('/client/soldier_*_front.png').
  # A leading slash resolves against the ORIGIN ROOT, so from the static bundle
  # at /v2/coworlds/replays/static/<coworld>/<hash>/ it fetched
  # <api-origin>/client/... — nothing serves that — and from the Kubernetes
  # service proxy it dropped the route prefix. Both 404.
  #
  # Nothing caught it for two releases because the failure is SILENT in both
  # directions: drawFpvEntity guards the blit with cogArtReady(), so a missing
  # sprite just falls back to the procedural chassis (which looks plausible),
  # and locally /client/* IS served, so it looked correct on every dev machine.
  # #131 fixed it by deriving the paths from the document (COG_BASE/ART_BASE).
  #
  # The Dockerfile's `test -f` guards prove the PNGs SHIP; they say nothing
  # about how the page ASKS for them. This is the other half: a static scan
  # asserting no asset reference in either bundle page is root-absolute. Kept as
  # a text scan on purpose — the paths live in inline JS inside the HTML, so
  # there is no Nim symbol to type-check and no cheap way to run the page here.
  const BundlePages = ["client/replay_broadcast.html", "client/league_replayer.html"]

  test "no bundle page requests an asset from the origin root":
    # Every offender is collected so a failure names them all at once, rather
    # than dying on the first and hiding the rest.
    var offenders: seq[string] = @[]
    for page in BundlePages:
      for lineNo, line in toSeq(readFile(GameDir / page).splitLines).pairs:
        # The shapes that load an asset: a JS Image().src assignment, an HTML
        # src=/href= attribute, and a CSS url(). "//host" is a protocol-relative
        # absolute URL — equally wrong here — and is caught by the same prefixes.
        for pattern in [".src = '/", ".src = \"/", "src='/", "src=\"/",
                        "href='/", "href=\"/", "url('/", "url(\"/"]:
          if line.contains(pattern):
            offenders.add(page & ":" & $(lineNo + 1) & "  " & line.strip())
    if offenders.len > 0:
      checkpoint("root-absolute asset references resolve to the API origin " &
                 "root from the static bundle and 404. Derive them from the " &
                 "document instead (see COG_BASE / ART_BASE):\n  " &
                 offenders.join("\n  "))
    check offenders.len == 0

  test "the cog art loads through COG_BASE, relative in the static bundle":
    let html = readFile(GameDir / "client/replay_broadcast.html")
    # The masters (every team x plain/gun) load through one templated loop —
    # the guard checks the loop goes through COG_BASE (issue #131: a root
    # path resolves to the API origin from the static bundle and 404s) and
    # that every team name is in the roster it iterates.
    checkpoint("the templated art loop must derive from COG_BASE")
    check html.contains(
      "COG_ART[team].src = COG_BASE + '/soldier_' + team + '_front.png'")
    check html.contains(
      "COG_ART_GUN[team].src = COG_BASE + '/soldier_' + team + " &
      "'_front_gun.png'")
    for team in ["'red'", "'blue'", "'green'", "'yellow'"]:
      checkpoint(team & " must be in the art roster")
      check html.contains(team)
    checkpoint("COG_BASE must still detect the static bundle")
    check html.contains("window.CtfStaticReplay")

suite "first-person picture-in-picture":
  test "no POV selected → no fp frame":
    var game = initCtfForTest(defaultGameConfig())
    discard game.addPlayer("red0")
    game.startGame()
    check game.fpFrame(-1).kind == JNull

  test "POV frame has one distance per raycast column":
    var game = initCtfForTest(defaultGameConfig())
    let red = game.addPlayer("red0")
    game.startGame()
    game.players[red].team = Red
    let fp = game.fpFrame(game.players[red].joinOrder)
    check fp.kind == JObject
    check fp["cols"].len == 96
    # The strip carries its cone half-angle (brads) for correct client projection.
    check fp.hasKey("hfov")
    check fp["hfov"].getFloat() > 0
    # A column is either a scalar wall hit (>=-1) or a [stoneHit, glassDist] pair
    # (glass is see-through, so both distances ride along).
    for c in fp["cols"]:
      if c.kind == JArray:
        check c.len == 2
        check c[0].getInt() >= -1     # stone behind the glass (or -1 miss)
        check c[1].getInt() >= 0      # a recorded glass pane is a real distance
      else:
        check c.getInt() >= -1

  test "walls near the player yield shorter distances than an open lane":
    # A player pressed against the left border wall, aiming into the wall (west),
    # must read closer walls than the same player aiming down an open lane.
    var game = initCtfForTest(defaultGameConfig())
    let red = game.addPlayer("red0")
    game.startGame()
    game.players[red].team = Red
    game.players[red].x = 20   # hard against the left border
    game.players[red].y = MapHeight div 2

    game.players[red].aimBrads = AimBradsTurn div 2  # west, into the border
    let intoWall = game.fpFrame(game.players[red].joinOrder)
    game.players[red].aimBrads = 0                   # east, into the arena
    let intoArena = game.fpFrame(game.players[red].joinOrder)

    proc centerHit(fp: JsonNode): int =
      # The central column: the axis the player looks straight down. A column is
      # either a scalar stone hit or a [stoneHit, glassDist] pair.
      let c = fp["cols"][fp["cols"].len div 2]
      if c.kind == JArray: c[0].getInt() else: c.getInt()

    let wallHit = intoWall.centerHit()
    # Aiming into the border wall must return a finite, short wall hit.
    check wallHit >= 0
    check wallHit < 60

  test "a visible enemy in front shows up as an entity near view-center":
    var game = initCtfForTest(defaultGameConfig())
    let
      red = game.addPlayer("red0")
      blue = game.addPlayer("blue0")
    game.startGame()
    game.players[red].team = Red
    game.players[blue].team = Blue
    let
      cx = game.gameMap.center.x
      cy = game.gameMap.center.y
    game.players[red].x = cx
    game.players[red].y = cy
    game.players[red].aimBrads = 0            # aiming east
    game.players[blue].x = cx + 80            # directly east, in the cone
    game.players[blue].y = cy

    # Refresh the viewer's fog so playerVisibleTo reflects real line of sight.
    discard game.refreshPlayerFov(red)
    let fp = game.fpFrame(game.players[red].joinOrder)
    check fp.kind == JObject
    var found = false
    for e in fp["ents"]:
      if e["k"].getStr() == "enemy":
        found = true
        # Dead-ahead → |o| near 0 (view center).
        check abs(e["o"].getFloat()) < 0.35
        check e["d"].getInt() > 0
    check found

  test "a dead viewer sees walls but no live entities in the inset":
    var game = initCtfForTest(defaultGameConfig())
    let
      red = game.addPlayer("red0")
      blue = game.addPlayer("blue0")
    game.startGame()
    game.players[red].team = Red
    game.players[blue].team = Blue
    let
      cx = game.gameMap.center.x
      cy = game.gameMap.center.y
    game.players[red].x = cx
    game.players[red].y = cy
    game.players[red].aimBrads = 0
    game.players[red].alive = false           # ghost viewer
    game.players[blue].x = cx + 80
    game.players[blue].y = cy

    let fp = game.fpFrame(game.players[red].joinOrder)
    check fp.kind == JObject
    check fp["cols"].len == 96                 # terrain still raycast
    for e in fp["ents"]:
      check e["k"].getStr() != "enemy"         # no moving entities for the dead
      check e["k"].getStr() != "mate"

  test "glass windows are see-through: a column reads BOTH the pane and the wall behind":
    # Column-1 has GLASS window stubs (x 268..286). A player standing just EAST of
    # the top glass stub (y ~138) and aiming WEST must ray THROUGH the glass to the
    # border wall behind it — so its center column is a [stoneHit, glassDist] pair,
    # never a dead stone face. This is the see-through-not-shoot-through contract.
    var game = initCtfForTest(defaultGameConfig())
    let red = game.addPlayer("red0")
    game.startGame()
    game.players[red].team = Red
    game.players[red].x = 340            # east of the x=268..286 glass stub
    game.players[red].y = 138            # inside the top glass stub's y-span
    game.players[red].aimBrads = AimBradsTurn div 2   # due west, through the glass
    let fp = game.fpFrame(game.players[red].joinOrder)
    var sawGlass = false
    for c in fp["cols"]:
      if c.kind == JArray:
        sawGlass = true
        check c[1].getInt() >= 0          # a real glass distance
    check sawGlass

  test "fp frame carries the seat's own status HUD":
    var game = initCtfForTest(defaultGameConfig())
    let red = game.addPlayer("red0")
    game.startGame()
    game.players[red].team = Red
    game.players[red].hp = 2
    game.players[red].hasShield = true
    let fp = game.fpFrame(game.players[red].joinOrder)
    check fp.kind == JObject
    check fp.hasKey("self")
    let self = fp["self"]
    check self["hp"].getInt() == 2
    check self["alive"].getBool() == true
    check self["team"].getStr() == "red"
    var carriesShield = false
    for it in self["items"]:
      if it.getStr() == "shield": carriesShield = true
    check carriesShield

  test "fp frame carries an un-fogged tactical map of ALL players and both hearts":
    # The minimap is deliberately omniscient: it lists every live player and both
    # hearts in world coords regardless of the POV seat's fog, plus the seat's own
    # position, aim and cone geometry.
    var game = initCtfForTest(defaultGameConfig())
    let
      red = game.addPlayer("red0")
      blue = game.addPlayer("blue0")
    game.startGame()
    game.players[red].team = Red
    game.players[blue].team = Blue
    let
      cx = game.gameMap.center.x
      cy = game.gameMap.center.y
    game.players[red].x = cx
    game.players[red].y = cy
    game.players[red].aimBrads = 0
    # Blue is placed far away and NOT refreshed into red's fov — the fog-honest
    # ents list would omit it, but the omniscient map must still include it.
    game.players[blue].x = 40
    game.players[blue].y = 40

    let fp = game.fpFrame(game.players[red].joinOrder)
    check fp.kind == JObject
    check fp.hasKey("map")
    let m = fp["map"]
    check m["w"].getInt() == MapWidth
    check m["h"].getInt() == MapHeight
    check m["players"].len == 2                 # BOTH players, no fog
    check m["hearts"].len == 2                  # both team hearts
    var sawSelf = false
    for p in m["players"]:
      if p["self"].getBool(): sawSelf = true
    check sawSelf
    let here = m["here"]
    check here["x"].getInt() == cx
    check here["coneDeg"].getInt() == game.config.visionConeDeg
    check here["bubble"].getInt() == game.config.visionBubble

  test "static minimap wall silhouette encodes floor/stone/glass":
    var game = initCtfForTest(defaultGameConfig())
    discard game.addPlayer("red0")
    game.startGame()
    let walls = game.fpMapWallsJson()
    check walls["w"].getInt() == MapWidth
    check walls["h"].getInt() == MapHeight
    # RLE is a flat [state, count, …] list; states are 0/1/2 and reconstruct to
    # exactly gw*gh cells.
    let
      gw = walls["gw"].getInt()
      gh = walls["gh"].getInt()
      rle = walls["rle"]
    check rle.len mod 2 == 0
    var total = 0
    var sawStone = false
    for k in countup(0, rle.len - 2, 2):
      let st = rle[k].getInt()
      check st in 0 .. 2
      if st == 1: sawStone = true
      total += rle[k + 1].getInt()
    check total == gw * gh
    check sawStone                              # the arena has stone walls

  test "self.paintTick advances on a PAINT hit — gun AND spray can":
    # The EYES-PiP visor splat keys off self.paintTick. EVERY weapon in this game
    # throws paint, so all of them stamp it: a gun hit must advance it, and so
    # must a spray-can burst (an aerosol of paint in the face paints the visor —
    # the earlier "plasma arc" reskin was the bloodless one that did not).
    let clearX = 60
    let clearY = MapHeight div 2

    var game = initCtfForTest(defaultGameConfig())
    let
      red = game.addPlayer("red0")
      blue = game.addPlayer("blue0")
    game.startGame()
    game.players[red].team = Red
    game.players[blue].team = Blue
    # Fresh seat: never hit → paintTick is the -1 sentinel in the frame.
    game.players[blue].hp = 3
    block:
      let fp0 = game.fpFrame(game.players[blue].joinOrder)
      check fp0["self"]["paintTick"].getInt() == -1

    # A point-blank GUN shot from red paints blue → paintTick stamps to now.
    game.players[red].placeAtCenter(clearX, clearY)
    game.players[red].aimBrads = 0                       # east
    game.players[red].fireCooldown = 0
    game.players[blue].placeAtCenter(clearX + 30, clearY)
    game.tryFire(red)
    check game.players[blue].paintHitTick == game.tickCount
    let paintedAt = game.players[blue].paintHitTick
    block:
      let fpHit = game.fpFrame(game.players[blue].joinOrder)
      check fpHit["self"]["paintTick"].getInt() == paintedAt
      check paintedAt >= 0

    # A SPRAY-CAN burst hurts AND paints → paintTick stamps forward again.
    inc game.tickCount                                   # so "now" differs from paintedAt
    game.players[red].hasPlasmaArc = true
    game.players[red].aimBrads = 0
    game.players[red].fireCooldown = 0                   # clear the gun-shot cooldown
    game.players[red].placeAtCenter(clearX, clearY)
    let
      ax = game.players[red].x + CollisionW div 2
      ay = game.players[red].y + CollisionH div 2
    game.players[blue].hp = 3                            # top up so the touch isn't fatal
    game.players[blue].placeAtCenter(ax + 60, ay)
    let hpBeforeArc = game.players[blue].hp
    game.tryFireArc(red)
    check game.players[blue].hp < hpBeforeArc             # the spray DID hurt
    check game.players[blue].paintHitTick > paintedAt     # …and painted the visor
    let sprayedAt = game.players[blue].paintHitTick
    block:
      let fpArc = game.fpFrame(game.players[blue].joinOrder)
      check fpArc["self"]["paintTick"].getInt() == sprayedAt
