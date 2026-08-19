## softmax:player Component Model adapter for the existing baseline policy.

import baseline

{.compile: "bindings/player/player.c".}
{.emit: """
void NimMain(void);
static int arena_player_nim_initialized;
__attribute__((constructor))
static void arena_player_nim_init(void) {
  if (!arena_player_nim_initialized) {
    arena_player_nim_initialized = 1;
    NimMain();
  }
}
""".}

type
  PlayerString {.importc: "player_string_t", header: "bindings/player/player.h", bycopy.} = object
    data {.importc: "ptr".}: ptr uint8
    len: csize_t

  PlayerBytes {.importc: "player_list_u8_t", header: "bindings/player/player.h", bycopy.} = object
    data {.importc: "ptr".}: ptr uint8
    len: csize_t

  PlayerMessages {.importc: "player_list_list_u8_t", header: "bindings/player/player.h", bycopy.} = object
    data {.importc: "ptr".}: ptr PlayerBytes
    len: csize_t

proc logLine(level, message: ptr PlayerString) {.
  importc: "softmax_player_log_line", header: "bindings/player/player.h".}
proc playerStringDup(value: ptr PlayerString, text: cstring) {.
  importc: "player_string_dup", header: "bindings/player/player.h".}
proc playerStringFree(value: ptr PlayerString) {.
  importc: "player_string_free", header: "bindings/player/player.h".}

var baselineComponent: BaselineComponent
var playerInitialized = false

proc prepareError(error: ptr PlayerString, message = "CTF player call failed") =
  ## With --exceptions:goto an unwind returns false without assigning the WIT
  ## error out-param. Preallocating it makes that generated-C path safe.
  playerStringDup(error, message)

proc clearError(error: ptr PlayerString) =
  playerStringFree(error)

proc setError(error: ptr PlayerString, message: cstring) =
  clearError(error)
  playerStringDup(error, message)

proc exportsPlayerStart(
  slot: uint32,
  config: ptr PlayerString,
  error: ptr PlayerString
): bool {.exportc: "exports_player_start", cdecl.} =
  discard config
  prepareError(error)
  baselineComponent = initBaselineComponent(int(slot))
  playerInitialized = true
  var
    level = "info"
    message = "CTF baseline player initialized"
    levelValue = PlayerString(data: cast[ptr uint8](level[0].unsafeAddr), len: csize_t(level.len))
    messageValue = PlayerString(data: cast[ptr uint8](message[0].unsafeAddr), len: csize_t(message.len))
  logLine(levelValue.addr, messageValue.addr)
  clearError(error)
  true

proc exportsPlayerOnMessage(
  message: ptr PlayerBytes,
  output: ptr PlayerMessages,
  error: ptr PlayerString
): bool {.exportc: "exports_player_on_message", cdecl.} =
  prepareError(error)
  if not playerInitialized:
    setError(error, "CTF player is not initialized")
    return false
  var frame = newString(int(message[].len))
  if message[].len > 0:
    copyMem(frame[0].addr, message[].data, message[].len)
  let replies = baselineComponent.onMessage(frame)
  output[].len = csize_t(replies.len)
  output[].data = nil
  if replies.len > 0:
    output[].data = cast[ptr PlayerBytes](alloc(replies.len * sizeof(PlayerBytes)))
    let outputData = cast[ptr UncheckedArray[PlayerBytes]](output[].data)
    for i, reply in replies:
      outputData[i].len = csize_t(reply.len)
      outputData[i].data = nil
      if reply.len > 0:
        outputData[i].data = cast[ptr uint8](alloc(reply.len))
        copyMem(outputData[i].data, reply[0].unsafeAddr, reply.len)
  clearError(error)
  true
