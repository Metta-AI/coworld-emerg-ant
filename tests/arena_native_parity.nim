## Native side of the Arena component determinism proof.

import std/[sequtils, strutils]
import arena/game_runtime
import baseline
import ctf/[replays, sim]

const
  ParitySeed = 0xfedcba9876543210'u64
  ParityTicks = 13
  ParityConfig = """{
    "players": [{"name": "alpha"}, {"name": "beta"}],
    "minPlayers": 2,
    "maxTicks": 12,
    "maxGames": 1
  }"""

proc inputPacket(mask: uint8): string =
  result = newString(2)
  result[0] = char(0x84)
  result[1] = char(mask)

var
  game = initArenaGame(ParityConfig, 2, ParitySeed)
  replayBytes = game.takeReplayChunks().join()
  playerFrames: seq[string]
for tick in 0 ..< ParityTicks:
  let output = game.step([
    SeatMessage(seat: 0, payload: inputPacket(uint8([8, 8, 0, 16, 0, 2][tick mod 6]))),
    SeatMessage(seat: 1, payload: inputPacket(uint8([4, 4, 0, 32, 0, 1][tick mod 6])))
  ])
  doAssert output.done == (tick == ParityTicks - 1)
  playerFrames.add(output.messages[0].payload)
  replayBytes.add(game.takeReplayChunks().join())
let nativeResults = game.finish()
let replay = parseReplayBytes(replayBytes)
doAssert replay.joins.len == 2
doAssert replay.inputs.len > 0
doAssert replay.hashes.mapIt(it.hash) == game.hashes

var
  replayConfig = defaultGameConfig()
  replaySim: SimServer
  replayPlayer = initReplayPlayer(replay)
replayConfig.update(replay.configJson)
replaySim = initSimServer(replayConfig)
replayPlayer.mismatchQuit = true
while replayPlayer.hashIndex < replay.hashes.len:
  replayPlayer.stepReplay(replaySim)
doAssert not replayPlayer.hashValidationFailed

var
  player = initBaselineComponent(0)
  playerMasks: seq[int]
for frame in playerFrames:
  let replies = player.onMessage(frame)
  doAssert replies.len <= 1
  playerMasks.add(if replies.len == 0: -1 else: int(replies[0][1].uint8))

echo "HASHES=" & game.hashes.mapIt($it).join(",")
echo "PLAYER_MASKS=" & playerMasks.mapIt($it).join(",")
echo "RESULTS=" & nativeResults
