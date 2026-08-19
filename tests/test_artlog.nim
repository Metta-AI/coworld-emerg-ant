## Player artifact telemetry: events fire on state edges, samples land on
## the cadence, and the flush writes a well-formed zip through the file://
## delivery path (the same code the hosted presigned PUT wraps).

import std/[json, os, strutils, tables], zippy/ziparchives
import ../players/baseline/baseline/artlog

proc snapAt(tick: int): FrameSnap =
  FrameSnap(tick: tick, alive: true, x: 100, y: 200, hp: 3, aim: 40,
    objective: "attack", action: "navigate", targetX: 600, targetY: 300,
    engageDist: -1)

proc walk(reader: ZipArchiveReader): Table[string, string] =
  for path in reader.walkFiles:
    result[path] = reader.extractFile(path)

block artifact_round_trip:
  let dir = getTempDir() / "artlog_test"
  removeDir(dir)
  let dest = dir / "artifact.zip"
  putEnv("COWORLD_PLAYER_ARTIFACT_UPLOAD_URL", "file://" & dest)

  artInit(3, "Blue", "MidTop")

  # Frame 1: baseline state.
  artFrame(snapAt(1))
  # Frame 2 (same sample window): steal + shot.
  var f2 = snapAt(2)
  f2.iCarry = true
  f2.objective = "carry"
  f2.fired = true
  f2.engageDist = 150
  artFrame(f2)
  # Frame 20: carry ends, hp drops, still alive.
  var f3 = snapAt(20)
  f3.hp = 1
  artFrame(f3)
  # Frame 21: death.
  artFrame(FrameSnap(tick: 21, alive: false, x: 100, y: 200,
    objective: "dead", action: "dead", engageDist: -1))
  # Frame 60: respawn.
  artFrame(snapAt(60))
  artEvent(61, "shout_tx", %*{"text": "C12 25"})

  artFlush()
  doAssert fileExists(dest), "flush must write through file:// URLs"

  let reader = openZipArchive(dest)
  let files = walk(reader)
  reader.close()
  for name in ["meta.json", "events.jsonl", "ticks.jsonl", "summary.json"]:
    doAssert name in files, name & " missing from artifact"

  let meta = parseJson(files["meta.json"])
  doAssert meta["slot"].getInt == 3
  doAssert meta["team"].getStr == "Blue"
  doAssert meta["role"].getStr == "MidTop"
  # buildDefines mirrors whatever -d:buildDefines the build injected
  # (empty seq when not injected, the full parsed list when it was).
  doAssert meta["buildDefines"] == %artBuildDefines()
  when defined(buildDefines):
    doAssert artBuildDefines().len > 0,
      "-d:buildDefines was injected but parsed to an empty list"
    echo "buildDefines recorded: ", $artBuildDefines()

  var kinds: CountTable[string]
  for line in files["events.jsonl"].splitLines:
    if line.len == 0:
      continue
    let row = parseJson(line)     # every event row must parse
    kinds.inc(row["e"].getStr)
  doAssert kinds["steal"] == 1
  doAssert kinds["carry_end"] == 1
  doAssert kinds["shot"] == 1
  doAssert kinds["damage"] == 1
  doAssert kinds["death"] == 1
  doAssert kinds["respawn"] == 1
  doAssert kinds["objective"] == 2      # attack -> carry -> attack
  doAssert kinds["shout_tx"] == 1

  # Ticks 1 and 2 share a sample window: exactly one row for it, then one
  # per later frame (each lands past the cadence).
  var sampleTicks: seq[int]
  for line in files["ticks.jsonl"].splitLines:
    if line.len == 0:
      continue
    sampleTicks.add(parseJson(line)["t"].getInt)
  doAssert sampleTicks == @[1, 20, 60], $sampleTicks

  let summary = parseJson(files["summary.json"])
  doAssert summary["lastTick"].getInt == 61 or
    summary["lastTick"].getInt == 60    # explicit artEvent does not move prev
  doAssert summary["events"]["steal"].getInt == 1
  doAssert summary["objectiveTicks"]["carry"].getInt == 1
  doAssert summary["truncated"].getBool == false

  # A second flush is a no-op (one artifact per episode).
  removeFile(dest)
  artFlush()
  doAssert not fileExists(dest)

block missing_url_is_silent:
  delEnv("COWORLD_PLAYER_ARTIFACT_UPLOAD_URL")
  delEnv("CTF_ARTLOG_PATH")
  artInit(0, "Red", "Overwatch")
  artFrame(snapAt(1))
  artFlush()                             # must not raise

echo "test_artlog passed"
