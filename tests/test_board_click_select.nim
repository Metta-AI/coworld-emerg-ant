import
  helpers,
  std/unittest,
  ctf/[global, sim]

const
  MapLayerId = 0

proc clickBoard(
  state: var GlobalViewerState,
  x, y: int
) =
  ## Queues one board (map-layer) click, exactly as the browser client's canvas
  ## click listener does: coords in the RenderScale× wire space the spectator
  ## map layer is served at (the client inverse-transforms into the viewport
  ## it was announced, so a scaled board sends scaled coordinates).
  state.mouseLayer = MapLayerId
  state.mouseX = x * RenderScale
  state.mouseY = y * RenderScale
  state.mouseDown = false
  state.clickPending = true

suite "board-click player selection":
  test "clicking a soldier on the board selects it and enters its POV":
    var game = initCtfForTest(defaultGameConfig())
    let
      red = game.addPlayer("red0")
      blue = game.addPlayer("blue0")
    game.startGame()
    game.players[red].team = Red
    game.players[blue].team = Blue
    # Place the blue player at a known spot, away from the red one.
    game.players[red].x = 200
    game.players[red].y = 200
    game.players[blue].x = 900
    game.players[blue].y = 400

    var state = initGlobalViewerState()
    var next: GlobalViewerState
    # Prime the viewer.
    discard game.buildSpriteProtocolUpdates(state, next)
    state = next
    check next.selectedJoinOrder == -1
    check not next.povActive

    # Click dead-center of the blue soldier's body footprint. The 16px helmet
    # square is centered on the player position, so the player point itself is
    # inside the hit-box.
    let
      bx = game.players[blue].x + CollisionW div 2
      by = game.players[blue].y + CollisionH div 2
    state.clickBoard(bx, by)
    discard game.buildSpriteProtocolUpdates(state, next)
    # A board click selects the soldier and enters the same POV lens the squad
    # pips use — this is the entry path that was previously unreachable because
    # the client never forwarded board clicks.
    check next.selectedJoinOrder == game.players[blue].joinOrder
    check next.povActive
    state = next

    # While in POV the board IS that player's fogged view, so further board
    # clicks are ignored (you exit via the squad-pip toggle). The selection
    # therefore holds rather than toggling off.
    state.clickBoard(bx, by)
    discard game.buildSpriteProtocolUpdates(state, next)
    check next.selectedJoinOrder == game.players[blue].joinOrder

  test "clicking empty arena selects nothing":
    var game = initCtfForTest(defaultGameConfig())
    let red = game.addPlayer("red0")
    let blue = game.addPlayer("blue0")
    game.startGame()
    game.players[red].team = Red
    game.players[blue].team = Blue
    game.players[red].x = 200
    game.players[red].y = 200
    game.players[blue].x = 900
    game.players[blue].y = 400

    var state = initGlobalViewerState()
    var next: GlobalViewerState
    discard game.buildSpriteProtocolUpdates(state, next)
    state = next

    # A patch of arena with no soldier under it.
    state.clickBoard(600, 100)
    discard game.buildSpriteProtocolUpdates(state, next)
    check next.selectedJoinOrder == -1
