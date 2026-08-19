import
  helpers,
  std/[json, os, strutils, unittest],
  ctf/[replays, sim],
  "../tools/extract_events"

const
  # The event-substrate fixture: a full 16-bot match recorded against the
  # CURRENT gameplay rules (GameVersion 43, seed 907, lives 9:
  #   record_fixture.sh tests/replays/ctf.bitreplay 907 10000 '{"lives":9}')
  # The GV43 take kept all three weapon kills on the FIRST recording
  # (gun 70 / grenade 5 / spray 8, one capture, eight steals).
  # Seed 907 survives the GV42 heart rule, but the SEED ALONE DOES NOT PIN
  # THE KILL MIX: the bots are separate processes, so two recordings of one
  # seed differ, and the grenade kill in particular is rare (5 of 105 kills
  # here). The first GV42 take of this very seed came back gun+spray only.
  # Re-record until `tools/scan_event_seeds.sh 907` prints ALL THREE — it
  # reports the mix per run and leaves its recording in .scan/, which is
  # cheaper than guessing, and do NOT move the seed on the first miss.
  # — kills across ALL THREE weapons, steals and heals, ending at the time
  # limit (a scoreless draw exercises the draw verdict path too; seed 908's
  # GV40 recording lost its spray kill under the GV41 no-overtime clock, so
  # the seed moved). (The GV32 recording ran the
  # server at speed 4 as a starvation guard; under GV33 the speed-4 runs
  # came back gun-only on this machine while the plain speed-16 recording
  # on an IDLE machine carried the full weapon mix — the idle-machine rule
  # below is the guard that actually matters: the first GV35 take of that
  # era's seed came back gun-only under load.)
  # (Seed 61 held the coverage until the blast became body-aware in GV31;
  # GV31-33 sat on seed 900; the GV34 range-cap + aim-jitter re-record came
  # back grenade-less there, and the scan moved to 902. The GV36 32-rotation
  # aim re-record came back grenade-less on 902, and the scan moved to 905.
  # Restoring continuous aim in GV40 moved it again to 908.
  # Expect the seed to move again on the next rules change.)
  #
  # Two things make this fixture easy to weaken by accident, both learned the
  # hard way:
  # - GRENADE KILLS ARE SCARCE. A bot that finishes a target with a grenade is
  #   rare, so most seeds carry none (GV30 scanned 281, 282, 283, 42, 99, 123,
  #   7 without one, and shipped without the coverage). Keep a seed that has
  #   them, and expect to scan for it — tools/scan_event_seeds.sh reports the
  #   mix per seed.
  # - RECORD ON AN IDLE MACHINE. A CPU-starved speed-16 server drops its bots:
  #   the same seed gave 9771 ticks and 45/31/1 kills idle vs 4499 ticks and
  #   25/1/0 under load. Both pass every assertion here; the starved one just
  #   tests far less.
  EventsFixture = GameDir / "tests" / "replays" / "ctf.bitreplay"

