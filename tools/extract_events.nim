## Re-simulates one .bitreplay with the tier-2 event sink enabled
## (sim.collectEvents) and prints the drained SimEvent stream as JSON lines —
## one object per event, in tick order — followed by a final summary object.
## Replay hashes are still validated every step (mismatchQuit), so a clean run
## also proves the recording re-simulates deterministically.
##
## `--frames <path>` additionally captures the per-tick, per-seat STATE the
## same walk passes through: positions, aim, health and carry flags. Events say
## what happened and where; frames say where everyone was in between, which is
## what spatial analysis needs and what no other output carries. It rides the
## existing re-simulation, so it costs no extra walk.
##
## frames layout, little-endian:
##   header: "CTFFRM01" | u16 slots | u16 mapW | u16 mapH | u16 teams
##   then one fixed-width record per simulated tick:
##     u32 tick | u8 phase | u8 pad
##     slots x { i16 x, i16 y, u8 aim, u8 hp, u8 lives, u8 flags, u8 fw, u8 wb }
##     teams x { i16 x, i16 y, i8 carrier }
##   flags bits: 1 alive, 2 carryingFlag, 4 hasShield, 8 hasGrenade,
##               16 hasPlasmaArc, 32 shieldHp>0, 64 spray cone active
##   fw = fireWindup; wb = windupBrads, meaningful only where fw > 0 (a full
##   0..255 brad value, so there is no free sentinel for "not armed").
## Seats are written by joinOrder, so column `s` is the same seat for the whole
## episode even though players join during the lobby. `carrier` is a SEAT in
## that same space (-1 when the flag is home), not a sim player index.
##
## Usage: nim r tools/extract_events.nim [replay-path] [--out <path>]
##                                       [--frames <path>]

import
  std/[json, os, strutils],
  ../src/ctf/events,
  ../src/ctf/sim,
  toolutil

# `key`/`jsonRow` moved to `ctf/events` so the live server and this tool share
# one serializer. Re-exported so every existing caller of this module keeps
# compiling: a move should not make callers chase the symbol.
export events

type
  ExtractEventsError = object of CatchableError

const
  UsageText =
    "Usage: nim r tools/extract_events.nim [replay-path] [--out <path>] " &
      "[--frames <path>]"
  FramesMagic = "CTFFRM01"
  SeatRecordBytes = 10
  DefaultReplayPath = GameDir / "tests" / "replays" / "ctf.bitreplay"

proc fail(message: string) =
  ## Raises one extraction failure.
  raise newException(ExtractEventsError, message)

proc parseArgs(): tuple[replayPath, outPath, framesPath: string] {.used.} =
  ## Returns the replay path and the --out / --frames paths.
  result.outPath = ""
  result.framesPath = ""
  var
    paths: seq[string]
    params = commandLineParams()
    i = 0
  while i < params.len:
    let arg = params[i]
    if arg == "--":
      discard
    elif arg in ["--help", "-h"]:
      echo UsageText
      quit(0)
    elif arg in ["--out", "--frames"]:
      if i + 1 >= params.len:
        fail(arg & " requires a path.\n" & UsageText)
      let flag = arg
      inc i
      if flag == "--out":
        result.outPath = params[i].absolutePath()
      else:
        result.framesPath = params[i].absolutePath()
    elif arg.startsWith("--"):
      fail("Unknown option: " & arg & "\n" & UsageText)
    else:
      paths.add(arg)
    inc i
  if paths.len > 1:
    fail("Expected at most one replay path.\n" & UsageText)
  result.replayPath =
    if paths.len == 0: DefaultReplayPath else: paths[0].absolutePath()

