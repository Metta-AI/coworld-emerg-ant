import
  std/[json, os, strutils],
  ../src/ctf/sim,
  toolutil

type
  ExpandReplayError = object of CatchableError

  ReplayEventKind* = enum
    PlayerJoined
    PhaseChanged
    Shot
    Hit
    Kill
    FlagSteal
    FlagReturnHome
    Capture
    Respawn
    ScoreChanged
    GameOver

  ReplayEvent* = object
    tick*: int
    kind*: ReplayEventKind
    actorSlot*: int
    actorLabel*: string
    secondarySlot*: int
    secondaryLabel*: string
    phase*: GamePhase
    scoreAmount*: int
    flagTeam*: Team
    winner*: Team
    isDraw*: bool

  ReplayTimeline* = object
    events*: seq[ReplayEvent]
    tickCount*: int
    hashFailed*: bool
    failTick*: int

const
  UsageText = "Usage: nim r tools/expand_replay.nim [replay-path]"
  DefaultReplayPath = GameDir / "tests" / "replays" / "ctf.bitreplay"

proc fail(message: string) =
  ## Raises one replay expansion failure.
  raise newException(ExpandReplayError, message)

proc replayPathFromArgs(): string {.used.} =
  ## Returns the replay path passed on the command line.
  var paths: seq[string]
  for arg in commandLineParams():
    if arg == "--":
      discard
    elif arg in ["--help", "-h"]:
      echo UsageText
      quit(0)
    elif arg.startsWith("--"):
      fail("Unknown option: " & arg & "\n" & UsageText)
    else:
      paths.add(arg)
  if paths.len > 1:
    fail("Expected at most one replay path.\n" & UsageText)
  if paths.len == 0:
    return DefaultReplayPath
  paths[0].absolutePath()

proc player(sim: SimServer, i: int): string =
  ## Returns team, color, and username for one player.
  let p = sim.players[i]
  teamText(p.team) & " " & playerColorText(p.color) & "(" & p.address & ")"

proc playerSlot(sim: SimServer, i: int): int =
  ## Returns one player's stable join slot.
  if i >= 0 and i < sim.players.len:
    return sim.players[i].joinOrder
  -1

proc addPlayerEvent(
  events: var seq[ReplayEvent],
  tick: int,
  kind: ReplayEventKind,
  sim: SimServer,
  playerIndex: int
) =
  ## Adds one single-player replay event.
  events.add ReplayEvent(
    tick: tick,
    kind: kind,
    actorSlot: sim.playerSlot(playerIndex),
    actorLabel: sim.player(playerIndex),
    secondarySlot: -1,
    phase: sim.phase
  )

type
  TrackState = object
    alive: seq[bool]
    kills: seq[int]
    deaths: seq[int]
    captures: seq[int]
    rewards: seq[int]
    shotsFired: seq[int]
    shotsHit: seq[int]

proc syncPlayers(
  sim: SimServer,
  tick: int,
  events: var seq[ReplayEvent],
  track: var TrackState
) =
  ## Adds tracking state and join events for newly joined players.
  while track.alive.len < sim.players.len:
    let i = track.alive.len
    track.alive.add(sim.players[i].alive)
    track.kills.add(sim.players[i].kills)
    track.deaths.add(sim.players[i].deaths)
    track.captures.add(sim.players[i].captures)
    track.rewards.add(sim.players[i].reward)
    track.shotsFired.add(sim.players[i].shotsFired)
    track.shotsHit.add(sim.players[i].shotsHit)
    events.addPlayerEvent(tick, PlayerJoined, sim, i)

proc killerThisTick(sim: SimServer, track: TrackState): int =
  ## Returns the single player whose kill count just went up this tick, or -1
  ## when none or SEVERAL did — fidelity rule F7, matching broadcast's
  ## killerThisStep: when two players score on the same tick the sim cannot
  ## say who killed whom, so the timeline never guesses an attribution.
  result = -1
  var killerCount = 0
  for i, player in sim.players:
    if i < track.kills.len and player.kills > track.kills[i]:
      inc killerCount
      result = i
  if killerCount > 1:
    result = -1

proc printKillsAndDeaths(
  sim: SimServer,
  tick: int,
  events: var seq[ReplayEvent],
  track: var TrackState
) =
  ## Adds kill/respawn events by diffing per-player death and alive counters.
  let killer = sim.killerThisTick(track)
  for i, p in sim.players:
    if p.deaths > track.deaths[i]:
      events.add ReplayEvent(
        tick: tick,
        kind: Kill,
        actorSlot: if killer >= 0: sim.playerSlot(killer) else: -1,
        actorLabel: if killer >= 0: sim.player(killer) else: "unknown",
        secondarySlot: sim.playerSlot(i),
        secondaryLabel: sim.player(i),
        phase: sim.phase
      )
    elif p.alive and not track.alive[i]:
      events.addPlayerEvent(tick, Respawn, sim, i)
    track.alive[i] = p.alive
    track.kills[i] = p.kills
    track.deaths[i] = p.deaths

