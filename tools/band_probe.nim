import std/[json, os, parseutils, strformat, strutils, tables], bitworld/spriteprotocol,
  ../src/ctf/[broadcast, global, replay_runtime, replays, sim]

# Loads a recorded replay file the way the static wasm viewer does
# (initReplayRuntime + buildReplayViewerPacket) and dumps every map-band
# sprite definition and board object in the first viewer packet, so band
# coverage of the board rows can be checked directly.

let path = paramStr(1)
setCurrentDir(currentSourcePath().parentDir().parentDir())
let replayData = parseReplayBytes(readFile(path))
var initialized = initReplayRuntime(
  replayData, mismatchQuit = false, gameEventLoggingEnabled = false)
var
  game = move(initialized.sim)
  player = move(initialized.player)
  viewer = initGlobalViewerState()
  nextViewer: GlobalViewerState
let packet = game.buildReplayViewerPacket(
  player, viewer, nextViewer, newJArray())

echo &"map: {game.gameMap.width}x{game.gameMap.height}"

# Mirror the client's object table: id -> (y, spriteId) for band-range ids,
# plus every sprite def's dims. Report anything that would corrupt band
# coverage on any frame.
var
  bandObjects = initTable[int, (int, int)]()
  spriteDims = initTable[int, (int, int)]()

proc scan(packet: seq[uint8], frame: int) =
  for msg in parseSpritePacket(packet):
    case msg.kind
    of spkSprite:
      let prev = spriteDims.getOrDefault(msg.sprite.id, (-1, -1))
      spriteDims[msg.sprite.id] = (msg.sprite.width, msg.sprite.height)
      if msg.sprite.id in 30 .. 99 and frame > 0:
        echo &"frame {frame}: SPRITE REDEF id={msg.sprite.id} " &
          &"{msg.sprite.width}x{msg.sprite.height} (was {prev[0]}x{prev[1]}) " &
          &"label={msg.sprite.label}"
    of spkObject:
      if msg.objectDef.id in 40 .. 99:
        if frame > 0 and (msg.objectDef.id notin bandObjects or
            bandObjects[msg.objectDef.id] != (msg.objectDef.y, msg.objectDef.spriteId)):
          echo &"frame {frame}: OBJECT OVERWRITE id={msg.objectDef.id} " &
            &"y={msg.objectDef.y} spriteId={msg.objectDef.spriteId} z={msg.objectDef.z}"
        bandObjects[msg.objectDef.id] = (msg.objectDef.y, msg.objectDef.spriteId)
    of spkDeleteObject:
      if msg.objectId in 40 .. 99:
        echo &"frame {frame}: DELETE band object id={msg.objectId}"
        bandObjects.del(msg.objectId)
    of spkClearObjects:
      echo &"frame {frame}: CLEAR OBJECTS"
      bandObjects.clear()
    else:
      discard

scan(packet, 0)
echo &"after init: {bandObjects.len} band objects"

let frames = if paramCount() >= 2: parseInt(paramStr(2)) else: 300
for frame in 1 .. frames:
  let events = player.advanceReplayFrame(
    game, initialized.tracker, newSeq[int](), viewer.replayCommands)
  var nv: GlobalViewerState
  let p = game.buildReplayViewerPacket(player, viewer, nv, events)
  viewer = nv
  scan(p, frame)
echo &"after {frames} frames: {bandObjects.len} band objects"
