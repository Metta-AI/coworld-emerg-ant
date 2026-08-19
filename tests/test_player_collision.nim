import
  helpers,
  std/unittest,
  bitworld/spriteprotocol,
  ctf/sim

proc bodyGap(sim: SimServer, a, b: int): int =
  ## Chebyshev distance between two player centers; footprints overlap
  ## when this is <= PlayerSolidSpan.
  max(
    abs(sim.players[a].x - sim.players[b].x),
    abs(sim.players[a].y - sim.players[b].y)
  )

suite "player body collisions":
  test "a mover cannot drive over a standing player":
    var sim = initCtfForTest(defaultGameConfig())
    let
      mover = sim.addPlayer("mover")
      wall = sim.addPlayer("wall")
    sim.blockAll()
    sim.openField(40, 40, 340, 240)
    sim.placeStill(mover, 100, 140)
    sim.placeStill(wall, 160, 140)
    for _ in 0 .. 120:
      sim.applyInput(mover, InputState(right: true))
      # The standing player idles (friction only) but still resolves input.
      sim.applyInput(wall, InputState())
      check sim.bodyGap(mover, wall) > PlayerSolidSpan  # never overlapping
    check sim.players[mover].x > 100                    # advanced into contact

  test "ramming shoves the standing player forward":
    var sim = initCtfForTest(defaultGameConfig())
    let
      mover = sim.addPlayer("mover")
      target = sim.addPlayer("target")
    sim.blockAll()
    sim.openField(40, 40, 640, 240)
    sim.placeStill(mover, 100, 140)
    sim.placeStill(target, 140, 140)
    for _ in 0 .. 60:
      sim.applyInput(mover, InputState(right: true))
      sim.applyInput(target, InputState())
    check sim.players[target].x > 140                   # got pushed along
    check sim.players[target].velX >= 0

  test "head-on collision bounces both movers back":
    var sim = initCtfForTest(defaultGameConfig())
    let
      left = sim.addPlayer("left")
      right = sim.addPlayer("right")
    sim.blockAll()
    sim.openField(40, 40, 640, 240)
    sim.placeStill(left, 100, 140)
    sim.placeStill(right, 200, 140)
    var bounced = false
    for _ in 0 .. 40:
      # Drive both toward each other until the frame after first contact.
      sim.applyInput(left, InputState(right: true))
      sim.applyInput(right, InputState(left: true))
      check sim.bodyGap(left, right) > PlayerSolidSpan
      if sim.players[left].velX < 0 and sim.players[right].velX > 0:
        bounced = true
        break
    check bounced                                       # both rebounded

  test "dead players never block movement":
    var sim = initCtfForTest(defaultGameConfig())
    let
      mover = sim.addPlayer("mover")
      corpse = sim.addPlayer("corpse")
    sim.blockAll()
    sim.openField(40, 40, 640, 240)
    sim.placeStill(mover, 100, 140)
    sim.placeStill(corpse, 160, 140)
    sim.players[corpse].alive = false
    for _ in 0 .. 60:
      sim.applyInput(mover, InputState(right: true))
    check sim.players[mover].x > 160 + PlayerSolidSpan  # drove straight past

  test "overlapping players can move apart but not further in":
    var sim = initCtfForTest(defaultGameConfig())
    let
      a = sim.addPlayer("a")
      b = sim.addPlayer("b")
    sim.blockAll()
    sim.openField(40, 40, 640, 240)
    # Force an overlapped start (a respawn onto an occupied home).
    sim.placeStill(a, 160, 140)
    sim.placeStill(b, 166, 140)
    let startGap = sim.bodyGap(a, b)
    for _ in 0 .. 30:
      sim.applyInput(a, InputState(left: true))
      sim.applyInput(b, InputState())
      check sim.bodyGap(a, b) >= startGap               # never deeper in
    check sim.bodyGap(a, b) > PlayerSolidSpan           # escaped the overlap
