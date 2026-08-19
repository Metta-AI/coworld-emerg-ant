import
  std/json,
  ctf/[broadcast, global, replay_runtime, replays, sim]

var
  runtimeLoaded = false
  replay: ReplayPlayer
  game: SimServer
  viewer: GlobalViewerState
  tracker: BroadcastTracker
  packet: seq[uint8]
  lastError: string

## --- Progress stage note ---
## wasm32 has no memory protection: when emscripten's malloc fails, a write
## through the nil pointer lands at address 0 and silently corrupts the
## module's own globals instead of trapping (that is how oversized replays
## used to die with ctf_error_len() == 0 and no diagnostic at all). The
## bundle is therefore linked with -s ABORTING_MALLOC=1 — allocation failure
## aborts the runtime loudly — and this fixed buffer, stamped BEFORE each
## risky phase, stays readable from JS after the abort (aborting kills the
## call stack, not the linear memory), so the page can still report what the
## runtime was doing when the 2 GB address space ran out.
var
  stageNote: array[192, char]
  stageNoteLen: int
  currentStage: string
  frameStage: string  ## prebuilt once per load; re-stamped every frame

proc stampStage(stage: string) =
  currentStage = stage
  stageNoteLen = min(stage.len, stageNote.len)
  if stageNoteLen > 0:
    copyMem(stageNote[0].addr, stage[0].unsafeAddr, stageNoteLen)

proc bytesFromPointer(data: ptr uint8, length: int): string =
  result = newString(length)
  if length > 0:
    copyMem(result[0].addr, data, length)

proc renderCurrent(events: JsonNode) =
  var nextViewer: GlobalViewerState
  packet = game.buildReplayViewerPacket(replay, viewer, nextViewer, events)
  viewer = nextViewer

proc ctfLoadReplay(data: ptr uint8, length: cint): cint
    {.exportc: "ctf_load_replay", cdecl.} =
  try:
    lastError = ""
    stampStage("parse replay")
    let replayData = parseReplayBytes(data.bytesFromPointer(int(length)))
    stampStage("initialize replay runtime")
    # Match the native replay server default: keep a historical replay usable
    # after the first integrity mismatch and surface the warning in the shared
    # replay chrome. `--mismatch-quit` remains a native diagnostic mode.
    var initialized = initReplayRuntime(
      replayData,
      mismatchQuit = false,
      gameEventLoggingEnabled = false
    )
    game = move(initialized.sim)
    replay = move(initialized.player)
    tracker = move(initialized.tracker)
    viewer = initGlobalViewerState()
    runtimeLoaded = true
    let mapNote =
      " (map " & $game.gameMap.width & "x" & $game.gameMap.height & ")"
    # Refuse boards whose render buffers cannot fit the 32-bit address space
    # BEFORE baking starts, so the page gets a clean diagnostic instead of an
    # OOM abort. Every supported size class passes (oversize boards emit at
    # 1x — see MaxSupersampledMapPixels); this trips only on a future class
    # bigger than colossal.
    stampStage("check viewer capacity" & mapNote)
    let predicted =
      predictedViewerRenderBytes(game.gameMap.width, game.gameMap.height)
    if predicted > WasmViewerBudgetBytes:
      raise newException(CtfError,
        "replay board is too large for the browser viewer" & mapNote &
        ": needs ~" & $(predicted shr 20) &
        " MB of render buffers, beyond the wasm32 2 GB address space")
    frameStage = "advance replay" & mapNote
    stampStage("render first frame" & mapNote)
    renderCurrent(newJArray())
    return 1
  except Exception as error:
    runtimeLoaded = false
    lastError = currentStage & ": " & error.msg & "\n" & error.getStackTrace()
    return 0

proc ctfInput(data: ptr uint8, length: cint)
    {.exportc: "ctf_input", cdecl.} =
  if runtimeLoaded:
    viewer.applyGlobalViewerMessage(data.bytesFromPointer(int(length)))

proc ctfFrame(): cint {.exportc: "ctf_frame", cdecl.} =
  if not runtimeLoaded:
    return 0
  stampStage(frameStage)
  try:
    let seekTicks =
      if viewer.replaySeekTick >= 0: @[viewer.replaySeekTick]
      else: newSeq[int]()
    let events = replay.advanceReplayFrame(
      game,
      tracker,
      seekTicks,
      viewer.replayCommands
    )
    renderCurrent(events)
    return 1
  except Exception as error:
    lastError = "advance replay: " & error.msg & "\n" & error.getStackTrace()
    return -1

proc ctfPacketPointer(): ptr uint8
    {.exportc: "ctf_packet_ptr", cdecl.} =
  if packet.len == 0:
    nil
  else:
    packet[0].addr

proc ctfPacketLength(): cint {.exportc: "ctf_packet_len", cdecl.} =
  cint(packet.len)

proc ctfMismatchTick(): cint {.exportc: "ctf_mismatch_tick", cdecl.} =
  if runtimeLoaded:
    cint(replay.hashMismatchTick)
  else:
    -1

proc ctfErrorPointer(): ptr uint8 {.exportc: "ctf_error_ptr", cdecl.} =
  if lastError.len == 0:
    nil
  else:
    cast[ptr uint8](lastError[0].addr)

proc ctfErrorLength(): cint {.exportc: "ctf_error_len", cdecl.} =
  cint(lastError.len)

proc ctfStagePointer(): ptr uint8 {.exportc: "ctf_stage_ptr", cdecl.} =
  ## The progress note (see stageNote above). Unlike ctf_error_*, this stays
  ## valid after an allocation-failure abort, so JS can report what the
  ## runtime was doing when the address space ran out.
  if stageNoteLen == 0:
    nil
  else:
    cast[ptr uint8](stageNote[0].addr)

proc ctfStageLength(): cint {.exportc: "ctf_stage_len", cdecl.} =
  cint(stageNoteLen)

when defined(emscripten):
  proc emscriptenExitWithLiveRuntime() {.
    importc: "emscripten_exit_with_live_runtime", cdecl.}

when isMainModule and defined(emscripten):
  # Nim's generated main runs every module-global destructor when it returns,
  # freeing ArenaObstacles, render caches, fonts — everything — while the wasm
  # module stays alive and JS keeps calling ctf_load_replay/ctf_frame. The
  # whole session then runs on freed globals: replay hashes get overwritten by
  # later allocations (spurious "REPLAY HASH MISMATCH — SHOWING RECORDED
  # INPUTS" + frozen-at-spawn playback) and seeks crash out of bounds.
  # Unwinding main through emscripten's live-runtime exit skips the destructor
  # epilogue entirely, so globals stay valid for the life of the page.
  emscriptenExitWithLiveRuntime()