suite "tier-2 event extraction (tools/extract_events)":
  test "the fixture extracts a rich, ordered, results-consistent event stream":
    let
      data = loadReplay(EventsFixture)
      extraction = extractEvents(data)
      results = parseJson(extraction.resultsJson)
      slotCount = results["names"].len

    # The walk finished (extractEvents raises ReplayError on any recorded
    # hash mismatch, so getting here also proves the fixture re-simulates
    # deterministically) and produced events.
    check extraction.ticks > 0
    check extraction.events.len > 0

    # Asking for frames is the only thing that produces them. (Piggy-backed on
    # this walk: a dedicated one costs a full re-simulation to assert a zero.)
    check extraction.frames.len == 0

    # Event ticks never go backwards.
    var lastTick = 0
    for event in extraction.events:
      check event.tick >= lastTick
      lastTick = event.tick

    # Every Kill is weapon-attributed, first-hand. Damage/Heal events carry
    # the affected player's post-event HP, and each victim's HP trace is
    # self-consistent: it steps down by exactly the damage dealt and up by
    # exactly the heal amount, resetting at each respawn.
    var
      killsBySlot = newSeq[int](slotCount)
      shotsBySlot = newSeq[int](slotCount)
      hitsBySlot = newSeq[int](slotCount)
      lastHp = newSeq[int](slotCount)  # -1 = unknown (start / just respawned)
      sawGunKill = false
      sawSprayKill = false
      sawGrenadeKill = false
      sawPlayingPhase = false
      sawGameOverPhase = false
    for slot in 0 ..< slotCount:
      lastHp[slot] = -1
    for event in extraction.events:
      case event.kind
      of Kill:
        check event.weapon in ["gun", "spray", "grenade"]
        case event.weapon
        of "gun": sawGunKill = true
        of "spray": sawSprayKill = true
        of "grenade": sawGrenadeKill = true
        else: discard
        check event.source >= 0 and event.source < slotCount
        check event.target >= 0 and event.target < slotCount
        inc killsBySlot[event.source]
      of Shot:
        check event.source >= 0 and event.source < slotCount
        inc shotsBySlot[event.source]
      of Hit:
        check event.source >= 0 and event.source < slotCount
        inc hitsBySlot[event.source]
      of Damage:
        check event.target >= 0 and event.target < slotCount
        check event.hp >= 0
        # Shield-absorbed hp is a subset of the hit: 0 <= blocked <= amount.
        check event.blocked >= 0
        check event.blocked <= event.amount
        # `hp` is BASE hp only; the shield layer soaks `blocked` of the hit, so
        # base hp steps down by the part that got through (amount - blocked).
        if lastHp[event.target] >= 0:
          check event.hp == max(0, lastHp[event.target] - (event.amount - event.blocked))
        lastHp[event.target] = event.hp
      of Heal:
        check event.source >= 0 and event.source < slotCount
        check event.hp >= 0
        check event.amount > 0
        if lastHp[event.source] >= 0:
          check event.hp == lastHp[event.source] + event.amount
        lastHp[event.source] = event.hp
      of Respawn:
        check event.source >= 0 and event.source < slotCount
        lastHp[event.source] = -1  # back at full; trace restarts.
      of PhaseChange:
        check event.weapon in ["lobby", "playing", "gameover"]
        check event.hp == -1
        if event.weapon == "playing":
          sawPlayingPhase = true
          check event.amount == ord(Playing)
        elif event.weapon == "gameover":
          sawGameOverPhase = true
          check event.amount == ord(GameOver)
        # A phase boundary resets every hp (new game / lobby): restart traces.
        for slot in 0 ..< slotCount:
          lastHp[slot] = -1
      else:
        check event.hp == -1
        # `blocked` is Damage-only; every other kind carries 0.
        check event.blocked == 0
    check sawGunKill
    check sawSprayKill
    check sawGrenadeKill
    # The fixture plays a full match: it enters Playing and ends at GameOver.
    check sawPlayingPhase
    check sawGameOverPhase

    # The event stream is the counters, itemized: per-slot Kill events sum to
    # the final results.json kills array. shotsFired/shotsHit stay OUT of
    # results.json (the platform results schema is closed and the certifier
    # rejects unknown fields) — the accuracy counters are checked against the
    # extraction directly instead.
    check results["kills"].len == slotCount
    check "shotsFired" notin results
    check "shotsHit" notin results
    for slot in 0 ..< slotCount:
      check results["kills"][slot].getInt == killsBySlot[slot]

    # The in-sim accuracy counters mirror the event stream exactly.
    for slot in 0 ..< slotCount:
      check extraction.slotShotsFired[slot] == shotsBySlot[slot]
      check extraction.slotShotsHit[slot] == hitsBySlot[slot]

  test "the JSONL emitter ends with an honest summary row":
    let
      data = loadReplay(EventsFixture)
      output = extractEventsJsonl(data)
    var
      rows: seq[JsonNode]
      lineStart = 0
    for i in 0 .. output.len:
      if i == output.len or output[i] == '\n':
        if i > lineStart:
          rows.add(parseJson(output[lineStart ..< i]))
        lineStart = i + 1
    check rows.len >= 2
    # Every event row carries the additive `blocked` field (0 unless a shield
    # soaked the hit), so downstream (the Healing tab's "blocks") can read it.
    for row in rows[0 ..< rows.high]:
      check row.hasKey("blocked")
      check row["blocked"].getInt >= 0
    let summary = rows[^1]
    check summary["type"].getStr == "summary"
    check summary["events"].getInt == rows.len - 1
    check summary["ticks"].getInt > 0
    check summary["gameVersion"].getStr == GameVersion
    # Every non-summary row carries the full event shape.
    for row in rows[0 ..< ^1]:
      for field in ["tick", "kind", "source", "target", "weapon", "amount",
          "hp", "x", "y"]:
        check row.hasKey(field)

  test "the summary names every seat and the outcome, so a scan stands alone":
    # Ladder scouting attributes every tier-2 event to a league entrant. The
    # roster travels WITH the events so a scan of the JSONL alone can do that:
    # no second read of the league API, and — the part that matters as
    # episodes grow past two teams — no inferring an entrant from its SEAT.
    let
      data = loadReplay(EventsFixture)
      extraction = extractEvents(data)
      results = parseJson(extraction.resultsJson)
      slotCount = results["names"].len

    check extraction.slotAddress.len == slotCount
    check extraction.slotTeam.len == slotCount
    var named = 0
    for slot in 0 ..< slotCount:
      # A seat the game never dealt reads "unknown" in the results snapshot and
      # stays empty here; every seat that DID play must be named.
      if results["team"][slot].getStr == "unknown":
        continue
      inc named
      check extraction.slotAddress[slot].len > 0
      # The team is whatever the sim dealt that seat — cross-checked against
      # the results snapshot, NOT against a seat-parity rule. Parity only ever
      # described a 2-team head-to-head; an episode can seat four teams.
      check extraction.slotTeam[slot] == results["team"][slot].getStr
    check named >= 2

    # A finished match names exactly one winner, or is an explicit draw.
    check extraction.finished
    if extraction.isDraw:
      check extraction.winner == ""
    else:
      check extraction.winner in extraction.slotTeam

    # And all of it survives the trip through the JSONL summary row.
    let
      output = extractEventsJsonl(data)
      lines = output.strip(chars = {'\n'}).split('\n')
      summary = parseJson(lines[^1])
    check summary["slot_address"].len == slotCount
    check summary["slot_team"].len == slotCount
    check summary["winner"].getStr == extraction.winner
    check summary["draw"].getBool == extraction.isDraw
    check summary["finished"].getBool == extraction.finished
    # The shared four keys are still there: extras never displace the contract.
    for field in ["type", "ticks", "events", "gameVersion"]:
      check summary.hasKey(field)

  test "collectEvents defaults off: a live sim collects nothing":
    let previousDir = getCurrentDir()
    setCurrentDir(GameDir)
    try:
      var game = initSimServer(defaultGameConfig())
      let
        shooter = game.addPlayer("red0")
        target = game.addPlayer("blue0")
      game.startGame()
      check game.collectEvents == false
      game.players[shooter].team = Red
      game.players[target].team = Blue
      game.players[shooter].x = game.gameMap.center.x
      game.players[shooter].y = game.gameMap.center.y
      game.players[shooter].aimBrads = 0
      game.players[shooter].windupBrads = -1
      game.players[shooter].fireCooldown = 0
      game.players[target].x = game.gameMap.center.x + 40
      game.players[target].y = game.gameMap.center.y
      game.tryFire(shooter)
      check game.players[shooter].shotsFired == 1
      check game.events.len == 0

      # The sink (and its switch) never enters the game hash.
      let hashBefore = game.gameHash()
      game.collectEvents = true
      game.events.add SimEvent(tick: 1, kind: Shot, source: 0, target: -1)
      check game.gameHash() == hashBefore
    finally:
      setCurrentDir(previousDir)

  test "--frames captures per-tick seat state that agrees with the events":
    ## The frame stream and the event stream come out of the SAME walk, so
    ## they have to agree. The sharpest cross-check is shots: a release is the
    ## tick a seat's fireWindup counts down 1 -> 0, and the engine stamps its
    ## own Shot event at the shooter's position. Rebuilding the shots from the
    ## frames alone and matching them against those events exercises the tick
    ## alignment, the seat ordering and the field packing all at once.
    let
      data = loadReplay(EventsFixture)
      extraction = extractEvents(data, captureFrames = true)

    check extraction.frameCount == extraction.ticks
    check extraction.frameSlots > 0
    check extraction.frames.len == FramesHeaderBytes +
      extraction.frameCount *
        frameRecordBytes(extraction.frameSlots, extraction.frameTeams)
    check extraction.frames[0 ..< 8] == "CTFFRM01"
    check extraction.frameTick(0) == 1
    check extraction.frameTick(extraction.frameCount - 1) == extraction.ticks

    # The header is what a downstream reader parses to find the records at
    # all, so decode it from the BYTES rather than trusting the in-memory
    # fields the accessors above already use.
    proc headerU16(offset: int): int =
      int(uint8(extraction.frames[offset])) or
        (int(uint8(extraction.frames[offset + 1])) shl 8)
    check headerU16(8) == extraction.frameSlots
    check headerU16(10) == MapWidth
    check headerU16(12) == MapHeight
    check headerU16(14) == extraction.frameTeams

    # Seats are the roster the results report, not a config guess: a seat the
    # results name but the frames omit is silent data loss.
    check extraction.frameSlots ==
      parseJson(extraction.resultsJson)["names"].len

    # One record per tick, contiguous — the accessors index frames by
    # `tick - 1`, which only holds if no tick is skipped or repeated.
    for index in 0 ..< extraction.frameCount:
      check extraction.frameTick(index) == index + 1

    var released: seq[(int, int)]
    for index in 1 ..< extraction.frameCount:
      for seat in 0 ..< extraction.frameSlots:
        if extraction.frameSeat(index - 1, seat).fireWindup == 1 and
            extraction.frameSeat(index, seat).fireWindup == 0:
          released.add((extraction.frameTick(index), seat))

    var shots: seq[(int, int)]
    for event in extraction.events:
      if event.kind == Shot:
        shots.add((event.tick, event.source))

    check released.len > 0
    check released.len == shots.len
    for pair in shots:
      check pair in released

    # And each shot leaves from where the frames say the shooter stood.
    for event in extraction.events:
      if event.kind == Shot:
        let seatState =
          extraction.frameSeat(event.tick - 1, event.source)
        check abs(float(seatState.x) - event.x) <= 1.0
        check abs(float(seatState.y) - event.y) <= 1.0

    # A flag is either home or on the back of a seat that says it is carrying.
    var carriedFrames = 0
    for index in 0 ..< extraction.frameCount:
      for team in 0 ..< extraction.frameTeams:
        let carrier = extraction.frameFlag(index, team).carrier
        if carrier < 0:
          continue
        inc carriedFrames
        check carrier < extraction.frameSlots
        check (extraction.frameSeat(index, carrier).flags and 2) != 0
    check carriedFrames > 0

  test "a flag carrier is named by seat, so a disconnect cannot shift it":
    ## `FlagState.carrier` is a PLAYER INDEX, and removePlayerAt renumbers
    ## those indices when someone leaves mid-episode — which replay playback
    ## does. Every other column in a frame record is joinOrder-keyed, so the
    ## carrier has to be converted or a reader silently follows the wrong
    ## seat for the rest of the episode.
    let previousDir = getCurrentDir()
    setCurrentDir(GameDir)
    try:
      var sim = initSimServer(defaultGameConfig())
      for i in 0 ..< 4:
        discard sim.addPlayer("bot" & $i, -1, "", true)
      check sim.players[3].joinOrder == 3

      # Seat 3 grabs a flag, then the seat-0 player disconnects. The sim
      # decrements the stored carrier index to 2 to track the array; the seat
      # it names is still 3.
      sim.flags[Blue].carrier = 3
      sim.removePlayerAt(0)
      check sim.flags[Blue].carrier == 2
      check sim.players[2].joinOrder == 3

      var frames = framesHeader(MaxPlayers, sim.config.teams)
      frames.appendFrame(sim, MaxPlayers)
      let decoded = ExtractResult(
        frames: frames, frameCount: 1,
        frameSlots: MaxPlayers, frameTeams: sim.config.teams)
      check decoded.frameFlag(0, ord(Blue)).carrier == 3
      # The vacated seat reads as never-joined, not as somebody else.
      check decoded.frameSeat(0, 0).flags == 0
    finally:
      setCurrentDir(previousDir)
