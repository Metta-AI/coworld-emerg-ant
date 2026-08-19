## Renders the SPRAY CAN weapon to PNGs without a server or a replay: poses the
## sim by hand (a floor pickup, a carrier holding one, and a live burst), builds
## REAL global sprite packets via buildSpriteProtocolUpdates, composites the map
## layer in z order, and crops each subject.
##
## This is the probe pattern (see tools/render_frame.nim): a recorded fixture only
## shows the weapon if a bot happens to walk into a pickup, so posing the state is
## the reliable way to see the art. It also PRINTS the emitted sprite labels, so
## the machine-facing contract is verified in the same run as the pixels.
##
## The burst is rendered at EVERY age in its lifetime (one frame per FX tick) and
## also written as a filmstrip, because the cone is ANIMATED — it jets out from
## the nozzle as it ages — and a single frame cannot show that.
##
## Usage (from the repo root): nim r tools/spray_probe.nim [outDir]
import
  std/[os, strutils, tables],
  pixie,
  ../src/ctf/[global, sim],
  toolutil

proc main() =
  let outDir = if paramCount() >= 1: paramStr(1) else: "/tmp"
  chdirGameDir()

  var sim = initSimServer(defaultGameConfig())
  sim.gameEventLoggingEnabled = false
  let
    red = sim.addPlayer("red0")
    blue = sim.addPlayer("blue0")
  sim.startGame()
  sim.players[red].team = Red
  sim.players[blue].team = Blue

  proc placeAt(index, x, y: int) =
    sim.players[index].x = x - CollisionW div 2
    sim.players[index].y = y - CollisionH div 2

  # Open floor with clear line of sight. Most poses on the center row are blocked
  # by the slalom; this one connects (swept by hand when writing the probe).
  let
    midY = MapHeight div 2
    sprayerX = 300
    sprayerY = midY - 90

  placeAt(red, sprayerX, sprayerY)
  sim.players[red].aimBrads = 0
  sim.players[red].hasPlasmaArc = true
  sim.players[red].fireCooldown = 0
  placeAt(blue, sprayerX + 100, sprayerY)
  sim.players[blue].hp = 3
  sim.tryFireArc(red)
  echo "spray fired: cone flashes=", sim.plasmaArcFlashes.len,
    " victim hp=", sim.players[blue].hp,
    " victim paintHitTick=", sim.players[blue].paintHitTick,
    " (tick ", sim.tickCount, ")"

  # The sprite wire is a DELTA protocol: after the first packet, later ones carry
  # only what CHANGED plus deletes. So the probe keeps a persistent sprite/object
  # world (exactly as a real client does) and applies each packet to it — a
  # per-packet composite would render every frame after the first as bare floor.
  var
    state = initGlobalViewerState()
    next: GlobalViewerState
    world = initSpriteWorld()

  proc renderBoard(): Image =
    world.apply(sim.buildSpriteProtocolUpdates(state, next).parseSpritePacket())
    state = next
    world.renderBoard()

  proc cropOf(board: Image, cx, cy, w, h: int): Image =
    let
      x0 = clamp(cx * RenderScale - w div 2, 0, MapWidth * RenderScale - w)
      y0 = clamp(cy * RenderScale - h div 2, 0, MapHeight * RenderScale - h)
    board.subImage(x0, y0, w, h)

  const
    BurstW = 360
    BurstH = 170
  let burstCx = sprayerX + PlasmaArcReach div 2

  # The animation: one frame per FX tick, so the jet's growth is visible.
  var frames: seq[Image]
  for f in 0 .. PlasmaArcFxTicks:
    let board = renderBoard()
    let shot = cropOf(board, burstCx, sprayerY, BurstW, BurstH)
    frames.add shot
    shot.resize(BurstW * 2, BurstH * 2)
      .writeFile(outDir / ("spray-burst-t" & $f & ".png"))
    if f == 0:
      # Subjects that don't animate, grabbed from the first frame.
      cropOf(board, sprayerX, sprayerY - 20, 130, 130)
        .resize(130 * 3, 130 * 3).writeFile(outDir / "spray-carried.png")
      let spawn = loadCtfMapMetadata("arena").plasmaArcSpawnPoints()[0]
      cropOf(board, spawn.x, spawn.y, 120, 120)
        .resize(120 * 3, 120 * 3).writeFile(outDir / "spray-pickup.png")
    inc sim.tickCount            # age the flash by one tick

  var strip = newImage(BurstW, BurstH * frames.len)
  for i, f in frames:
    strip.draw(f, translate(vec2(0, float32(i * BurstH))))
  strip.writeFile(outDir / "spray-anim-strip.png")
  echo "wrote ", frames.len, " burst frames + spray-anim-strip.png to ", outDir

  echo "--- spray / weapon sprite labels on the wire ---"
  for id, label in world.labels:
    if "spray" in label or "cog gun" in label or "weapon " in label or
        "identity " in label:
      echo "  sprite ", id, "  \"", label, "\""

main()
