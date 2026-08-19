import
  helpers,
  std/[os, posix, strutils, tables, unittest],
  bitworld/spriteprotocol,
  ctf/[global, sim]

proc captureStderr(run: proc() {.closure.}): string =
  ## Runs one config parse and returns exactly what it writes to stderr.
  let path = getTempDir() / ("ctf-skin-stderr-" & $getCurrentProcessId())
  var output = open(path, fmWrite)
  flushFile(stderr)
  let savedStderr = dup(cint(getFileHandle(stderr)))
  doAssert savedStderr >= 0
  doAssert dup2(cint(getFileHandle(output)), cint(getFileHandle(stderr))) >= 0
  try:
    run()
    flushFile(stderr)
  finally:
    discard dup2(savedStderr, cint(getFileHandle(stderr)))
    discard posix.close(savedStderr)
    output.close()
  result = readFile(path)
  removeFile(path)

proc parseConfig(json: string): GameConfig =
  result = defaultGameConfig()
  result.update(json)

proc firstPlayerPacket(config: GameConfig): seq[uint8] =
  var sim = initCtfForTest(config)
  let playerIndex = sim.addPlayer("player")
  sim.startGame()
  var state, nextState: PlayerViewerState
  let previousDir = getCurrentDir()
  setCurrentDir(GameDir)
  try:
    result = sim.buildSpriteProtocolPlayerUpdates(
      playerIndex,
      state,
      nextState
    )
  finally:
    setCurrentDir(previousDir)

proc firstGlobalPacket(config: GameConfig): seq[uint8] =
  var sim = initCtfForTest(config)
  discard sim.addPlayer("player")
  sim.startGame()
  var state = initGlobalViewerState()
  var nextState: GlobalViewerState
  let previousDir = getCurrentDir()
  setCurrentDir(GameDir)
  try:
    result = sim.buildSpriteProtocolUpdates(state, nextState)
  finally:
    setCurrentDir(previousDir)

proc referencedRigHead(packet: seq[uint8]): tuple[
  id: int,
  pixels: seq[uint8]
] =
  ## Returns the rig-head sprite definition referenced by the live player object.
  let messages = packet.parseSpritePacket()
  var definitions: Table[int, SpritePacketSpriteDef]
  for message in messages:
    if message.kind == spkSprite:
      definitions[message.sprite.id] = message.sprite
  for message in messages:
    if message.kind != spkObject:
      continue
    let spriteId = message.objectDef.spriteId
    if spriteId in definitions and definitions[spriteId].label == "player red":
      return (
        id: spriteId,
        pixels: definitions[spriteId].compressedPixels
      )
  raise newException(ValueError, "global packet has no referenced red rig head")

suite "agent skins":
  test "missing and explicit default skins parse silently":
    var missing, explicitDefault: GameConfig
    let warnings = captureStderr(proc() =
      missing = parseConfig("""{"slots":[{}]}""")
      explicitDefault = parseConfig(
        """{"slots":[{"skin":"default"}]}"""
      )
    )
    check warnings == ""
    check missing.slots[0].skin == DefaultSkin
    check explicitDefault.slots[0].skin == DefaultSkin

  test "crown skin parses and is assigned when its slot joins":
    let config = parseConfig("""{"slots":[{"skin":"crown"}]}""")
    check config.slots[0].skin == CrownSkin
    var sim = initCtfForTest(config)
    let playerIndex = sim.addPlayer("crowned")
    check sim.players[playerIndex].skin == CrownSkin

  test "unknown string falls back with one useful warning":
    var config: GameConfig
    let warnings = captureStderr(proc() =
      config = parseConfig("""{"slots":[{},{"skin":"crwon"}]}""")
    )
    check config.slots[1].skin == DefaultSkin
    check warnings.strip().splitLines().len == 1
    check "slots[1].skin" in warnings
    check "\"crwon\"" in warnings

  test "non-string skin falls back instead of raising":
    var config: GameConfig
    let warnings = captureStderr(proc() =
      config = parseConfig("""{"slots":[{"skin":17}]}""")
    )
    check config.slots[0].skin == DefaultSkin
    check warnings.strip().splitLines().len == 1
    check "slots[0].skin" in warnings
    check "17" in warnings

  test "the repository config parses without skin warnings":
    var config: GameConfig
    let warnings = captureStderr(proc() =
      config = parseConfig(readFile(GameDir / "config.json"))
    )
    check warnings == ""
    check config.slots.len > 0
    for slot in config.slots:
      check slot.skin == DefaultSkin

  test "non-default skins round-trip through replay config JSON":
    let original = parseConfig(
      """{"slots":[{"skin":"crown"},{"skin":"default"},{}]}"""
    )
    let encoded = original.configJson()
    check encoded.contains("\"skin\":\"crown\"")
    check not encoded.contains("\"skin\":\"default\"")
    let restored = parseConfig(encoded)
    check restored.slots[0].skin == CrownSkin
    check restored.slots[1].skin == DefaultSkin
    check restored.slots[2].skin == DefaultSkin

  test "skin is excluded from the deterministic game hash":
    var defaultSim = initCtfForTest(defaultGameConfig())
    var crownSim = initCtfForTest(defaultGameConfig())
    discard defaultSim.addPlayer("player")
    discard crownSim.addPlayer("player")
    crownSim.players[0].skin = CrownSkin
    check defaultSim.gameHash() == crownSim.gameHash()

  test "omitted and explicit default skins emit identical init packets":
    let
      missing = parseConfig("""{"slots":[{}]}""")
      explicitDefault = parseConfig(
        """{"slots":[{"skin":"default"}]}"""
      )
    check missing.firstPlayerPacket() == explicitDefault.firstPlayerPacket()
    check missing.firstGlobalPacket() == explicitDefault.firstGlobalPacket()

  test "crown skin changes the rig head referenced by the global viewer":
    let
      defaultHead = parseConfig("""{"slots":[{}]}""")
        .firstGlobalPacket().referencedRigHead()
      crownHead = parseConfig("""{"slots":[{"skin":"crown"}]}""")
        .firstGlobalPacket().referencedRigHead()
    check crownHead.id != defaultHead.id
    check crownHead.pixels != defaultHead.pixels
