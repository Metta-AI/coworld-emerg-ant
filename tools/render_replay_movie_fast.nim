## Incremental variant of render_replay_movie for OVERSIZE maps: keeps one
## persistent GlobalViewerState across sampled ticks so the map bands ship
## once, composites the static map background a single time, and per frame
## redraws only the dynamic objects on top of a cached background. Optional
## integer downscale before the PNG write. Demo tooling; not part of the
## server.
## Usage: render_replay_movie_fast <replay> <outDir> [everyN] [fromTick]
##        [toTick] [scaleDiv]
import
  std/[algorithm, monotimes, os, sets, strformat, strutils, tables, times],
  pixie,
  bitworld/spriteprotocol,
  ../src/ctf/[global, sim],
  toolutil

## Divergent from toolutil's SpriteWorld ON PURPOSE: this tool's point is the
## band/dynamic split with a cached composited background (plus per-stage
## timing), so only the sprite decode and the replay-open dance are shared.
type ViewerModel = object
  sprites: Table[int, Image]
  objects: Table[int, SpritePacketObject]
  bandIds: HashSet[int]
  mapLayer: int
  background: Image
  backgroundDirty: bool

proc apply(model: var ViewerModel, messages: seq[SpritePacketMessage]) =
  for m in messages:
    case m.kind
    of spkSprite:
      model.sprites[m.sprite.id] = decodeSprite(m.sprite)
      if m.sprite.width == MapWidth * RenderScale:
        model.bandIds.incl(m.sprite.id)
        model.backgroundDirty = true
    of spkObject:
      model.objects[m.objectDef.id] = m.objectDef
      if m.objectDef.spriteId in model.bandIds:
        model.mapLayer = m.objectDef.layer
        model.backgroundDirty = true
    of spkDeleteObject:
      if m.objectId in model.objects:
        if model.objects[m.objectId].spriteId in model.bandIds:
          model.backgroundDirty = true
        model.objects.del(m.objectId)
    of spkClearObjects:
      model.objects.clear()
      model.backgroundDirty = true
    of spkViewport, spkLayer:
      discard

proc sortedLayerObjects(
  model: ViewerModel, bands: bool
): seq[SpritePacketObject] =
  for obj in model.objects.values:
    if obj.layer == model.mapLayer and
        (obj.spriteId in model.bandIds) == bands:
      result.add(obj)
  result.sort(proc (a, b: SpritePacketObject): int = cmp(a.z, b.z))

proc renderFrame(model: var ViewerModel): Image =
  if model.backgroundDirty:
    model.background = newImage(MapWidth * RenderScale, MapHeight * RenderScale)
    model.background.fill(rgba(20, 18, 16, 255))
    for obj in model.sortedLayerObjects(bands = true):
      let image = model.sprites.getOrDefault(obj.spriteId)
      if image.isNil:
        continue
      model.background.draw(
        image, translate(vec2(float32(obj.x), float32(obj.y))))
    model.backgroundDirty = false
  result = model.background.copy()
  for obj in model.sortedLayerObjects(bands = false):
    let image = model.sprites.getOrDefault(obj.spriteId)
    if image.isNil:
      continue
    result.draw(image, translate(vec2(float32(obj.x), float32(obj.y))))

proc main() =
  let
    replayPath = paramStr(1)
    outDir = paramStr(2)
    everyN = if paramCount() >= 3: parseInt(paramStr(3)) else: 3
    fromTick = if paramCount() >= 4: parseInt(paramStr(4)) else: 0
    toTick = if paramCount() >= 5: parseInt(paramStr(5)) else: high(int)
    scaleDiv = if paramCount() >= 6: parseInt(paramStr(6)) else: 1
  createDir(outDir)
  var (sim, replay) = openReplay(replayPath)
  var
    model = ViewerModel(mapLayer: -1, backgroundDirty: false)
    state = initGlobalViewerState()
  let maxTick = min(toTick, replay.replayMaxTick())
  var frame = 0
  while sim.tickCount < maxTick and replay.playing:
    replay.stepReplay(sim)
    if sim.tickCount < fromTick or sim.tickCount mod everyN != 0:
      continue
    var t0 = getMonoTime()
    var next: GlobalViewerState
    let messages =
      sim.buildSpriteProtocolUpdates(state, next).parseSpritePacket()
    state = next
    let buildMs = (getMonoTime() - t0).inMilliseconds
    var spritePx = 0
    for m in messages:
      if m.kind == spkSprite:
        spritePx += m.sprite.width * m.sprite.height
    t0 = getMonoTime()
    model.apply(messages)
    let applyMs = (getMonoTime() - t0).inMilliseconds
    t0 = getMonoTime()
    var canvas = model.renderFrame()
    let drawMs = (getMonoTime() - t0).inMilliseconds
    t0 = getMonoTime()
    if scaleDiv > 1:
      canvas = canvas.resize(canvas.width div scaleDiv, canvas.height div scaleDiv)
    let resizeMs = (getMonoTime() - t0).inMilliseconds
    t0 = getMonoTime()
    canvas.writeFile(outDir / &"frame-{frame:05}.png")
    let pngMs = (getMonoTime() - t0).inMilliseconds
    echo &"frame {frame}: build {buildMs} apply {applyMs} " &
      &"(px {spritePx}) draw {drawMs} resize {resizeMs} png {pngMs}"
    inc frame
    if frame mod 50 == 0:
      echo "tick ", sim.tickCount, " -> ", frame, " frames"
  echo "wrote ", frame, " frames to ", outDir, " (last tick ",
    sim.tickCount, ")"

main()
