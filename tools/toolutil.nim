## Shared plumbing for the offline forensic/demo tools in tools/.
## Not part of the server.
##
## Three families of boilerplate live here:
##   1. chdirGameDir / GameDir — repo-root chdir so `data/` assets resolve
##      no matter where the tool is invoked from.
##   2. openReplay — the tools' standard replay-stepping setup: fresh sim at
##      tick 0, no keyframes, non-looping hash-checked playback. This is
##      deliberately NOT src/ctf/replay_runtime.initReplayRuntime, which
##      builds seek keyframes (a full extra simulation pass) and starts
##      playback at the post-lobby start tick — both would change the
##      tick-by-tick output these tools print.
##   3. Sprite-packet -> pixie compositors: the one-shot full-packet
##      composite (fresh viewer state per frame) and the persistent
##      SpriteWorld for the DELTA protocol (later packets carry only
##      changes plus deletes, so a client-like accumulated world is needed).
import
  std/[algorithm, os, tables],
  pixie, supersnappy,
  bitworld/spriteprotocol,
  ../src/ctf/[global, replays, sim]

export replays, spriteprotocol

const GameDir* = currentSourcePath().parentDir().parentDir()

proc chdirGameDir*() =
  ## Enters the repo root so relative asset paths (`data/...`) resolve.
  setCurrentDir(GameDir)

proc openReplay*(
  data: ReplayData,
  gameEventLoggingEnabled = false,
  mismatchQuit = true
): tuple[game: SimServer, replay: ReplayPlayer] =
  ## Standard tool setup for re-simulating a replay from tick 0: sim built
  ## from the recorded config, non-looping playback, recorded-hash checking
  ## on (quitting on mismatch unless told otherwise).
  var config = defaultGameConfig()
  config.update(data.configJson)
  result.game = initSimServer(config)
  result.game.gameEventLoggingEnabled = gameEventLoggingEnabled
  result.replay = initReplayPlayer(data)
  result.replay.looping = false
  result.replay.mismatchQuit = mismatchQuit

proc openReplay*(
  path: string,
  gameEventLoggingEnabled = false,
  mismatchQuit = true
): tuple[game: SimServer, replay: ReplayPlayer] =
  ## `openReplay` over a .bitreplay file path.
  openReplay(loadReplay(path), gameEventLoggingEnabled, mismatchQuit)

proc spriteToImage*(pixels: seq[uint8], width, height: int): Image =
  ## Straight-RGBA byte buffer -> pixie image.
  result = newImage(width, height)
  for i in 0 ..< width * height:
    result.data[i] = rgba(
      pixels[i * 4], pixels[i * 4 + 1], pixels[i * 4 + 2], pixels[i * 4 + 3]
    ).rgbx()

proc decodeSprite*(def: SpritePacketSpriteDef): Image =
  ## Snappy-compressed RGBA sprite payload -> pixie image. Returns nil for
  ## non-RGBA payloads (palette/UI sprites) so board compositors skip them.
  let raw = supersnappy.uncompress(def.compressedPixels)
  if raw.len < def.width * def.height * 4:
    return nil
  result = newImage(def.width, def.height)
  for i in 0 ..< def.width * def.height:
    result.data[i] = rgba(
      raw[i * 4], raw[i * 4 + 1], raw[i * 4 + 2], raw[i * 4 + 3]
    ).rgbx()

proc compositeBoard*(
  messages: seq[SpritePacketMessage],
  scale = RenderScale
): Image =
  ## Composites one FULL sprite packet (built against a fresh viewer state,
  ## so nothing rides on earlier deltas): decode every sprite, find the map
  ## layer by the full-board band width, blit that layer's objects in z
  ## order. `scale` is the board scale the packet was emitted at.
  var sprites: seq[tuple[id: int, image: Image]]
  proc spriteImage(id: int): Image =
    for s in sprites:
      if s.id == id:
        return s.image
    nil
  for m in messages:
    if m.kind == spkSprite:
      sprites.add((m.sprite.id, decodeSprite(m.sprite)))
  var mapSprites: seq[int]
  for m in messages:
    if m.kind == spkSprite and m.sprite.width == MapWidth * scale:
      mapSprites.add(m.sprite.id)
  var mapLayer = -1
  for m in messages:
    if m.kind == spkObject and m.objectDef.spriteId in mapSprites:
      mapLayer = m.objectDef.layer
  var objects: seq[SpritePacketObject]
  for m in messages:
    if m.kind == spkObject and m.objectDef.layer == mapLayer:
      objects.add(m.objectDef)
  objects.sort(proc (a, b: SpritePacketObject): int = cmp(a.z, b.z))
  result = newImage(MapWidth * scale, MapHeight * scale)
  result.fill(rgba(20, 18, 16, 255))
  for obj in objects:
    let image = spriteImage(obj.spriteId)
    if image.isNil:
      continue
    result.draw(image, translate(vec2(float32(obj.x), float32(obj.y))))

proc renderBoardFrame*(sim: var SimServer, scale = RenderScale): Image =
  ## Builds one full sprite packet against a fresh viewer state and
  ## composites it — the "rebuild everything each sampled tick" pattern.
  var
    state = initGlobalViewerState()
    next: GlobalViewerState
  compositeBoard(
    sim.buildSpriteProtocolUpdates(state, next).parseSpritePacket(), scale
  )

type SpriteWorld* = object
  ## Client-like persistent sprite/object world for the DELTA sprite wire:
  ## every packet must be applied on top of the last, exactly as a real
  ## viewer does — a per-packet composite would render every frame after
  ## the first as bare floor.
  sprites*: Table[int, Image]
  labels*: Table[int, string]      ## sprite id -> wire label, as received.
  world*: Table[int, SpritePacketObject]
  mapLayer*: int
  mapSpriteIds*: seq[int]

proc initSpriteWorld*(): SpriteWorld =
  SpriteWorld(mapLayer: -1)

proc apply*(world: var SpriteWorld, messages: seq[SpritePacketMessage]) =
  ## Applies one parsed packet to the persistent world.
  for m in messages:
    case m.kind
    of spkSprite:
      world.sprites[m.sprite.id] = decodeSprite(m.sprite)
      world.labels[m.sprite.id] = m.sprite.label
      if m.sprite.width == MapWidth * RenderScale:
        world.mapSpriteIds.add(m.sprite.id)
    of spkObject:
      world.world[m.objectDef.id] = m.objectDef
      if m.objectDef.spriteId in world.mapSpriteIds:
        world.mapLayer = m.objectDef.layer
    of spkDeleteObject:
      world.world.del(m.objectId)
    of spkClearObjects:
      world.world.clear()
    else:
      discard

proc renderBoard*(world: SpriteWorld): Image =
  ## Composites the accumulated map-layer objects in z order at board scale.
  var objects: seq[SpritePacketObject]
  for _, obj in world.world:
    if obj.layer == world.mapLayer:
      objects.add(obj)
  objects.sort(proc (a, b: SpritePacketObject): int = cmp(a.z, b.z))
  result = newImage(MapWidth * RenderScale, MapHeight * RenderScale)
  result.fill(rgba(20, 18, 16, 255))
  for obj in objects:
    if obj.spriteId in world.sprites:
      let image = world.sprites[obj.spriteId]
      if image.isNil:
        continue
      result.draw(image, translate(vec2(float32(obj.x), float32(obj.y))))
