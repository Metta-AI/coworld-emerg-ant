import
  helpers,
  std/unittest,
  bitworld/spriteprotocol,
  ctf/sim

suite "movement footprint":
  test "moves across open floor toward input":
    var sim = initCtfForTest(defaultGameConfig())
    let p = sim.addPlayer("mover")
    sim.blockAll()
    sim.openField(40, 40, 240, 240)
    sim.placeStill(p, 100, 100)
    for _ in 0 .. 20:
      sim.applyInput(p, InputState(right: true))
    check sim.players[p].x > 100          # accelerated to the right
    check sim.players[p].y == 100          # no vertical drift

  test "solid footprint cannot overlap a wall":
    var sim = initCtfForTest(defaultGameConfig())
    let p = sim.addPlayer("bumper")
    sim.blockAll()
    sim.openField(40, 40, 240, 240)
    # Wall column starting at x = 150.
    for y in 40 .. 240:
      for x in 150 .. 240:
        sim.walkMask[mapIndex(x, y)] = false
    sim.placeStill(p, 100, 100)
    for _ in 0 .. 80:
      sim.applyInput(p, InputState(right: true))
    check sim.players[p].x > 100                    # advanced toward the wall
    check sim.players[p].x + PlayerHalf < 150        # but never entered it