proc printShots(
  sim: SimServer,
  tick: int,
  events: var seq[ReplayEvent],
  track: var TrackState
) =
  ## Adds shot/hit events by diffing per-player shot counters. A player
  ## releases at most one shot per tick (fire cooldown), so each counter rises
  ## by at most one; a Hit is a shot that locked onto a live enemy on its ray.
  for i, p in sim.players:
    if p.shotsFired > track.shotsFired[i]:
      events.addPlayerEvent(tick, Shot, sim, i)
    if p.shotsHit > track.shotsHit[i]:
      events.addPlayerEvent(tick, Hit, sim, i)
    track.shotsFired[i] = p.shotsFired
    track.shotsHit[i] = p.shotsHit

proc printCaptures(
  sim: SimServer,
  tick: int,
  events: var seq[ReplayEvent],
  track: var TrackState,
  prevCarriers: array[Team, int],
  prevCaptured: array[Team, bool]
) =
  ## Adds capture events by diffing per-player capture counters. The
  ## captured flag is whichever one just flipped to captured out of this
  ## capturer's hands (GV32 retires the heart at the capture spot) — with
  ## 4 teams "the enemy flag" is not unique. prevCarriers/prevCaptured are
  ## the flags as they stood before this tick's changes.
  for i, p in sim.players:
    if p.captures > track.captures[i]:
      var capturedTeam = p.team
      var found = false
      for team in sim.teams():
        if sim.flags[team].captured and not prevCaptured[team] and
            prevCarriers[team] == i:
          capturedTeam = team
          found = true
      # A miss would silently report the player capturing their OWN flag —
      # wrong-but-plausible forensics data is worse than a crash.
      doAssert found, "capture event with no captured flag"
      events.add ReplayEvent(
        tick: tick,
        kind: Capture,
        actorSlot: sim.playerSlot(i),
        actorLabel: sim.player(i),
        secondarySlot: -1,
        flagTeam: capturedTeam,
        phase: sim.phase
      )
    track.captures[i] = p.captures

proc printScoreChanges(
  sim: SimServer,
  tick: int,
  events: var seq[ReplayEvent],
  track: var TrackState
) =
  ## Adds score change events since the previous tick.
  for i, p in sim.players:
    if p.reward != track.rewards[i]:
      events.add ReplayEvent(
        tick: tick,
        kind: ScoreChanged,
        actorSlot: sim.playerSlot(i),
        actorLabel: sim.player(i),
        secondarySlot: -1,
        scoreAmount: p.reward - track.rewards[i],
        phase: sim.phase
      )
      track.rewards[i] = p.reward

proc printFlagChanges(
  sim: SimServer,
  tick: int,
  events: var seq[ReplayEvent],
  prevCarriers: var array[Team, int],
  prevCaptured: var array[Team, bool]
) =
  ## Adds per-team flag steal and return-home events by diffing each flag's
  ## carrier. A carrier losing a flag for any reason other than capture sends
  ## it straight back to its pedestal; a heart retired by a capture (GV32)
  ## is not a return — the capture event is that story.
  for team in sim.teams():
    prevCaptured[team] = sim.flags[team].captured
    let carrier = sim.flags[team].carrier
    if carrier == prevCarriers[team]:
      continue
    if prevCarriers[team] >= 0 and not sim.flags[team].captured:
      events.add ReplayEvent(
        tick: tick,
        kind: FlagReturnHome,
        actorSlot: -1,
        actorLabel: "",
        secondarySlot: -1,
        flagTeam: team,
        phase: sim.phase
      )
    if carrier >= 0:
      events.add ReplayEvent(
        tick: tick,
        kind: FlagSteal,
        actorSlot: sim.playerSlot(carrier),
        actorLabel: sim.player(carrier),
        secondarySlot: -1,
        flagTeam: team,
        phase: sim.phase
      )
    prevCarriers[team] = carrier

proc scoreAmountText(amount: int): string =
  ## Returns a readable signed score amount.
  if amount > 0:
    "+" & $amount
  else:
    $amount

proc key*(event: ReplayEvent): string =
  ## Returns the event-log key for one replay event.
  case event.kind
  of PlayerJoined:
    "player_joined"
  of PhaseChanged:
    "phase"
  of Shot:
    "shot"
  of Hit:
    "hit"
  of Kill:
    "kill"
  of FlagSteal:
    "flag_steal"
  of FlagReturnHome:
    "flag_return_home"
  of Capture:
    "capture"
  of Respawn:
    "respawn"
  of ScoreChanged:
    "score"
  of GameOver:
    "game_over"

