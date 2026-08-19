import std/[json, os], ../src/ctf/[replay_runtime, replays, sim]

# Dumps the recorded config + generated map dimensions of .bitreplay files and
# verifies they initialize natively. Triage tool for the wasm-viewer
# "over- or underflow" crash: correlates failing replays with map scale.

for i in 1 .. paramCount():
  let path = paramStr(i)
  let data = parseReplayBytes(readFile(path))
  let cfg = parseJson(data.configJson)
  var initialized = initReplayRuntime(
    data, mismatchQuit = false, gameEventLoggingEnabled = false)
  echo path.extractFilename(), ": map=", initialized.sim.gameMap.width, "x",
    initialized.sim.gameMap.height,
    " trenches=", initialized.sim.gameMap.trenches.len,
    " seed=", cfg{"seed"}.getInt(-1),
    " mapSeed=", cfg{"mapSeed"}.getInt(-1),
    " teams=", cfg{"teams"}.getInt(2),
    " maxTicks=", cfg{"maxTicks"}.getInt(-1),
    " ticks=", initialized.player.replayMaxTick()
