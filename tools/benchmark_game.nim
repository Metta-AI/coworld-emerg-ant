## Benchmark: wall-clock time to complete one full game in the 4-team /
## 32-bot shape (the hosted 4ffa8 variant: four teams of eight on a giant
## generated map). Starts bin/ctf-server plus 32 baseline bots as plain
## local processes (no Docker), waits for the game to finish, and reports
## startup time, game time, ticks, and ticks/second.
##
## fastMode (on by default) plus CTF_BOT_FAST_READY=1 makes the server
## advance the moment every bot has submitted input, so the game runs as
## fast as the sim + bots + websocket pipeline allows — the wall-clock
## number is a real throughput measurement, not the 24fps pacing clock.
##
## Usage: nim r tools/benchmark_game.nim [seed] [maxTicks]
##   seed     pinned game/map seed, default 1 (pin keeps runs comparable)
##   maxTicks tick cap, default 5000 (a draw at the cap still benchmarks)
## Env overrides: PORT (21400), MAPSIZE (giant), REBUILD=1 (force rebuild)

import std/[algorithm, json, monotimes, net, os, osproc, streams, strformat,
  strutils, times]

const
  GameDir = currentSourcePath().parentDir().parentDir()
  Seats = 32
  TeamCount = 4
  PolicyNames = ["redshift:v1", "bluesteel:v1", "greenhorn:v1", "goldrush:v1"]

proc envOr(name, default: string): string =
  let value = getEnv(name)
  if value.len > 0: value else: default

proc seconds(a, b: MonoTime): float =
  (b - a).inMilliseconds.float / 1000.0

proc buildBinary(outPath, source: string) =
  echo "building ", outPath, " (release)..."
  let process = startProcess(
    "nim",
    args = ["c", "-d:release", "--out:" & outPath, source],
    options = {poUsePath, poParentStreams}
  )
  let code = process.waitForExit()
  process.close()
  if code != 0:
    quit("build failed: " & source)

proc writeBenchConfig(seed, maxTicks: int, mapSize: string): string =
  ## Derives the benchmark config from the repo config: 32 seats dealt
  ## round four teams (slot mod 4), giant generated map, pot scoring,
  ## pinned seed, one game.
  let config = parseJson(readFile("config.json"))
  config["seed"] = %seed
  config["maxTicks"] = %maxTicks
  config["maxGames"] = %1
  config["teams"] = %TeamCount
  config["scoring"] = %"pot"
  config["mapPath"] = %"gen"
  config["mapSeed"] = %seed
  config["mapSize"] = %mapSize
  config["minPlayers"] = %Seats
  config["fastMode"] = %true
  if config.hasKey("slots"):
    config.delete("slots")
  var tokens = newJArray()
  for slot in 0 ..< Seats:
    tokens.add(%("0xBADA55_" & $slot))
  config["tokens"] = tokens
  var players = newJArray()
  var seatCounts: array[TeamCount, int]
  for slot in 0 ..< Seats:
    let team = slot mod TeamCount
    inc seatCounts[team]
    players.add(%*{"name": &"{PolicyNames[team]}_({seatCounts[team]})"})
  config["players"] = players
  result = getTempDir() / &"ctf-bench-cfg-{getCurrentProcessId()}.json"
  writeFile(result, $config)

proc drainToFile(arg: tuple[handle: FileHandle, path: string]) {.thread.} =
  ## Copies a child process's output pipe into a log file as it arrives.
  ## The server echoes every game event, more than a pipe buffer holds —
  ## left undrained it would fill up and deadlock the game mid-match.
  var input: File
  if not input.open(arg.handle, fmRead):
    return
  let output = open(arg.path, fmWrite)
  var line = ""
  while input.readLine(line):
    output.writeLine(line)
    output.flushFile()
  output.close()
  input.close()

proc portListening(port: int): bool =
  let socket = newSocket()
  defer: socket.close()
  try:
    socket.connect("127.0.0.1", Port(port), timeout = 250)
    true
  except CatchableError:
    false

proc tailFile(path: string, lines: int): string =
  if not fileExists(path):
    return ""
  let all = readFile(path).strip().splitLines()
  all[max(0, all.len - lines) .. ^1].join("\n")