type
  ExtractResult* = object
    ## One replay's full tier-2 extraction plus the final tier-1 snapshot,
    ## from a single hash-validated re-simulation walk.
    events*: seq[SimEvent]     ## every drained event, in emission order.
    ticks*: int                ## final simulated tick.
    resultsJson*: string       ## playerResultsJson at the final tick.
    slotShotsFired*: seq[int]  ## final in-sim accuracy counters by slot.
    slotShotsHit*: seq[int]
    slotAddress*: seq[string]  ## each slot's recorded join name. A hosted
                               ## league replay records the league player name
                               ## here, so attribution never has to ASSUME a
                               ## slot-to-entrant mapping. Read this, never a
                               ## seat-parity rule: parity only ever described
                               ## a 2-team head-to-head, and an episode can
                               ## seat four policies across four teams.
    slotTeam*: seq[string]     ## each slot's team, from the sim's own
                               ## assignment ("red"/"blue"/"green"/"yellow").
    winner*: string            ## the winning team's color, or "" when the
                               ## match drew or never finished.
    isDraw*: bool
    finished*: bool            ## whether the replay reached GameOver.
    frames*: string            ## per-tick seat state; empty unless requested.
    frameCount*: int           ## records in `frames`.
    frameSlots*: int           ## seats per frame record.
    frameTeams*: int           ## flags per frame record.

  FrameSeat* = object
    ## One seat's state on one tick, decoded from an ExtractResult's frames.
    x*, y*: int
    aimBrads*, hp*, lives*, flags*: int
    fireWindup*: int
    windupBrads*: int          ## meaningful only where fireWindup > 0.

  FrameFlag* = object
    ## One team's flag on one tick, decoded from an ExtractResult's frames.
    x*, y*: int
    carrier*: int              ## SEAT carrying it, -1 when home.

const FramesHeaderBytes* = 16   ## magic + slots + width + height + teams.

proc frameRecordBytes*(slotCount, teamCount: int): int =
  ## Bytes per per-tick record: tick + phase + pad, then seats, then flags.
  6 + slotCount * SeatRecordBytes + teamCount * 5

proc addLe(buffer: var string, value: uint8) =
  buffer.add(char(value))

