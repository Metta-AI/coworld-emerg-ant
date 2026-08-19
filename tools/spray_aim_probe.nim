## Renders the spray plume at several AIM angles, to prove the nozzle offset is
## in aim space (rotates with the cog) and not a fixed screen-space nudge.
## Usage (repo root): nim r tools/spray_aim_probe.nim [outDir]
import
  std/os,
  pixie,
  ../src/ctf/[global, sim],
  toolutil

proc main() =
  let outDir = if paramCount() >= 1: paramStr(1) else: "/tmp"
  chdirGameDir()
  const Steps = [0, 32, 64, 96, 128, 160, 192, 224]   # E, NE, N, NW, W, SW, S, SE
  var tiles: seq[Image]
  for brads in Steps:
    var sim = initSimServer(defaultGameConfig())
    sim.gameEventLoggingEnabled = false
    let red = sim.addPlayer("red0")
    discard sim.addPlayer("blue0")
    sim.startGame()
    sim.players[red].team = Red
    # Open center-ish floor so the plume has room in every direction.
    sim.players[red].x = MapWidth div 2 - CollisionW div 2
    sim.players[red].y = MapHeight div 2 - CollisionH div 2
    sim.players[red].aimBrads = brads
    sim.players[red].hasPlasmaArc = true
    sim.players[red].fireCooldown = 0
    sim.tryFireArc(red)

    var
      state = initGlobalViewerState()
      next: GlobalViewerState
      world = initSpriteWorld()
    world.apply(sim.buildSpriteProtocolUpdates(state, next).parseSpritePacket())
    let board = world.renderBoard()
    const S = 210
    let
      cx = (MapWidth div 2) * RenderScale
      cy = (MapHeight div 2) * RenderScale
    tiles.add board.subImage(cx - S div 2, cy - S div 2, S, S)

  let s = tiles[0].width
  var sheet = newImage(s * 4, s * 2)
  for i, t in tiles:
    sheet.draw(t, translate(vec2(float32((i mod 4) * s), float32((i div 4) * s))))
  sheet.writeFile(outDir / "spray-aim-sheet.png")
  echo "wrote ", outDir / "spray-aim-sheet.png", " (E NE N NW / W SW S SE)"

main()