proc main() =
  setCurrentDir(GameDir)
  let params = commandLineParams()
  let
    seed = if params.len > 0: parseInt(params[0]) else: 1
    maxTicks = if params.len > 1: parseInt(params[1]) else: 5000
    port = parseInt(envOr("PORT", "21400"))
    mapSize = envOr("MAPSIZE", "giant")
    rebuild = getEnv("REBUILD") == "1"
    serverLogPath = envOr("LOG", "/tmp/ctf-bench-server.log")
    botLogPath = envOr("BOTLOG", "/tmp/ctf-bench-bots.log")
    eventsPath = envOr("EVENTS", "/tmp/ctf-bench-events.jsonl")
    metricsPath = envOr("METRICS", "/tmp/ctf-bench-metrics.json")

  ## Build (release) — outside the timed region
  if rebuild or not fileExists("bin/ctf-server"):
    buildBinary("bin/ctf-server", "src/ctf.nim")
  if rebuild or not fileExists("players/baseline/baseline.out"):
    buildBinary("players/baseline/baseline.out", "players/baseline/baseline.nim")

  let configPath = writeBenchConfig(seed, maxTicks, mapSize)
  removeFile(eventsPath)
  removeFile(metricsPath)

  var
    serverProcess: Process = nil
    botProcesses: seq[Process]

  proc shutdown() =
    if serverProcess != nil and serverProcess.running:
      serverProcess.kill()
    for bot in botProcesses:
      if bot.running:
        bot.kill()

  try:
    ## Start the server; startup time covers map generation
    let timeStart = getMonoTime()
    putEnv("COGAME_HOST", "127.0.0.1")
    putEnv("COGAME_PORT", $port)
    putEnv("COGAME_CONFIG_URI", "file://" & configPath)
    putEnv("COGAME_EVENTS_URI", "file://" & eventsPath)
    putEnv("COGAME_METRICS_URI", "file://" & metricsPath)
    serverProcess = startProcess(
      GameDir / "bin/ctf-server",
      workingDir = GameDir,
      options = {poStdErrToStdOut}
    )
    var serverLogThread: Thread[tuple[handle: FileHandle, path: string]]
    createThread(serverLogThread, drainToFile,
      (serverProcess.outputHandle, serverLogPath))

    while not portListening(port):
      if not serverProcess.running:
        joinThread(serverLogThread)
        echo "server died during startup; log tail:"
        echo tailFile(serverLogPath, 20)
        quit(1)
      if seconds(timeStart, getMonoTime()) > 480.0:
        echo "server never listened; log tail:"
        echo tailFile(serverLogPath, 20)
        quit(1)
      sleep(200)
    let timeListen = getMonoTime()

    ## Spawn all 32 bots as plain processes; the game clock starts here
    putEnv("CTF_BOT_FAST_READY", "1")
    for slot in 0 ..< Seats:
      putEnv("COWORLD_PLAYER_WS_URL",
        &"ws://127.0.0.1:{port}/player?slot={slot}&token=0xBADA55_{slot}")
      botProcesses.add(startProcess(
        GameDir / "players/baseline/baseline.out",
        workingDir = GameDir,
        options = {poStdErrToStdOut}
      ))
    let timeBots = getMonoTime()

    ## The server exits on its own after maxGames=1; a hang must be loud
    while serverProcess.running:
      if seconds(timeBots, getMonoTime()) > 1200.0:
        echo "server still running after 20 minutes — killing; log tail:"
        echo tailFile(serverLogPath, 20)
        quit(1)
      sleep(100)
    let timeEnd = getMonoTime()
    joinThread(serverLogThread)

    ## Bot pipes stay unread during the game (their output is tiny, far
    ## under one pipe buffer); collect them into the bot log afterwards.
    let botLog = open(botLogPath, fmWrite)
    for bot in botProcesses:
      if bot.running:
        bot.kill()
      botLog.write(bot.outputStream.readAll())
    botLog.close()

    var ticks, events = -1
    if fileExists(eventsPath):
      for line in readFile(eventsPath).strip().splitLines():
        let row = parseJson(line)
        if row{"type"}.getStr() == "summary":
          ticks = row["ticks"].getInt()
          events = row["events"].getInt()

    let gameSeconds = seconds(timeBots, timeEnd)
    echo ""
    echo &"benchmark: {TeamCount} teams x {Seats div TeamCount} bots " &
      &"({Seats} seats), map=gen/{mapSize}, seed={seed}"
    echo &"  server startup (map gen):  {seconds(timeStart, timeListen):8.2f} s"
    echo &"  game (bots spawn -> over): {gameSeconds:8.2f} s"
    echo &"  total:                     {seconds(timeStart, timeEnd):8.2f} s"
    if ticks >= 0:
      echo &"  ticks: {ticks}   events: {events}   " &
        &"ticks/sec: {ticks.float / gameSeconds:.1f}"
    else:
      echo "  (no events summary found — tick stats unavailable)"

    ## Server-side performance metrics: frame pacing + per-player traffic
    if fileExists(metricsPath):
      let metrics = parseJson(readFile(metricsPath))
      let frames = metrics["frames"]
      let framesTotal = max(1, frames["total"].getInt())
      echo &"""  frame pacing: skipped {frames["skipped"].getInt()} """ &
        &"""({frames["skipped"].getInt().float * 100.0 / framesTotal.float:.1f}%), """ &
        &"""waited {frames["waited"].getInt()}, late {frames["late"].getInt()} """ &
        &"of {frames[\"total\"].getInt()} playing frames"
      var totalBytes, imageBytes, objectBytes: int64
      var playerCount = 0
      for player in metrics["players"]:
        if player["bytesTotal"].getBiggestInt() > 0:
          inc playerCount
        totalBytes += player["bytesTotal"].getBiggestInt()
        imageBytes += player["bytesImage"].getBiggestInt()
        objectBytes += player["bytesObject"].getBiggestInt()
      if totalBytes > 0 and playerCount > 0:
        echo &"  traffic: {totalBytes.float / 1e6:.1f} MB to " &
          &"{playerCount} players " &
          &"(avg {totalBytes.float / playerCount.float / 1e6:.2f} MB/player) — " &
          &"images {imageBytes.float * 100.0 / totalBytes.float:.1f}%, " &
          &"objects {objectBytes.float * 100.0 / totalBytes.float:.1f}%"
      if metrics.hasKey("objectPools"):
        var pools: seq[(int64, string)]
        for name, bytes in metrics["objectPools"]:
          pools.add((bytes.getBiggestInt(), name))
        pools.sort(Descending)
        var top = ""
        for i in 0 ..< min(6, pools.len):
          if i > 0:
            top.add(", ")
          top.add(&"{pools[i][1]} {pools[i][0].float / 1e6:.1f}")
        echo &"  top object pools (MB): {top}"
      echo &"  per-player detail: {metricsPath}"
    else:
      echo "  (no metrics file found — server predates COGAME_METRICS_URI?)"
  finally:
    shutdown()
    removeFile(configPath)

main()
