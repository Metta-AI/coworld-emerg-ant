import
  helpers,
  std/[random, unittest],
  ctf/sim

proc isWalkable(sim: SimServer, x, y: int): bool =
  x >= 0 and y >= 0 and x < MapWidth and y < MapHeight and
    sim.walkMask[mapIndex(x, y)]

suite "map long sightlines":
  let sim = initCtfForTest()

  test "no full horizontal crossing on any walkable row, at any spin frame":
    ## Since GV28 the center diamonds are live geometry, so which rows they
    ## block is a function of the tick: a crossing that is walled at rest can
    ## open a third of a turn later. The invariant has to hold all turn, so
    ## the scan runs at every frame — and every row, not every fourth, since
    ## the rows that change are exactly the narrow ones near a vertex.
    var spun = sim
    for frame in 0 ..< DiamondSpinFrames:
      spun.applyDiamondGeometry(frame * DiamondSpinTicksPerFrame)
      var open = 0
      for y in 10 ..< MapHeight - 10:
        if (spun.isWalkable(215, y) or spun.isWalkable(1020, y)) and
            not spun.segmentBlocked(215, y, 1020, y):
          inc open
      check open == 0

  test "at least 95% of long diagonals are wall-blocked":
    var rng = initRand(0xC7F5EED)
    proc randomWalkable(): (int, int) =
      while true:
        let
          x = rng.rand(MapWidth - 1)
          y = rng.rand(MapHeight - 1)
        if sim.isWalkable(x, y):
          return (x, y)
    var blocked = 0
    const Pairs = 500
    for _ in 0 ..< Pairs:
      var (ax, ay, bx, by) = (0, 0, 0, 0)
      while true:
        (ax, ay) = randomWalkable()
        (bx, by) = randomWalkable()
        if distSq(ax, ay, bx, by) >= 700 * 700:
          break
      if sim.segmentBlocked(ax, ay, bx, by):
        inc blocked
    echo "long sightlines blocked: ", blocked, "/", Pairs
    check blocked * 100 >= Pairs * 95

  test "capture columns and flag center stay mutually reachable":
    var visited = newSeq[bool](MapWidth * MapHeight)
    var queue = @[(100, MapHeight div 2)]
    visited[mapIndex(100, MapHeight div 2)] = true
    var head = 0
    while head < queue.len:
      let (x, y) = queue[head]
      inc head
      for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)]:
        let
          nx = x + dx
          ny = y + dy
        if sim.isWalkable(nx, ny) and not visited[mapIndex(nx, ny)]:
          visited[mapIndex(nx, ny)] = true
          queue.add((nx, ny))
    check visited[mapIndex(sim.gameMap.center.x, sim.gameMap.center.y)]
    check visited[mapIndex(MapWidth - 100, MapHeight div 2)]
