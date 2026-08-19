import
  helpers,
  std/unittest,
  bitworld/spriteprotocol,
  ctf/sim

suite "fog-of-war vision":
  let sim = initCtfForTest()
  let
    cx = sim.gameMap.center.x   # 617: the vertical strip 596..638 is open.
    cy = sim.gameMap.center.y   # 329

  test "cone membership: ahead is visible, behind and sideways are not":
    var visible: seq[bool]
    # Aiming straight up the open center corridor (64 brads = north).
    sim.computeFovVisible(cx div FovCellSize, cy div FovCellSize, 64, visible)
    check sim.fovAt(visible, cx, 100)          # far ahead, in the cone.
    check not sim.fovAt(visible, cx, 550)      # behind, beyond the bubble.
    check not sim.fovAt(visible, 100, cy)      # 90 degrees off, beyond bubble.

  test "the 60-degree cone edge follows the aim":
    var visible: seq[bool]
    # Aiming up-right at 21 brads (~30 degrees above east): cells up the open
    # center corridor just inside the 60-degree edge stay visible, just
    # outside it fog over.
    sim.computeFovVisible(cx div FovCellSize, cy div FovCellSize, 21, visible)
    check sim.fovAt(visible, 636, 100)         # ~56 degrees off the aim.
    check not sim.fovAt(visible, 604, 100)     # ~64 degrees off the aim.

  test "vision bubble: close cells are visible regardless of aim":
    var visible: seq[bool]
    sim.computeFovVisible(cx div FovCellSize, cy div FovCellSize, 64, visible)
    check sim.fovAt(visible, cx, cy + 40)      # behind but inside the bubble.
    check sim.fovAt(visible, cx - 60, cy)      # sideways, inside the bubble.
    check sim.fovAt(visible, cx, cy)           # own cell.

  test "walls block the cone, glass does not":
    # The midline bracket (GameVersion 16) straddles the center row near
    # x=479..507 with a GLASS pane at the middle of its bar, and the middle
    # column-1 stub (x=268..286, y=300..359) is glass too since
    # GameVersion 27: aiming west from the center the whole lane stays
    # visible through both panes, while a ray off the pane line still fogs
    # behind stone (the bracket bar and the y=204..264 stub).
    var visible: seq[bool]
    sim.computeFovVisible(cx div FovCellSize, cy div FovCellSize, 128, visible)
    check sim.fovAt(visible, 540, cy)          # before the bracket: clear.
    check sim.fovAt(visible, 440, cy)          # behind the glass: visible.
    check sim.fovAt(visible, 250, cy)          # behind BOTH panes: visible.
    check not sim.fovAt(visible, 250, 234)     # off the pane line: fogged.

  test "an open lane stays visible out to the map border (inside vision range)":
    var visible: seq[bool]
    # Aiming down the open center corridor (192 brads = south): the far border
    # is ~319px away, well past the bubble and well inside the 1575px vision
    # range, still visible.
    sim.computeFovVisible(cx div FovCellSize, cy div FovCellSize, 192, visible)
    check sim.fovAt(visible, cx, MapHeight - 20)

  test "the cone cuts off at 1.5x gun range (GV34)":
    # Vision range is derived from the LIVE config.gunRange (1.5x), so a
    # shortened gun proves the cutoff inside the arena: gunRange 200 fogs the
    # open center corridor past 300px even with a clear sightline.
    var config = defaultGameConfig()
    config.update("""{"gunRange": 200}""")
    var short = initCtfForTest(config)
    check short.visionRange == 300
    var visible: seq[bool]
    short.computeFovVisible(cx div FovCellSize, cy div FovCellSize, 192, visible)
    check short.fovAt(visible, cx, cy + 250)       # inside 300px: seen.
    check not short.fovAt(visible, cx, cy + 316)   # past the cutoff: fogged.
    # The stock sim sees the same far cell fine (only the range differs).
    var stock: seq[bool]
    sim.computeFovVisible(cx div FovCellSize, cy div FovCellSize, 192, stock)
    check sim.fovAt(stock, cx, cy + 316)

  test "the close-range bubble is never shrunk by the range cap":
    # Even an absurdly short gun keeps the 90px omnidirectional bubble: the
    # cap applies to the cone, not to close-quarters awareness.
    var config = defaultGameConfig()
    config.update("""{"gunRange": 40}""")
    var short = initCtfForTest(config)
    check short.visionRange == 60
    var visible: seq[bool]
    short.computeFovVisible(cx div FovCellSize, cy div FovCellSize, 64, visible)
    check short.fovAt(visible, cx - 80, cy)        # sideways, inside the bubble.
    check not short.fovAt(visible, cx - 150, cy)   # outside bubble AND cone.
    check not short.fovAt(visible, cx, cy - 200)   # dead ahead, past the cap.

  test "everyone but yourself is culled when fogged, teammates included":
    var game = initCtfForTest()
    discard game.addPlayer("red0")
    discard game.addPlayer("blue0")
    discard game.addPlayer("red1")
    game.startGame()
    game.players[0].team = Red
    game.players[1].team = Blue
    game.players[2].team = Red
    # Viewer red0 stands at the center aiming up the open corridor.
    game.players[0].x = cx
    game.players[0].y = cy
    game.players[0].aimBrads = 64
    # Enemy ahead in the cone: visible.
    game.players[1].x = cx
    game.players[1].y = 100
    discard game.refreshPlayerFov(0)
    check game.playerVisibleTo(0, 1)
    # Enemy behind, beyond the bubble: fogged.
    game.players[1].y = 550
    check not game.playerVisibleTo(0, 1)
    # A teammate at the same fogged spot fogs too (no team radio).
    game.players[2].x = cx
    game.players[2].y = 550
    check not game.playerVisibleTo(0, 2)
    # A teammate ahead in the cone is visible like anyone else.
    game.players[2].y = 100
    check game.playerVisibleTo(0, 2)
    # And the viewer always sees itself.
    check game.playerVisibleTo(0, 0)

  test "the vision cone follows the aim, not the movement":
    var game = initCtfForTest()
    discard game.addPlayer("red0")
    discard game.addPlayer("blue0")
    game.startGame()
    game.players[0].team = Red
    game.players[1].team = Blue
    # Viewer at the center aiming north; enemy south, beyond the bubble.
    game.players[0].x = cx
    game.players[0].y = cy - 60
    game.players[0].aimBrads = 64
    game.players[1].x = cx
    game.players[1].y = 550
    discard game.refreshPlayerFov(0)
    check not game.playerVisibleTo(0, 1)
    # Walking TOWARD the enemy does not swing the cone: still fogged.
    var inputs = newSeq[InputState](game.players.len)
    let noInput = newSeq[InputState](game.players.len)
    inputs[0] = InputState(down: true)
    for _ in 1 .. 10:
      game.step(inputs, noInput)
    check game.players[0].y > cy - 60      # the viewer really moved south...
    check game.players[0].aimBrads == 64   # ...with the aim untouched.
    discard game.refreshPlayerFov(0)
    check not game.playerVisibleTo(0, 1)
    # Rotating the aim around to south (64 -> ~192 via B) reveals the enemy.
    inputs[0] = InputState(b: true)
    while game.players[0].aimBrads < 190:
      game.step(inputs, noInput)
    discard game.refreshPlayerFov(0)
    check game.playerVisibleTo(0, 1)

  test "pedestal flags are always visible; carried flags follow the carrier":
    var game = initCtfForTest()
    discard game.addPlayer("red0")
    discard game.addPlayer("blue0")
    game.startGame()
    game.players[0].team = Red
    game.players[1].team = Blue
    game.players[0].x = cx
    game.players[0].y = cy
    game.players[0].aimBrads = 64
    discard game.refreshPlayerFov(0)
    # Both pedestals sit far outside the up-aimed cone yet stay visible.
    check game.flagVisibleTo(0, Red)
    check game.flagVisibleTo(0, Blue)
    # The enemy steals the red flag and runs behind the viewer: fogged.
    game.players[1].x = cx
    game.players[1].y = 550
    game.flags[Red].carrier = 1
    game.players[1].carryingFlag = true
    check not game.flagVisibleTo(0, Red)
    # The same carrier ahead in the cone: visible again.
    game.players[1].y = 100
    check game.flagVisibleTo(0, Red)

  test "dead viewers see nothing but themselves":
    var game = initCtfForTest()
    discard game.addPlayer("red0")
    discard game.addPlayer("blue0")
    game.startGame()
    game.players[0].team = Red
    game.players[1].team = Blue
    game.players[0].x = cx
    game.players[0].y = cy
    game.players[0].aimBrads = 64
    game.players[0].alive = false
    game.players[1].x = cx
    game.players[1].y = 550
    # Death does not lift the fog: everything is masked until respawn —
    # even a target standing right where the viewer died.
    check not game.playerVisibleTo(0, 1)
    check not game.fovVisibleAt(0, cx, cy)
    check game.playerVisibleTo(0, 0)
