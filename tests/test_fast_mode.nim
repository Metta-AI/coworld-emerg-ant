import
  std/json,
  ctf/server, ctf/sim

proc testReadyPacketPredicate() =
  ## Tests the one-byte Sprite v1 player-ready packet detector.
  var ready = newString(1)
  ready[0] = char(0x85)
  doAssert ready.isPlayerReadyPacket()
  doAssert not "".isPlayerReadyPacket()
  doAssert not (ready & ready).isPlayerReadyPacket()
  var input = newString(1)
  input[0] = char(0x84)
  doAssert not input.isPlayerReadyPacket()

proc testFastModeDefault() =
  ## Tests that fastMode defaults on and survives the config echo.
  let config = defaultGameConfig()
  doAssert config.fastMode
  doAssert parseJson(config.configJson())["fastMode"].getBool()

proc testFastModeConfigRead() =
  ## Tests that the config reader honors an explicit fastMode.
  var config = defaultGameConfig()
  config.update("""{"fastMode": false}""")
  doAssert not config.fastMode
  doAssert not parseJson(config.configJson())["fastMode"].getBool()
  config.update("""{"fastMode": true}""")
  doAssert config.fastMode

echo "Testing fast mode"
testReadyPacketPredicate()
testFastModeDefault()
testFastModeConfigRead()
echo "ok"
