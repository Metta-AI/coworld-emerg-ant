## Player artifact telemetry: a tracing profiler for the baseline bot.
##
## Every episode, the bot records tick-stamped decision events (steals,
## deaths, pickups, shots, mode switches, ...) plus a downsampled state row
## every `SampleEvery` ticks, and uploads the bundle as the platform's
## per-seat player artifact (one zip per slot per episode, fetched back with
## `coworld episode-logs <ereq> --agent <slot> --artifact`). The point is
## post-hoc diagnosis over large episode sets, where stdout logs are too
## unstructured to answer "what was seat 3 doing between the steal and the
## death" without re-simulating replays.
##
## Contract (PLAYER_ARTIFACT.md): the runner injects a presigned URL as
## COWORLD_PLAYER_ARTIFACT_UPLOAD_URL (`https://` PUT on hosted runs, a
## `file://` path locally, absent = uploads disabled). One zip, <=200 MB,
## Content-Type application/zip, uploaded after the final game message and
## before container teardown. A missing or failed artifact never fails the
## episode, so NOTHING in this module may raise into the game loop: every
## entry point traps, remembers the first error, and goes quiet.
##
## Zip layout:
## - meta.json     slot / team / role / build-injected define list
## - events.jsonl  one JSON object per event, `t` = tick, `e` = kind
## - ticks.jsonl   sampled state rows (pos, hp, aim, modes, target, mask)
## - summary.json  counters + per-mode tick histograms + first error, if any

import std/[json, os, strutils, tables], zippy/ziparchives

export json                 # callers build event fields with `%*`

when not defined(artlogNoCurl):
  import curly
else:
  # Test/CI builds can drop the libcurl dependency; `file://` and
  # CTF_ARTLOG_PATH delivery keep working without it.
  type
    StubResponse = object
      code: int
      body: string
    CurlStub = object
  proc newCurlPool(n: int): CurlStub = CurlStub()
  proc close(c: CurlStub) = discard
  proc put(c: CurlStub, url: string, headers: seq[(string, string)],
      body: string, timeout: float32): StubResponse =
    raise newException(CatchableError, "curl disabled (-d:artlogNoCurl)")

const
  SampleEvery* = 12         # ticks between state rows (~0.5 s at 24 tps)
  MaxEventLines = 100_000   # safety valves: a normal 5000-tick game writes
  MaxTickLines = 20_000     # a few hundred lines of each; the caps only
                            # matter if an episode runs away
  UploadTimeout = 45.0'f32  # seconds; teardown gives a bounded window

type
  FrameSnap* = object
    ## Everything `decide` learned this frame that telemetry cares about.
    ## The log keeps the previous snap and emits events on the edges, so
    ## the bot just fills this in and calls `artFrame` once per frame.
    tick*: int
    alive*: bool
    x*, y*: int               # own position, map px
    hp*: int
    aim*: int                 # dead-reckoned aim, brads
    objective*: string        # movement-target branch, e.g. "carry"
    action*: string           # turret/act branch, e.g. "fire"
    targetX*, targetY*: int   # movement target, map px
    iCarry*, mateCarry*, ownStolen*, sawThief*, pushOut*: bool
    hasShield*, hasPlasma*, carryNade*: bool
    nadeCharge*: int
    jinked*: bool             # stuck-detector burst fired this frame
    nadeDanger*: bool
    enemiesVisible*: int      # streamed into vision this frame
    engageDist*: int          # px to the live engage target, -1 = none
    mask*: uint8              # the input mask decide returned
    fired*: bool              # a fresh A press went out this frame

  ArtLog = ref object
    active: bool
    meta: JsonNode
    events: seq[string]
    ticks: seq[string]
    counters: CountTable[string]
    objTicks: CountTable[string]   # ticks spent per objective mode
    actTicks: CountTable[string]   # ticks spent per action mode
    havePrev: bool
    prev: FrameSnap
    lastSample: int
    firstError: string
    flushed: bool

var art = ArtLog(active: false)

const buildDefines {.strdefine.} = ""
  ## Raw define string injected by the build (players/baseline/Dockerfile
  ## passes -d:buildDefines="..." with the full compile-line define set).
  ## Records what the build was TOLD to compile with — NOT proof that any
  ## code guarded by a define still exists in this tree. Behavioral
  ## verification (mechdiff.py --trigger) stays authoritative.

