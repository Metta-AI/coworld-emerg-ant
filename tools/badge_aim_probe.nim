## Renders one cog's identity badge at eight AIM angles, to prove the badge sits
## on the head plate BEHIND the visor (never over the face) and that its Greek
## glyph turns WITH the cog instead of floating upright.
## Usage (repo root): nim r tools/badge_aim_probe.nim [outDir]
import
  std/[algorithm, os, strformat, strutils, tables],
  pixie, supersnappy,
  bitworld/spriteprotocol,
  ../src/ctf/global, ../src/ctf/sim

proc povBadgeDigest() =
  ## Prints where a PLAYER view puts the badge and a checksum of its pixels, at
  ## two different aims: the observation contract says the badge is centered on
  ## its player's body, so both numbers must be aim-INDEPENDENT and identical
  ## before and after any board-side change.
  for brads in [0, 96]:
    var sim = initSimServer(defaultGameConfig())
    sim.gameEventLoggingEnabled = false
    let me = sim.addPlayer("red0")
    discard sim.addPlayer("blue0")
    sim.startGame()
    sim.players[me].x = MapWidth div 2
    sim.players[me].y = MapHeight div 2
    sim.players[me].aimBrads = brads
    var state, next: PlayerViewerState
    var labels: Table[int, string]
    var sums: Table[int, int]
    for m in sim.buildSpriteProtocolPlayerUpdates(me, state, next)
        .parseSpritePacket():
      if m.kind == spkSprite:
        labels[m.sprite.id] = m.sprite.label
        var sum = 0
        for i, b in supersnappy.uncompress(m.sprite.compressedPixels):
          sum = (sum * 31 + int(b) * (i mod 7 + 1)) mod 1_000_003
        sums[m.sprite.id] = sum
    for m in sim.buildSpriteProtocolPlayerUpdates(me, state, next)
        .parseSpritePacket():
      if m.kind == spkObject and
          labels.getOrDefault(m.objectDef.spriteId).startsWith("identity red"):
        echo &"pov aim={brads} label='{labels[m.objectDef.spriteId]}' " &
          &"dx={m.objectDef.x - sim.players[me].x} " &
          &"dy={m.objectDef.y - sim.players[me].y} " &
          &"pixels={sums.getOrDefault(m.objectDef.spriteId)}"

proc main() =
  let outDir = if paramCount() >= 1: paramStr(1) else: "/tmp"
  setCurrentDir(currentSourcePath().parentDir().parentDir())
  const Steps = [0, 32, 64, 96, 128, 160, 192, 224]   # E, NE, N, NW, W, SW, S, SE
  var tiles: seq[Image]
  for brads in Steps:
    var sim = initSimServer(defaultGameConfig())
    sim.gameEventLoggingEnabled = false
    let red = sim.addPlayer("red0")
    discard sim.addPlayer("blue0")
    sim.startGame()
    sim.players[red].team = Red
    sim.players[red].x = MapWidth div 2 - CollisionW div 2
    sim.players[red].y = MapHeight div 2 - CollisionH div 2
    sim.players[red].aimBrads = brads

    var
      state = initGlobalViewerState()
      next: GlobalViewerState
      sprites: Table[int, Image]
      world: Table[int, SpritePacketObject]
      mapLayer = -1
      mapIds: seq[int]
    for m in sim.buildSpriteProtocolUpdates(state, next).parseSpritePacket():
      case m.kind
      of spkSprite:
        let raw = supersnappy.uncompress(m.sprite.compressedPixels)
        var img = newImage(m.sprite.width, m.sprite.height)
        for y in 0 ..< m.sprite.height:
          for x in 0 ..< m.sprite.width:
            let i = y * m.sprite.width + x
            img[x, y] = rgba(raw[i*4], raw[i*4+1], raw[i*4+2], raw[i*4+3])
        sprites[m.sprite.id] = img
        if m.sprite.width == MapWidth * RenderScale: mapIds.add m.sprite.id
      of spkObject:
        world[m.objectDef.id] = m.objectDef
        if m.objectDef.spriteId in mapIds: mapLayer = m.objectDef.layer
      else: discard
    var objs: seq[SpritePacketObject]
    for _, o in world:
      if o.layer == mapLayer: objs.add o
    objs.sort(proc (a, b: SpritePacketObject): int = cmp(a.z, b.z))
    var board = newImage(MapWidth * RenderScale, MapHeight * RenderScale)
    board.fill(rgba(20, 18, 16, 255))
    for o in objs:
      if o.spriteId in sprites:
        board.draw(sprites[o.spriteId], translate(vec2(float32(o.x), float32(o.y))))
    const S = 56 * RenderScale
    let
      cx = (MapWidth div 2) * RenderScale
      cy = (MapHeight div 2) * RenderScale
      crop = board.subImage(cx - S div 2, cy - S div 2, S, S)
    tiles.add crop.resize(S * 3, S * 3)

  let s = tiles[0].width
  var sheet = newImage(s * 4, s * 2)
  for i, t in tiles:
    sheet.draw(t, translate(vec2(float32((i mod 4) * s), float32((i div 4) * s))))
  let name = if paramCount() >= 2: paramStr(2) else: "badge-aim-sheet.png"
  sheet.writeFile(outDir / name)
  echo "wrote ", outDir / name, " (E NE N NW / W SW S SE)"
  povBadgeDigest()

main()