proc addLe(buffer: var string, value: uint16) =
  buffer.add(char(value and 0xff'u16))
  buffer.add(char((value shr 8) and 0xff'u16))

proc addLe(buffer: var string, value: uint32) =
  for shift in [0, 8, 16, 24]:
    buffer.add(char((value shr shift) and 0xff'u32))

proc addI16(buffer: var string, value: int) =
  buffer.addLe(cast[uint16](int16(clamp(value, int(low(int16)), int(high(int16))))))

proc addByte(buffer: var string, value: int) =
  buffer.addLe(uint8(clamp(value, 0, 255)))

proc framesHeader*(slotCount, teamCount: int): string =
  ## The frame stream's fixed 16-byte preamble. One definition, so the writer
  ## and anything decoding it cannot drift.
  result = FramesMagic
  result.addLe(uint16(slotCount))
  result.addLe(uint16(MapWidth))
  result.addLe(uint16(MapHeight))
  result.addLe(uint16(teamCount))

proc seatOfPlayer(sim: SimServer, playerIndex, slotCount: int): int =
  ## The joinOrder seat of one sim player index, or -1 for "none". Player
  ## INDICES shift when someone leaves (removePlayerAt renumbers the array and
  ## every index stored in it); seats do not. Anything index-shaped that
  ## reaches the frame stream has to come through here.
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return -1
  let seat = sim.players[playerIndex].joinOrder
  if seat < 0 or seat >= slotCount: -1 else: seat

proc appendFrame*(buffer: var string, sim: SimServer, slotCount: int) =
  ## Appends one fixed-width per-tick record. Seats are written by joinOrder,
  ## not by array index: players join during the lobby, so `sim.players` grows
  ## mid-episode and an index-ordered dump would shift columns under the
  ## reader. A seat that has not joined yet writes a zeroed record.
  buffer.addLe(uint32(sim.tickCount))
  buffer.addByte(ord(sim.phase))
  buffer.addLe(0'u8)
  var seatOf = newSeq[int](slotCount)
  for seat in 0 ..< slotCount:
    seatOf[seat] = -1
  for index, player in sim.players:
    if player.joinOrder < 0 or player.joinOrder >= slotCount:
      # Dropping a live seat would be silent data loss in the one output that
      # exists to be read by a machine: refuse the extraction instead.
      fail("player " & $index & " has joinOrder " & $player.joinOrder &
        ", outside the " & $slotCount & " seats this frame stream sizes for.")
    seatOf[player.joinOrder] = index
  for seat in 0 ..< slotCount:
    if seatOf[seat] < 0:
      for _ in 0 ..< SeatRecordBytes:
        buffer.addLe(0'u8)
      continue
    let player = sim.players[seatOf[seat]]
    var flags = 0'u8
    if player.alive: flags = flags or 1
    if player.carryingFlag: flags = flags or 2
    if player.hasShield: flags = flags or 4
    if player.hasGrenade: flags = flags or 8
    if player.hasPlasmaArc: flags = flags or 16
    if player.shieldHp > 0: flags = flags or 32
    if player.arcTicksLeft > 0: flags = flags or 64
    buffer.addI16(player.x)
    buffer.addI16(player.y)
    buffer.addByte(player.aimBrads)
    buffer.addByte(player.hp)
    buffer.addByte(player.lives)
    buffer.addLe(flags)
    buffer.addByte(player.fireWindup)
    # windupBrads spans the full 0..255 brad range, so "not armed" has no
    # spare value to claim; fireWindup > 0 is what makes it meaningful.
    buffer.addByte(if player.windupBrads < 0: 0 else: player.windupBrads)
  for team in activeTeams(sim.config.teams):
    let flag = sim.flags[team]
    buffer.addI16(flag.x)
    buffer.addI16(flag.y)
    buffer.addLe(cast[uint8](int8(sim.seatOfPlayer(flag.carrier, slotCount))))

proc u8At(frames: string, offset: int): int =
  int(uint8(frames[offset]))

proc u16At(frames: string, offset: int): int =
  frames.u8At(offset) or (frames.u8At(offset + 1) shl 8)

proc i16At(frames: string, offset: int): int =
  int(cast[int16](uint16(frames.u16At(offset))))

proc frameOffset(extraction: ExtractResult, index: int): int =
  FramesHeaderBytes +
    index * frameRecordBytes(extraction.frameSlots, extraction.frameTeams)

proc frameTick*(extraction: ExtractResult, index: int): int =
  ## The sim tick of frame `index`.
  let base = extraction.frameOffset(index)
  extraction.frames.u16At(base) or (extraction.frames.u16At(base + 2) shl 16)

proc framePhase*(extraction: ExtractResult, index: int): int =
  extraction.frames.u8At(extraction.frameOffset(index) + 4)

proc frameFlag*(extraction: ExtractResult, index, team: int): FrameFlag =
  ## One team's flag on frame `index`. `carrier` is a SEAT (joinOrder), the
  ## same space the seat columns use, or -1 when the flag is home.
  let base = extraction.frameOffset(index) + 6 +
    extraction.frameSlots * SeatRecordBytes + team * 5
  FrameFlag(
    x: extraction.frames.i16At(base),
    y: extraction.frames.i16At(base + 2),
    carrier: int(cast[int8](uint8(extraction.frames.u8At(base + 4))))
  )

proc frameSeat*(extraction: ExtractResult, index, seat: int): FrameSeat =
  ## One seat's state on frame `index`. Seats are in joinOrder.
  let base = extraction.frameOffset(index) + 6 + seat * SeatRecordBytes
  FrameSeat(
    x: extraction.frames.i16At(base),
    y: extraction.frames.i16At(base + 2),
    aimBrads: extraction.frames.u8At(base + 4),
    hp: extraction.frames.u8At(base + 5),
    lives: extraction.frames.u8At(base + 6),
    flags: extraction.frames.u8At(base + 7),
    fireWindup: extraction.frames.u8At(base + 8),
    windupBrads: extraction.frames.u8At(base + 9)
  )

proc extractEvents*(data: ReplayData, captureFrames = false): ExtractResult =
  ## Re-simulates one replay with the tier-2 sink on and returns every event
  ## in emission order. Raises ReplayError on any recorded-hash mismatch.
  ## With `captureFrames`, the same walk also records per-tick seat state.
  let previousDir = getCurrentDir()
  chdirGameDir()
  try:
    var (sim, replay) = openReplay(data)
    sim.collectEvents = true
    # Seats join during the lobby, so the roster size comes from the config
    # rather than from the (initially empty) player list: the configured
    # slots (the players[] list extends them) name every seat a recorded
    # game deals, keeping the frame width the actual roster rather than the
    # MaxPlayers capacity bound. An unconfigured open roster has no such
    # list and falls back to capacity. Under-sizing stays loud either way:
    # appendFrame refuses any seat outside the width instead of dropping it.
    var slotCount = sim.config.slots.len
    if slotCount == 0:
      slotCount = sim.config.playerSlotLimit()
    result.frameSlots = slotCount
    result.frameTeams = sim.config.teams
    if captureFrames:
      result.frames.add(framesHeader(slotCount, sim.config.teams))
    while replay.playing:
      replay.stepReplay(sim)
      # Drain the sink every tick so it never grows past one tick's worth.
      for event in sim.events:
        result.events.add(event)
      sim.events.setLen(0)
      if captureFrames:
        result.frames.appendFrame(sim, slotCount)
        inc result.frameCount
      result.ticks = sim.tickCount
    result.resultsJson = sim.playerResultsJson()
    let resultSlotCount = parseJson(result.resultsJson)["names"].len
    result.slotShotsFired = newSeq[int](resultSlotCount)
    result.slotShotsHit = newSeq[int](resultSlotCount)
    result.slotAddress = newSeq[string](resultSlotCount)
    result.slotTeam = newSeq[string](resultSlotCount)
    for player in sim.players:
      if player.joinOrder >= 0 and player.joinOrder < resultSlotCount:
        result.slotShotsFired[player.joinOrder] = player.shotsFired
        result.slotShotsHit[player.joinOrder] = player.shotsHit
        # Both come from the SIM, not from the seat index: the recorded join
        # name is the league entrant, and the team is whatever the config
        # actually dealt that seat (2-team alternation is one layout of
        # several, not a rule to infer from).
        result.slotAddress[player.joinOrder] = player.address
        result.slotTeam[player.joinOrder] = teamText(player.team)
    result.finished = sim.phase == GameOver
    result.isDraw = sim.isDraw
    if result.finished and not sim.isDraw:
      result.winner = teamText(sim.winner)
  finally:
    setCurrentDir(previousDir)

proc extractEventsJsonl*(
    data: ReplayData, framesOut: var string, captureFrames = false
): string =
  ## Returns the full JSON-lines extraction: one row per event plus a final
  ## summary object. Captured frames, if any, come back through `framesOut`.
  ##
  ## The summary carries the ROSTER and the OUTCOME on top of the shared four
  ## keys, so a scan of the JSONL alone can attribute every event to a league
  ## entrant and say who won — without re-reading the league API and without
  ## inferring an entrant from its seat index.
  let extraction = extractEvents(data, captureFrames)
  framesOut = extraction.frames
  var roster = newJObject()
  roster["finished"] = %extraction.finished
  roster["draw"] = %extraction.isDraw
  roster["winner"] = %extraction.winner
  roster["slot_address"] = %extraction.slotAddress
  roster["slot_team"] = %extraction.slotTeam
  roster["slot_shots_fired"] = %extraction.slotShotsFired
  roster["slot_shots_hit"] = %extraction.slotShotsHit
  extraction.events.eventsJsonl(extraction.ticks, roster)

proc extractEventsJsonl*(data: ReplayData): string =
  ## Event-stream-only overload: the shape every existing caller uses.
  var discarded: string
  extractEventsJsonl(data, discarded)

proc runExtract(replayPath, outPath, framesPath: string) {.used.} =
  ## Extracts one replay's event stream to stdout or --out, and its per-tick
  ## seat state to --frames when asked.
  if not fileExists(replayPath):
    fail("Replay file does not exist: " & replayPath)
  var frames: string
  let output =
    extractEventsJsonl(loadReplay(replayPath), frames, framesPath.len > 0)
  if outPath.len > 0:
    writeFile(outPath, output)
  else:
    stdout.write(output)
  if framesPath.len > 0:
    writeFile(framesPath, frames)

when isMainModule:
  try:
    let (replayPath, outPath, framesPath) = parseArgs()
    runExtract(replayPath, outPath, framesPath)
  except ExtractEventsError as e:
    stderr.writeLine("extract_events failed: " & e.msg)
    quit(1)
  except ReplayError as e:
    stderr.writeLine("extract_events replay error: " & e.msg)
    quit(1)
  except CtfError as e:
    stderr.writeLine("extract_events sim error: " & e.msg)
    quit(1)
