## softmax:game Component Model adapter generated around the native runtime.

import game_runtime

{.compile: "bindings/game/game.c".}
{.emit: """
void NimMain(void);
static int arena_game_nim_initialized;
__attribute__((constructor))
static void arena_game_nim_init(void) {
  if (!arena_game_nim_initialized) {
    arena_game_nim_initialized = 1;
    NimMain();
  }
}
""".}

type
  GameString {.importc: "game_string_t", header: "bindings/game/game.h", bycopy.} = object
    data {.importc: "ptr".}: ptr uint8
    len: csize_t

  GameBytes {.importc: "game_list_u8_t", header: "bindings/game/game.h", bycopy.} = object
    data {.importc: "ptr".}: ptr uint8
    len: csize_t

  GameSeatMessage {.importc: "game_seat_message_t", header: "bindings/game/game.h", bycopy.} = object
    seat: uint32
    payload: GameBytes

  GameSeatMessages {.importc: "game_list_seat_message_t", header: "bindings/game/game.h", bycopy.} = object
    data {.importc: "ptr".}: ptr GameSeatMessage
    len: csize_t

  GameStepOutput {.importc: "game_step_output_t", header: "bindings/game/game.h", bycopy.} = object
    messages: GameSeatMessages
    done: bool

proc outputResults(body: ptr GameBytes) {.
  importc: "softmax_game_output_results", header: "bindings/game/game.h".}
proc outputReplay(chunk: ptr GameBytes) {.
  importc: "softmax_game_output_replay_append", header: "bindings/game/game.h".}
proc logLine(level, message: ptr GameString) {.
  importc: "softmax_game_log_line", header: "bindings/game/game.h".}
proc gameStringDup(value: ptr GameString, text: cstring) {.
  importc: "game_string_dup", header: "bindings/game/game.h".}
proc gameStringFree(value: ptr GameString) {.
  importc: "game_string_free", header: "bindings/game/game.h".}

var arenaGame: ArenaGame
var gameInitialized = false

proc prepareError(error: ptr GameString, message = "CTF game call failed") =
  ## With --exceptions:goto an unwind returns false without assigning the WIT
  ## error out-param. Preallocating it makes that generated-C path safe.
  gameStringDup(error, message)

proc clearError(error: ptr GameString) =
  gameStringFree(error)

proc setError(error: ptr GameString, message: cstring) =
  clearError(error)
  gameStringDup(error, message)

proc toString(data: ptr uint8, len: csize_t): string =
  result = newString(len)
  if len > 0:
    copyMem(result[0].addr, data, len)

proc emitReplay() =
  for chunk in arenaGame.takeReplayChunks():
    var bytes = GameBytes(len: csize_t(chunk.len))
    if chunk.len > 0:
      bytes.data = cast[ptr uint8](chunk[0].unsafeAddr)
    outputReplay(bytes.addr)

proc log(level, message: string) =
  var
    levelValue = GameString(data: cast[ptr uint8](level[0].unsafeAddr), len: csize_t(level.len))
    messageValue = GameString(data: cast[ptr uint8](message[0].unsafeAddr), len: csize_t(message.len))
  logLine(levelValue.addr, messageValue.addr)

proc exportsGameInit(
  config: ptr GameString,
  seats: uint32,
  seed: uint64,
  error: ptr GameString
): bool {.exportc: "exports_game_init", cdecl.} =
  prepareError(error)
  if gameInitialized:
    setError(error, "CTF game is already initialized")
    return false
  arenaGame = initArenaGame(toString(config[].data, config[].len), int(seats), seed)
  gameInitialized = true
  emitReplay()
  log("info", "CTF Arena game initialized")
  clearError(error)
  true

proc exportsGameStep(
  actions: ptr GameSeatMessages,
  output: ptr GameStepOutput,
  error: ptr GameString
): bool {.exportc: "exports_game_step", cdecl.} =
  prepareError(error)
  if not gameInitialized:
    setError(error, "CTF game is not initialized")
    return false
  var messages: seq[SeatMessage]
  let actionData = cast[ptr UncheckedArray[GameSeatMessage]](actions[].data)
  for i in 0 ..< int(actions[].len):
    messages.add(SeatMessage(
      seat: int(actionData[i].seat),
      payload: toString(actionData[i].payload.data, actionData[i].payload.len)
    ))
  let stepOutput = arenaGame.step(messages)
  output[].messages.len = csize_t(stepOutput.messages.len)
  output[].messages.data = nil
  if stepOutput.messages.len > 0:
    output[].messages.data = cast[ptr GameSeatMessage](
      alloc(stepOutput.messages.len * sizeof(GameSeatMessage))
    )
    let outputData = cast[ptr UncheckedArray[GameSeatMessage]](output[].messages.data)
    for i, message in stepOutput.messages:
      outputData[i].seat = uint32(message.seat)
      outputData[i].payload.len = csize_t(message.payload.len)
      outputData[i].payload.data = nil
      if message.payload.len > 0:
        outputData[i].payload.data = cast[ptr uint8](alloc(message.payload.len))
        copyMem(outputData[i].payload.data, message.payload[0].unsafeAddr, message.payload.len)
  output[].done = stepOutput.done
  emitReplay()
  clearError(error)
  true

proc exportsGameFinish(error: ptr GameString): bool {.
  exportc: "exports_game_finish", cdecl.} =
  prepareError(error)
  if not gameInitialized:
    setError(error, "CTF game is not initialized")
    return false
  let body = arenaGame.finish()
  gameInitialized = false
  # finish creates no replay records; every record is emitted by init/step.
  var bytes = GameBytes(len: csize_t(body.len))
  if body.len > 0:
    bytes.data = cast[ptr uint8](body[0].unsafeAddr)
  outputResults(bytes.addr)
  log("info", "CTF Arena game finished")
  clearError(error)
  true