proc artBuildDefines*(): seq[string] =
  ## Define names parsed from the injected build string, in compile-line
  ## order, e.g. @["release", "swarm", "useMalloc"]. Empty when the build
  ## did not inject -d:buildDefines (local/test builds).
  for tok in buildDefines.splitWhitespace():
    var name = tok
    name.removePrefix("--define:")
    name.removePrefix("-d:")
    let eq = name.find('=')
    if eq >= 0:
      name.setLen(eq)
    if name.len > 0 and name notin result:
      result.add(name)

proc artError(msg: string) =
  ## First internal error wins; later ones are dropped. The error rides in
  ## summary.json AND goes to stdout once, so a broken logger is visible in
  ## the policy logs without ever touching gameplay.
  if art.firstError.len == 0:
    art.firstError = msg
    echo "artlog error (telemetry disabled): ", msg

template guarded(body: untyped) =
  if art.active and art.firstError.len == 0:
    try:
      body
    except CatchableError as e:
      artError(e.msg)

proc artInit*(slot: int, team, role: string) =
  ## Arms the log. Called once at bot startup; cheap enough to be
  ## unconditional — whether the artifact can go anywhere is decided at
  ## flush time from the environment.
  # lastSample sits one full window in the past so the very first frame
  # lands a state row (episode-start position, spawn aim).
  art = ArtLog(active: true, lastSample: -SampleEvery)
  art.meta = %*{
    "schema": 2,
    "slot": slot,
    "team": team,
    "role": role,
    "buildDefines": artBuildDefines(),
    "sampleEvery": SampleEvery,
  }

proc artEvent*(tick: int, kind: string, fields: JsonNode = nil) =
  ## Appends one event row and bumps its counter. `fields` merges into the
  ## row next to `t` and `e`.
  guarded:
    art.counters.inc(kind)
    if art.events.len >= MaxEventLines:
      return
    var row = %*{"t": tick, "e": kind}
    if fields != nil:
      for key, value in fields:
        row[key] = value
    art.events.add($row)

proc edge(now, before: bool, tick: int, rise, fall: string,
    fields: JsonNode = nil) =
  ## Emits `rise` on false->true and `fall` on true->false. Empty name =
  ## that edge is not an event.
  if now == before:
    return
  let kind = if now: rise else: fall
  if kind.len > 0:
    artEvent(tick, kind, fields)

proc sample(snap: FrameSnap) =
  if art.ticks.len >= MaxTickLines:
    return
  var row = %*{
    "t": snap.tick,
    "x": snap.x, "y": snap.y,
    "hp": snap.hp,
    "aim": snap.aim,
    "obj": snap.objective,
    "act": snap.action,
    "tx": snap.targetX, "ty": snap.targetY,
    "vis": snap.enemiesVisible,
    "mask": int(snap.mask),
  }
  if not snap.alive:
    row["dead"] = %true
  if snap.engageDist >= 0:
    row["eng"] = %snap.engageDist
  var flags: seq[string]
  if snap.iCarry: flags.add("carry")
  if snap.mateCarry: flags.add("mateCarry")
  if snap.ownStolen: flags.add("ownStolen")
  if snap.hasShield: flags.add("shield")
  if snap.hasPlasma: flags.add("plasma")
  if snap.carryNade: flags.add("nade")
  if snap.pushOut: flags.add("pushOut")
  if flags.len > 0:
    row["f"] = %flags
  art.ticks.add($row)

