## Headless JSONL training transport for the published Emerg-ant variant.
import std/[json, os]

import bitworld/spriteprotocol
import ctf/[sim, training]

if paramCount() != 2:
  quit("expected game root and Coworld manifest", 2)
setCurrentDir(paramStr(1))
let manifest = parseFile(paramStr(2))
let variant = manifest["variants"][0]["game_config"]
doAssert manifest["game"]["name"].getStr() == "emerg-ant"
doAssert variant["gameMode"].getStr() == EmergAntMode
doAssert variant["num_agents"].getInt() == 32

var game: SimServer
var previous: seq[InputState]
var previousRewards: seq[int]
var line: string
while stdin.readLine(line):
  let request = parseJson(line)
  case request["kind"].getStr()
  of "reset":
    var config = defaultGameConfig()
    config.update($variant)
    config.seed = request["seed"].getInt()
    config.maxTicks = request["horizon"].getInt()
    config.maxGames = 1
    doAssert config.maxTicks > 0
    game = initSimServer(config)
    game.gameEventLoggingEnabled = false
    for seat in 0 ..< 32:
      doAssert game.addPlayer("training-" & $seat, requestedSlot=seat,
        trusted=true) == seat
    game.startGame()
    previous = newSeq[InputState](32)
    previousRewards = newSeq[int](32)
  of "step":
    doAssert game.phase == Playing
    doAssert request["actions"].len == 32
    var inputs: seq[InputState]
    for action in request["actions"]:
      let mask = action.getInt()
      doAssert mask in 0 .. 255
      inputs.add(decodeInputMask(uint8(mask)))
    let repeats = request["repeat"].getInt()
    doAssert repeats > 0
    for _ in 0 ..< repeats:
      game.step(inputs, previous)
      previous = inputs
      if game.phase == GameOver:
        break
  else:
    raise newException(ValueError, "Unknown training request")
  var observations: seq[seq[float32]]
  var rewards: seq[int]
  var alive: seq[bool]
  for seat in 0 ..< 32:
    observations.add(game.antObservation(seat))
    rewards.add(game.players[seat].reward - previousRewards[seat])
    previousRewards[seat] = game.players[seat].reward
    alive.add(game.players[seat].alive)
  stdout.writeLine($(%*{
    "observations": observations,
    "rewards": rewards,
    "totals": previousRewards,
    "alive": alive,
    "food": [game.teamForageScore(Red), game.teamForageScore(Blue)],
    "done": game.phase == GameOver,
    "elapsed": game.gameTicksElapsed()
  }))
  stdout.flushFile()