proc text*(event: ReplayEvent): string =
  ## Renders one replay event as a human-readable CLI line.
  case event.kind
  of PlayerJoined:
    "  player " & event.actorLabel & " joined"
  of PhaseChanged:
    "  phase " & $event.phase
  of Shot:
    "  player " & event.actorLabel & " fired"
  of Hit:
    "  player " & event.actorLabel & " landed a shot"
  of Kill:
    "  player " & event.actorLabel & " killed " & event.secondaryLabel
  of FlagSteal:
    "  player " & event.actorLabel & " stole the " &
      teamText(event.flagTeam) & " flag"
  of FlagReturnHome:
    "  " & teamText(event.flagTeam) & " flag returned home"
  of Capture:
    "  player " & event.actorLabel & " captured the " &
      teamText(event.flagTeam) & " flag"
  of Respawn:
    "  player " & event.actorLabel & " respawned"
  of ScoreChanged:
    "  score player " & event.actorLabel & " " & scoreAmountText(event.scoreAmount)
  of GameOver:
    if event.isDraw:
      "  game over: draw"
    else:
      "  game over: " & teamText(event.winner) & " wins"

proc jsonRow*(event: ReplayEvent): JsonNode =
  ## Returns one event-log JSON row for a replay event.
  var value = newJObject()
  case event.kind
  of PlayerJoined:
    value["label"] = %event.actorLabel
  of PhaseChanged:
    value["phase"] = %($event.phase)
  of Kill:
    value["victim_slot"] = %event.secondarySlot
    value["victim_label"] = %event.secondaryLabel
  of FlagSteal, Capture:
    value["label"] = %event.actorLabel
    value["flag"] = %teamText(event.flagTeam)
  of Shot, Hit, Respawn:
    value["label"] = %event.actorLabel
  of FlagReturnHome:
    value["flag"] = %teamText(event.flagTeam)
  of ScoreChanged:
    value["amount"] = %event.scoreAmount
  of GameOver:
    value["draw"] = %event.isDraw
    if not event.isDraw:
      value["winner"] = %teamText(event.winner)

  result = newJObject()
  result["ts"] = %event.tick
  result["player"] = %event.actorSlot
  result["key"] = %event.key()
  result["value"] = value

proc eventsAt(timeline: ReplayTimeline, tick: int): seq[ReplayEvent] =
  ## Returns timeline events for one tick in their recorded order.
  for event in timeline.events:
    if event.tick == tick:
      result.add(event)

proc expandReplayTimeline*(data: ReplayData): ReplayTimeline =
  ## Expands one replay into a structured CTF event timeline.
  let previousDir = getCurrentDir()
  chdirGameDir()
  try:
    var
      (sim, replay) = openReplay(data)
      track: TrackState
      phase = sim.phase
      prevCarriers: array[Team, int]
      prevCaptured: array[Team, bool]
    for team in Team:
      prevCarriers[team] = sim.flags[team].carrier
      prevCaptured[team] = sim.flags[team].captured

    while replay.playing:
      let tick = sim.tickCount + 1
      result.tickCount = tick
      try:
        replay.stepReplay(sim)
      except ReplayError:
        result.hashFailed = true
        result.failTick = tick
        return

      if phase != sim.phase:
        result.events.add ReplayEvent(
          tick: tick,
          kind: PhaseChanged,
          actorSlot: -1,
          secondarySlot: -1,
          phase: sim.phase
        )
        if sim.phase == GameOver:
          result.events.add ReplayEvent(
            tick: tick,
            kind: GameOver,
            actorSlot: -1,
            secondarySlot: -1,
            phase: sim.phase,
            winner: sim.winner,
            isDraw: sim.isDraw
          )
        phase = sim.phase

      sim.syncPlayers(tick, result.events, track)
      sim.printShots(tick, result.events, track)
      sim.printKillsAndDeaths(tick, result.events, track)
      # Flag changes run first (steal/return before capture, matching
      # broadcast's beat order); captures diff against the carriers as they
      # stood BEFORE this tick's flag changes, so the retired heart still
      # names its last carrier.
      let
        carriersBefore = prevCarriers
        capturedBefore = prevCaptured
      sim.printFlagChanges(tick, result.events, prevCarriers, prevCaptured)
      sim.printCaptures(tick, result.events, track, carriersBefore, capturedBefore)
      sim.printScoreChanges(tick, result.events, track)
  finally:
    setCurrentDir(previousDir)

proc expandReplay(path: string) {.used.} =
  ## Prints one readable replay timeline.
  if not fileExists(path):
    fail("Replay file does not exist: " & path)

  let data = loadReplay(path)
  let timeline = expandReplayTimeline(data)

  echo "replay ", path
  for tick in 1 .. timeline.tickCount:
    let events = timeline.eventsAt(tick)
    if events.len == 0:
      continue
    echo "tick ", tick
    for event in events:
      echo event.text()
    if timeline.hashFailed and tick == timeline.failTick:
      echo "  hash failed"
      fail("hash failed")
  echo "done"

when isMainModule:
  try:
    expandReplay(replayPathFromArgs())
  except ExpandReplayError as e:
    if e.msg != "hash failed":
      stderr.writeLine("expand_replay failed: " & e.msg)
    quit(1)
  except ReplayError as e:
    stderr.writeLine("expand_replay replay error: " & e.msg)
    quit(1)
  except CtfError as e:
    stderr.writeLine("expand_replay sim error: " & e.msg)
    quit(1)