proc artFrame*(snap: FrameSnap) =
  ## Once per decided frame: diff against the previous frame for events,
  ## keep the mode histograms current, and append a state row on the
  ## sampling cadence.
  guarded:
    let at = %*{"x": snap.x, "y": snap.y}
    if art.havePrev:
      let p = art.prev
      edge(snap.alive, p.alive, snap.tick, "respawn", "death",
        %*{"x": p.x, "y": p.y})     # the death frame reads no self position
      edge(snap.iCarry, p.iCarry, snap.tick, "steal", "carry_end", at)
      edge(snap.mateCarry, p.mateCarry, snap.tick,
        "mate_carry", "mate_carry_end")
      edge(snap.ownStolen, p.ownStolen, snap.tick,
        "own_flag_stolen", "own_flag_returned")
      edge(snap.sawThief, p.sawThief, snap.tick, "thief_fix", "", at)
      edge(snap.pushOut, p.pushOut, snap.tick, "push_out", "")
      edge(snap.hasShield, p.hasShield, snap.tick,
        "pickup_shield", "shield_lost", at)
      edge(snap.hasPlasma, p.hasPlasma, snap.tick,
        "pickup_plasma", "plasma_spent", at)
      edge(snap.carryNade, p.carryNade, snap.tick,
        "pickup_nade", "nade_thrown", at)
      edge(snap.nadeDanger, p.nadeDanger, snap.tick, "nade_flee", "", at)
      if snap.alive and p.alive:
        if snap.hp < p.hp:
          artEvent(snap.tick, "damage",
            %*{"x": snap.x, "y": snap.y, "hp": snap.hp, "from": p.hp})
        elif snap.hp > p.hp:
          artEvent(snap.tick, "heal",
            %*{"x": snap.x, "y": snap.y, "hp": snap.hp, "from": p.hp})
        if snap.objective != p.objective:
          artEvent(snap.tick, "objective",
            %*{"x": snap.x, "y": snap.y, "obj": snap.objective,
               "was": p.objective})
    if snap.fired:
      # Only a fresh A press fires (decide already gates on firedLast).
      var shot = %*{"x": snap.x, "y": snap.y, "aim": snap.aim,
                    "act": snap.action}
      if snap.engageDist >= 0:
        shot["eng"] = %snap.engageDist
      artEvent(snap.tick, "shot", shot)
    if snap.jinked:
      artEvent(snap.tick, "stuck_jink", at)
    if snap.alive:
      art.objTicks.inc(snap.objective)
      art.actTicks.inc(snap.action)
    else:
      art.objTicks.inc("dead")
    if snap.tick - art.lastSample >= SampleEvery:
      art.lastSample = snap.tick
      sample(snap)
    art.havePrev = true
    art.prev = snap

proc countsToJson(counts: CountTable[string]): JsonNode =
  result = newJObject()
  for key, count in counts:
    result[key] = %count

proc buildZip(): string =
  var summary = %*{
    "lastTick": (if art.havePrev: art.prev.tick else: 0),
    "events": countsToJson(art.counters),
    "objectiveTicks": countsToJson(art.objTicks),
    "actionTicks": countsToJson(art.actTicks),
    "truncated": art.events.len >= MaxEventLines or
      art.ticks.len >= MaxTickLines,
  }
  if art.firstError.len > 0:
    summary["error"] = %art.firstError
  var entries: OrderedTable[string, string]
  entries["meta.json"] = pretty(art.meta)
  entries["events.jsonl"] = art.events.join("\n")
  entries["ticks.jsonl"] = art.ticks.join("\n")
  entries["summary.json"] = pretty(summary)
  createZipArchive(entries)

proc deliver(payload: string): string =
  ## Returns a human-readable destination, or "" when uploads are disabled.
  ## `file://` paths (local runs) and CTF_ARTLOG_PATH (developer override)
  ## write straight to disk; anything else is the presigned hosted PUT.
  var url = getEnv("COWORLD_PLAYER_ARTIFACT_UPLOAD_URL")
  if url.len == 0:
    url = getEnv("CTF_ARTLOG_PATH")
    if url.len == 0:
      return ""
    createDir(url.parentDir())
    writeFile(url, payload)
    return url
  if url.startsWith("file://"):
    let path = url[len("file://") .. ^1]
    createDir(path.parentDir())
    writeFile(path, payload)
    return path
  # Presigned PUT: the URL already carries authorization, so no auth header.
  let curl = newCurlPool(1)
  defer: curl.close()
  let response = curl.put(
    url, @[("Content-Type", "application/zip")], payload, UploadTimeout)
  if response.code != 200:
    raise newException(CatchableError,
      "artifact PUT failed: HTTP " & $response.code)
  "hosted artifact store"

proc artFlush*() =
  ## Builds the zip and uploads it. Called once, on the game-over exit path
  ## (the server closing the socket IS the final game message for this bot).
  ## Failures are logged and swallowed: a lost artifact never fails an
  ## otherwise successful episode.
  if not art.active or art.flushed:
    return
  art.flushed = true
  try:
    let payload = buildZip()
    let dest = deliver(payload)
    if dest.len > 0:
      echo "artifact uploaded (", payload.len, " bytes, ",
        art.events.len, " events, ", art.ticks.len, " samples) -> ", dest
    else:
      echo "artifact skipped: no upload URL"
  except CatchableError as e:
    echo "artifact upload failed (episode unaffected): ", e.msg
