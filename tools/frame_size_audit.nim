import std/[algorithm, json, strformat],
  ../src/ctf/[sim, global, broadcast, server], toolutil

# Reproduces the hosted first WS frame and reports whether ANY single frame
# exceeds the hosted 1 MiB WebSocket limit (a frame over 1048576 bytes makes the
# viewer close with 1009 → "produced no frame" → the replay never loads).
#
# The board packet (map sprite + sprite atlas) rides the binary channel; the
# broadcast chrome (JSON w/ the full lives-lead series on frame 1) is smuggled as
# sprite BroadcastChromeSpriteId's label. This audit measures the board packet,
# the chrome packet, and their sum so we can see the split vs the 1 MiB cap.

const WsLimit = 1048576

chdirGameDir()
var config = defaultGameConfig()
var game = initSimServer(config)
game.gameEventLoggingEnabled = false
for i in 0 ..< 16:
  discard game.addPlayer("player" & $(i + 1))
game.startGame()
var noInput = newSeq[InputState](game.players.len)
for _ in 0 ..< 30:
  game.step(noInput, noInput)

const ChunkCap = MaxWsFrameBytes  ## the server's real chunk cap, not a copy

proc report(tag: string, boardPacket: seq[uint8], chrome: string) =
  # Assemble the real outbound packet exactly as the server does (board + chrome
  # smuggled as sprite 4090's label), then chunk it the way the WS send does.
  var outPacket = boardPacket
  outPacket.addSprite(BroadcastChromeSpriteId, 1, 1, [0'u8, 0, 0, 0], chrome)
  let chunks = chunkSpritePacket(outPacket, ChunkCap)
  var maxChunk = 0
  for c in chunks:
    if c.len > maxChunk: maxChunk = c.len
  # Reassemble to prove chunking preserves every byte (no message cut).
  var rejoined: seq[uint8]
  for c in chunks: rejoined.add(c)
  echo "== ", tag, " =="
  echo &"  full packet:    {outPacket.len:>9} bytes  (label {chrome.len} chars)"
  echo &"  ws chunks:      {chunks.len:>9}  largest {maxChunk} bytes  " &
    (if maxChunk > WsLimit: "OVER 1MiB ✗" else: "ok, under cap")
  echo &"  lossless:       {(if rejoined == outPacket: \"chunks rejoin byte-identical ✓\" else: \"MISMATCH ✗\")}"

# --- Frame 1: cold start, both hearts home (map + atlas), full lead series ---
var state = initGlobalViewerState()
var next: GlobalViewerState
let firstPacket = game.buildSpriteProtocolUpdates(
  state, next, replayTick = 0, replayEnabled = true, replayMaxTick = 2432)
# Simulate a long-match lives series (change point per tick worst case).
var lead: seq[seq[int]]
for t in 0 ..< 2432:
  lead.add(@[t, 24 - (t mod 7), 21 + (t mod 4)])
let firstChrome = game.buildStateJson(newJArray(), true, 1, 2432, false, true, -1,
  -1, lead, 0)
report("FRAME 1 (map + atlas + full lead series)", firstPacket, firstChrome)

# --- Per-sprite breakdown of the board packet (largest first) ---
var sizes: seq[(int, int, string)]
var total = 0
for message in parseSpritePacket(firstPacket):
  if message.kind == spkSprite:
    let s = message.sprite
    let bytes = blobFromBytes(s.compressedPixels).len
    total += bytes
    sizes.add((bytes, s.id, s.label))
sizes.sort()
sizes.reverse()
echo "-- board sprite payload: ", total, " across ", sizes.len, " sprites --"
for i in 0 ..< min(sizes.len, 12):
  let (bytes, id, label) = sizes[i]
  echo &"  {bytes:>9}\t#{id}\t{label}"

# --- A stage-TRANSITION frame: BOTH hearts taken so BOTH full-height endzone
# strips (the widest single sprites the glow-fade ever emits) ride one frame.
# The strip is re-sent only when its stage changes, so its full pixel payload
# lands on a transition frame, not the stable frame — this is the wire worst
# case for the fade overlay and must still chunk under the 1 MiB cap.
game.flags[Red].carrier = 0
game.flags[Blue].carrier = 1
state = next
next = state
let glowPacket = game.buildSpriteProtocolUpdates(
  state, next, replayTick = 100, replayEnabled = true, replayMaxTick = 2432)
state = next
let glowChrome = game.buildStateJson(newJArray(), true, 1, 2432, false, true, -1, -1, @[], 0)
report("GLOW TRANSITION (both hearts taken, full strips in-packet)",
  glowPacket, glowChrome)

# --- A SATURATED-PAINT frame: the arena carrying the maximum permanent terrain
# stains (StainMaxCount) with NONE yet sent to this viewer, so every stain
# ships its own masked sprite plus an object placement in a single packet. This
# is the wire worst case for the paint family: a fresh viewer joining (or
# returning from POV) late in a heavily-fought match receives the whole backlog
# in one frame. Stains are emitted once and never re-sent, so the STEADY-state
# cost afterward is zero; this frame is the spike.
#
# addPaintStain ROUTES: paint landing on a rotating center diamond is stored per
# diamond (it has to turn with the stone) and baked into that diamond's sprite
# instead of becoming a standalone terrain stain. So the pool total is the sum
# of both stores — asserting on paintStains alone under-fills as soon as any
# synthetic coordinate lands on a diamond.
for i in 0 ..< StainMaxCount:
  game.addPaintStain(
    (i * 37) mod MapWidth,
    (i * 53) mod MapHeight,
    if i mod 2 == 0: teamColor(Red) else: teamColor(Blue)
  )
doAssert game.paintStains.len + game.diamondStains.len == StainMaxCount,
  "saturation case must actually fill the stain pool, got " &
    $game.paintStains.len & " terrain + " & $game.diamondStains.len &
    " diamond"
echo "  (paint split: ", game.paintStains.len, " terrain stains, ",
  game.diamondStains.len, " on rotating diamonds)"
var stainState = initGlobalViewerState()
var stainNext: GlobalViewerState
let stainPacket = game.buildSpriteProtocolUpdates(
  stainState, stainNext, replayTick = 200, replayEnabled = true,
  replayMaxTick = 2432)
let stainChrome = game.buildStateJson(
  newJArray(), true, 1, 2432, false, true, -1, -1, @[], 0)
report("PAINT SATURATION (init + " & $StainMaxCount &
  " permanent stains backlogged)", stainPacket, stainChrome)
