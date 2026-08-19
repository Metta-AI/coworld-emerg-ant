import
  helpers,
  std/unittest,
  ctf/sim

## The second rect stub from the top and from the bottom of column 1
## (x=268..286, plus their x-mirrors) are glass windows: they stay walls for
## movement, bullets, and plasma-arc line-of-sight, but fog-of-war shadowcasting
## sees straight through them. The scene used throughout: a west-side spot at
## (240, 138), the top window stub at x 268..286, y 108..168, and an
## east-side spot at (310, 138) — the straight line between the spots
## crosses only the window.
const
  WestX = 240
  EastX = 310
  RowY = 138                  # center row of the top window stub (y 108..168).
  WindowCx = 277              # column-1 stub center line.
# A template, not a `let`: MapWidth is a process `var`, and in a combined
# test binary an earlier module may leave a different map installed at this
# module's import time — read the width after this suite installs the arena.
template WindowMirrorCx(): int = MapWidth - 268 - 18 + 9  # mirrored stub.
const
  StoneRowY = 40              # center row of stub #1 (y 10..72): stays stone.
  StoneDiamondCx = 349        # column-2 diamond at (349, 282): stays opaque.
  StoneDiamondCy = 282

suite "windows: glass blocks movement and shots but not vision":
  let sim = initCtfForTest()

  test "the test scene is laid out as documented":
    check sim.canOccupy(WestX, RowY)
    check sim.canOccupy(EastX, RowY)
    check sim.isWall(WindowCx, RowY)
    check sim.segmentBlocked(WestX, RowY, EastX, RowY)

  test "windows block movement exactly like stone":
    check not sim.canOccupy(WindowCx, RowY)
    check not sim.canOccupy(WindowMirrorCx, RowY)
    check not sim.isWalkable(WindowCx, RowY)

  test "windows stay in the wall mask, but leave the fog occlusion grid":
    check sim.wallMask[mapIndex(WindowCx, RowY)]
    let (wcx, wcy) = fovCellAt(WindowCx, RowY)
    check not sim.fovBlocked[fovCellIndex(wcx, wcy)]
    # The mirrored stub is glass too.
    check sim.wallMask[mapIndex(WindowMirrorCx, RowY)]
    let (mcx, mcy) = fovCellAt(WindowMirrorCx, RowY)
    check not sim.fovBlocked[fovCellIndex(mcx, mcy)]
    # Stone still occludes: the column-2 diamond's center cell is opaque.
    let (scx, scy) = fovCellAt(StoneDiamondCx, StoneDiamondCy)
    check sim.fovBlocked[fovCellIndex(scx, scy)]

  test "vision passes through a window":
    var visible: seq[bool]
    # Viewer west of the stub aiming due east (0 brads): the spot behind the
    # glass is inside the forward cone and no longer fogged.
    let (vcx, vcy) = fovCellAt(WestX, RowY)
    sim.computeFovVisible(vcx, vcy, 0, visible)
    check sim.fovAt(visible, EastX, RowY)

  test "stone still blocks vision from the same viewpoint":
    var visible: seq[bool]
    # The same scene one stub up: stub #1 (y 10..72) stays stone, so a viewer
    # west of it aiming due east cannot see the east-side spot behind it.
    check sim.canOccupy(WestX, StoneRowY)
    check sim.canOccupy(EastX, StoneRowY)
    let (vcx, vcy) = fovCellAt(WestX, StoneRowY)
    sim.computeFovVisible(vcx, vcy, 0, visible)
    check not sim.fovAt(visible, EastX, StoneRowY)

  test "a player seen through glass cannot be shot through it":
    var game = initCtfForTest()
    let
      shooter = game.addPlayer("red0")
      target = game.addPlayer("blue0")
    game.startGame()
    game.players[shooter].team = Red
    game.players[target].team = Blue
    game.players[shooter].x = WestX
    game.players[shooter].y = RowY
    game.players[shooter].aimBrads = 0          # due east, straight at the glass.
    game.players[target].x = EastX
    game.players[target].y = RowY
    game.armToFire(shooter)
    # Seen: the enemy behind the window is visible through the glass.
    discard game.refreshPlayerFov(shooter)
    check game.playerVisibleTo(shooter, target)
    # Not shot: the bullet stops at the glass — a miss, no damage.
    let hpBefore = game.players[target].hp
    game.tryFire(shooter)
    check game.players[shooter].shotsFired == 1
    check game.players[shooter].shotsHit == 0
    check game.players[target].hp == hpBefore
    # The tracer visibly ends at the window, not at the target.
    check game.recentShots.len > 0
    let tracer = game.recentShots[^1]
    check tracer.x1 < 268                       # stopped at the west face.
    check tracer.x1 > WestX
