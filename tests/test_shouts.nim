import
  helpers,
  std/[algorithm, os, sequtils, strutils, tables, unittest],
  bitworld/spriteprotocol,
  ctf/[global, labels, sim]

proc openGround(sim: var SimServer) =
  ## All-open floor with both players apart and at rest, so held movement
  ## input produces real, deterministic displacement.
  for i in 0 ..< sim.walkMask.len:
    sim.walkMask[i] = true
  for (index, x, y) in [(0, 100, 100), (1, 400, 300)]:
    sim.players[index].x = x
    sim.players[index].y = y
    sim.players[index].velX = 0
    sim.players[index].velY = 0
    sim.players[index].carryX = 0
    sim.players[index].carryY = 0

proc shoutLabels(sim: var SimServer, viewerIndex: int): seq[string] =
  ## Every shout-bubble label one viewer receives: a seat index for the player
  ## stream a bot reads, -1 for the board/broadcast stream. Built from the game
  ## directory so data/ art resolves, like initCtfForTest.
  let previousDir = getCurrentDir()
  setCurrentDir(GameDir)
  var packet: seq[uint8]
  try:
    if viewerIndex >= 0:
      var
        state: PlayerViewerState
        nextState: PlayerViewerState
      packet = sim.buildSpriteProtocolPlayerUpdates(
        viewerIndex, state, nextState)
    else:
      var
        state = initGlobalViewerState()
        nextState: GlobalViewerState
      packet = sim.buildSpriteProtocolUpdates(state, nextState)
  finally:
    setCurrentDir(previousDir)
  for message in packet.parseSpritePacket():
    if message.kind == spkSprite and " shout " in message.sprite.label:
      result.add message.sprite.label

proc sansShoutTick(player: Player, matching: Player): Player =
  ## The player with lastShoutTick copied over, so everything else can be
  ## compared for exact equality.
  result = player
  result.lastShoutTick = matching.lastShoutTick

suite "shouts":
  test "a shout is stored with player, team, and shout-time coordinates":
    var sim = twoTeamGame()
    check sim.applyShout(0, "push mid")
    check sim.recentShouts.len == 1
    let shout = sim.recentShouts[0]
    check shout.address == "red0"
    check shout.team == Red
    check shout.text == "push mid"
    check shout.tick == sim.tickCount
    check shout.x == sim.players[0].x + CollisionW div 2
    check shout.y == sim.players[0].y + CollisionH div 2

  test "shouts are truncated to the limit and sanitized":
    var sim = twoTeamGame()
    check sim.applyShout(0, "0123456789ABCDEF")
    check sim.recentShouts[0].text == "0123456789"
    check sim.recentShouts[0].text.len == ShoutMaxChars
    # Control characters are dropped; whitespace-only shouts are ignored.
    sim.players[1].lastShoutTick = -1
    check not sim.applyShout(1, "\x01\x02   \n")

  test "dead players cannot shout":
    var sim = twoTeamGame()
    sim.players[0].alive = false
    check not sim.applyShout(0, "ghost")
    check sim.recentShouts.len == 0

  test "shouting is rate limited and replaces the previous bubble":
    var sim = twoTeamGame()
    check sim.applyShout(0, "first")
    check not sim.applyShout(0, "too soon")
    check sim.recentShouts.len == 1
    check sim.recentShouts[0].text == "first"
    # After the cooldown a new shout replaces the old bubble.
    let none = newSeq[InputState](sim.players.len)
    for _ in 0 ..< ShoutCooldownTicks:
      sim.step(none, none)
    check sim.applyShout(0, "second")
    check sim.recentShouts.len == 1
    check sim.recentShouts[0].text == "second"

  test "shouts expire after their display window":
    var sim = twoTeamGame()
    check sim.applyShout(0, "brief")
    let none = newSeq[InputState](sim.players.len)
    for _ in 0 ..< ShoutTicks:
      sim.step(none, none)
    check sim.recentShouts.len == 0

  test "shouts are audible within range, through walls, but not to the dead":
    var sim = twoTeamGame()
    check sim.applyShout(0, "here")
    let shout = sim.recentShouts[0]
    # The shouter hears its own shout.
    check sim.shoutAudibleTo(0, shout)
    # A viewer just inside the radius hears it; just outside does not.
    sim.players[1].x = shout.x + ShoutRange - 1 - CollisionW div 2
    sim.players[1].y = shout.y - CollisionH div 2
    check sim.shoutAudibleTo(1, shout)
    sim.players[1].x = shout.x + ShoutRange + 1 - CollisionW div 2
    check not sim.shoutAudibleTo(1, shout)
    # Dead viewers observe nothing.
    sim.players[1].x = shout.x - CollisionW div 2
    sim.players[1].alive = false
    check not sim.shoutAudibleTo(1, shout)

  test "shouting is parallel: it never blocks or alters same-tick movement and fire":
    # Two identical worlds, identical held inputs (move right + trigger
    # pull); one of them also shouts. Talking is free: it must never
    # consume, delay, or modify any other same-tick action.
    var
      talker = twoTeamGame()
      silent = twoTeamGame()
    talker.openGround()
    silent.openGround()

    # applyShout on its own changes nothing in the player state except
    # lastShoutTick.
    let before = talker.players[0]
    check talker.applyShout(0, "on my mark")
    check talker.recentShouts.len == 1
    check talker.recentShouts[0].text == "on my mark"
    check talker.players[0].lastShoutTick == talker.tickCount
    check talker.players[0].sansShoutTick(before) == before

    # With the shout in flight, movement and fire advance in lockstep with
    # the silent world: every tick, the full player state matches exactly
    # (lastShoutTick aside).
    var inputs = newSeq[InputState](talker.players.len)
    inputs[0] = InputState(right: true, attack: true)
    var prev = newSeq[InputState](talker.players.len)
    let startX = talker.players[0].x
    for _ in 0 ..< 10:
      talker.step(inputs, prev)
      silent.step(inputs, prev)
      prev = inputs
      check talker.players[0].sansShoutTick(silent.players[0]) ==
        silent.players[0]
    check talker.players[0].x > startX      # the shouter really moved

    # A second shout inside the cooldown is rejected — and the rejection,
    # too, leaves movement and fire untouched.
    check not talker.applyShout(0, "too soon")
    check talker.recentShouts.len == 1
    check talker.recentShouts[0].text == "on my mark"
    for _ in 0 ..< 5:
      talker.step(inputs, prev)
      silent.step(inputs, prev)
      check talker.players[0].sansShoutTick(silent.players[0]) ==
        silent.players[0]

  test "shouts are part of the game hash":
    var sim1 = twoTeamGame()
    var sim2 = twoTeamGame()
    check sim1.gameHash == sim2.gameHash
    sim1.applyShout(0, "flank left")
    check sim1.gameHash != sim2.gameHash
    sim2.applyShout(0, "flank left")
    check sim1.gameHash == sim2.gameHash

suite "shout labels name a slot letter, never the shouter's address":
  # A bubble's label is read off the wire by EVERY listener in earshot, so
  # whatever it names the shouter is public to the other side. It used to name
  # the connection address — for a league bot, the policy's own name — so a team
  # talking to itself ("red shout daveey: H2") handed rivals a free roster and
  # told them exactly whose build they were playing. These tests pin the
  # anonymous per-team slot letter in BOTH streams.

  proc standOn(sim: var SimServer, viewer, target: int) =
    ## Puts `viewer` on top of `target`, well inside ShoutRange.
    sim.players[viewer].x = sim.players[target].x
    sim.players[viewer].y = sim.players[target].y

  test "a player view labels a heard shout with the shouter's slot letter":
    var sim = namedGame(2)
    check sim.applyShout(0, "H2")
    sim.standOn(viewer = 1, target = 0)
    let heard = sim.shoutLabels(viewerIndex = 1)
    check heard == @[labelShout("red", "alpha", "H2")]
    check not heard.anyIt("policy" in it)

  test "the board view labels shouts the same way":
    # The broadcast stream is anonymized too: one label shape everywhere, and a
    # human watching still reads the address off the `name` label over the
    # shouter's head.
    var sim = namedGame(2)
    check sim.applyShout(0, "H2")
    let shown = sim.shoutLabels(viewerIndex = -1)
    check shown == @[labelShout("red", "alpha", "H2")]
    check not shown.anyIt("policy" in it)

  test "slot letters rank within the team, not across the roster":
    # Seat 2 is Red's SECOND seat, so it is beta even though it is the third
    # player to join. Getting this from the roster index instead would make two
    # teammates share a letter and the enemy's letters mirror our own.
    var sim = namedGame(4)
    # A shout is heard at the coordinates it was MADE at, so gather the seats
    # before either of them talks.
    sim.standOn(viewer = 3, target = 2)
    sim.standOn(viewer = 0, target = 2)
    check sim.applyShout(2, "H2")        # red beta
    check sim.applyShout(3, "H3")        # blue beta
    check sim.shoutLabels(viewerIndex = 0).sorted == @[
      labelShout("blue", "beta", "H3"),
      labelShout("red", "beta", "H2"),
    ]

  test "a departed shouter's bubble falls back to the unknown slot name":
    # A bubble outlives its author: it displays for ShoutTicks and the shouter
    # can disconnect inside that window, which drops its player row and with it
    # the only route from address to slot. The bubble is observable state, so it
    # stays — under a name that still leaks nothing.
    var sim = namedGame(2)
    check sim.applyShout(0, "H2")
    sim.standOn(viewer = 1, target = 0)
    sim.removePlayerAt(0)
    check sim.players.len == 1
    check sim.recentShouts.len == 1
    let heard = sim.shoutLabels(viewerIndex = 0)
    check heard == @[labelShout("red", IdentityNameUnknown, "H2")]
    check not heard.anyIt("policy" in it)

suite "shout bubbles keep their wire ids while other shouts churn":
  # The replay client tracks board objects by id across frames, so a bubble
  # whose object id changes mid-life reads as a teleport, and an id that jumps
  # to a DIFFERENT shout reads as the text flashing. recentShouts reshuffles on
  # every re-shout (remove mid-array + append) and every expiry (front
  # compaction), so ids keyed on the array index — the old scheme — swapped
  # almost every second of a talkative match. These tests pin the fix: a
  # bubble's (object id, sprite id) pair is claimed when it first draws and
  # holds until its shout dies, whatever the rest of the roster says.

  proc boardShoutIds(
    sim: var SimServer,
    state: var GlobalViewerState,
    spriteLabels: var Table[int, string]
  ): Table[string, (int, int)] =
    ## text → (objectId, spriteId) for every shout bubble the board stream
    ## places this frame. Carries the viewer state between calls — slot
    ## persistence across frames is the thing under test — and accumulates
    ## sprite labels because an unchanged sprite def is not re-sent.
    let previousDir = getCurrentDir()
    setCurrentDir(GameDir)
    var packet: seq[uint8]
    try:
      var nextState: GlobalViewerState
      packet = sim.buildSpriteProtocolUpdates(state, nextState)
      state = nextState
    finally:
      setCurrentDir(previousDir)
    var objects: seq[SpritePacketObject]
    for message in packet.parseSpritePacket():
      case message.kind
      of spkSprite:
        spriteLabels[message.sprite.id] = message.sprite.label
      of spkObject:
        objects.add message.objectDef
      else:
        discard
    for obj in objects:
      let label = spriteLabels.getOrDefault(obj.spriteId, "")
      if " shout " in label:
        result[label.split(": ", 1)[1]] = (obj.id, obj.spriteId)

  proc playOn(
    sim: var SimServer,
    state: var GlobalViewerState,
    spriteLabels: var Table[int, string],
    ticks: int
  ): Table[string, (int, int)] =
    ## Advances `ticks` ticks at 1x playback — one drawn board frame per sim
    ## tick, like the live broadcast — and returns the last frame's bubbles.
    ## Wall-clock dwell (ShoutDwellFrames) never exceeds real time at 1x, so
    ## these tests observe the same expiry/swap timing the sim dictates.
    let none = newSeq[InputState](sim.players.len)
    for _ in 0 ..< ticks:
      sim.step(none, none)
      result = sim.boardShoutIds(state, spriteLabels)

  test "a re-shout and an expiry never move another player's bubble":
    var
      sim = namedGame(2)
      state = initGlobalViewerState()
      spriteLabels = initTable[int, string]()

    # Frame 1: player 0's bubble claims its ids.
    check sim.applyShout(0, "one")
    let first = sim.boardShoutIds(state, spriteLabels)
    check first.len == 1
    let idsA = first["one"]

    # One cooldown later: player 1 joins the conversation. The new bubble gets
    # its own ids; player 0's do not move.
    discard sim.playOn(state, spriteLabels, ShoutCooldownTicks)
    check sim.applyShout(1, "two")
    let second = sim.boardShoutIds(state, spriteLabels)
    check second.len == 2
    check second["one"] == idsA
    let idsB = second["two"]
    check idsB != idsA

    # Player 0 re-shouts, which REPLACES its recentShouts entry (remove
    # mid-array + append at the end). Under index-keyed ids that reordering
    # swapped both bubbles' identities; slot-keyed, each stays put.
    discard sim.playOn(state, spriteLabels, ShoutCooldownTicks)
    check sim.applyShout(0, "three")
    let third = sim.boardShoutIds(state, spriteLabels)
    check third.len == 2
    check third["three"] == idsA
    check third["two"] == idsB

    # Player 1 refreshes its bubble too, so its shout now outlives player 0's.
    discard sim.playOn(state, spriteLabels, ShoutCooldownTicks)
    check sim.applyShout(1, "four")
    let fourth = sim.boardShoutIds(state, spriteLabels)
    check fourth.len == 2
    check fourth["three"] == idsA
    check fourth["four"] == idsB

    # Player 0's shout expires, compacting recentShouts. ("three" was made one
    # cooldown before "four", so this lands after "three" dies and before
    # "four" does.) Under index-keyed ids the surviving bubble slid into the
    # dead one's identity; slot-keyed, it keeps its own.
    let fifth = sim.playOn(
      state, spriteLabels, ShoutTicks - ShoutCooldownTicks)
    check sim.recentShouts.len == 1
    check fifth.len == 1
    check fifth["four"] == idsB

  test "a freed slot is reusable by the next new shout":
    var
      sim = namedGame(2)
      state = initGlobalViewerState()
      spriteLabels = initTable[int, string]()
    check sim.applyShout(0, "one")
    let first = sim.boardShoutIds(state, spriteLabels)
    check sim.playOn(state, spriteLabels, ShoutTicks).len == 0
    check sim.recentShouts.len == 0
    check sim.applyShout(1, "two")
    let next = sim.boardShoutIds(state, spriteLabels)
    check next["two"] == first["one"]

suite "board bubbles hold a wall-clock read time under compressed playback":
  # Replay playback compresses sim time: speed multiplies ticks-per-frame and
  # the default skip-lulls boost multiplies it again (up to MaxLullTicksPerFrame
  # ticks per rendered frame). A shout's ShoutTicks lifetime is SIM time, so on
  # the board a bubble could draw for one or two frames — a flash of random
  # text near a bot — and a chatty policy (one comms shout per cooldown) turned
  # its bubble into a strobe. These tests pin the render-side dwell floor: on
  # the BOARD stream every text a bubble shows stays up for at least
  # ShoutDwellFrames rendered frames of advancing playback, however many sim
  # ticks each frame swallows. Player streams are bot observations and keep
  # exact sim timing.
  #
  # "Wall-clock" is design language, not an implementation: the dwell is a
  # COUNT of advancing rendered frames against sim.tickCount, and neither the
  # sim nor the board builder ever reads the system clock — so this suite is
  # fully deterministic and cannot be timing-flaky under CPU load.

  proc boardShoutTexts(
    sim: var SimServer,
    state: var GlobalViewerState,
    spriteLabels: var Table[int, string]
  ): seq[string] =
    ## The shout payloads on the board this frame, via the same client
    ## semantics as boardShoutIds.
    let previousDir = getCurrentDir()
    setCurrentDir(GameDir)
    var packet: seq[uint8]
    try:
      var nextState: GlobalViewerState
      packet = sim.buildSpriteProtocolUpdates(state, nextState)
      state = nextState
    finally:
      setCurrentDir(previousDir)
    var objects: seq[SpritePacketObject]
    for message in packet.parseSpritePacket():
      case message.kind
      of spkSprite:
        spriteLabels[message.sprite.id] = message.sprite.label
      of spkObject:
        objects.add message.objectDef
      else:
        discard
    for obj in objects:
      let label = spriteLabels.getOrDefault(obj.spriteId, "")
      if " shout " in label:
        result.add label.split(": ", 1)[1]

  test "a bubble expired between frames lingers for the dwell, then leaves":
    var
      sim = namedGame(2)
      state = initGlobalViewerState()
      spriteLabels = initTable[int, string]()
    let none = newSeq[InputState](sim.players.len)
    check sim.applyShout(0, "one")
    check sim.boardShoutTexts(state, spriteLabels) == @["one"]   # frame 1
    # Fast-forward past the shout's whole sim lifetime WITHOUT drawing — the
    # compressed-playback case. The sim forgets the shout...
    for _ in 0 ..< ShoutTicks + 1:
      sim.step(none, none)
    check sim.recentShouts.len == 0
    # ...but the board keeps the bubble until it has been READABLE: frames
    # 2..ShoutDwellFrames still show it (each frame advances the sim a tick,
    # like playback), and the frame after that is clean.
    for frame in 2 .. ShoutDwellFrames:
      sim.step(none, none)
      check sim.boardShoutTexts(state, spriteLabels) == @["one"]
    sim.step(none, none)
    check sim.boardShoutTexts(state, spriteLabels).len == 0

  test "paused playback neither ages nor drops a lingering bubble":
    var
      sim = namedGame(2)
      state = initGlobalViewerState()
      spriteLabels = initTable[int, string]()
    let none = newSeq[InputState](sim.players.len)
    check sim.applyShout(0, "one")
    discard sim.boardShoutTexts(state, spriteLabels)
    for _ in 0 ..< ShoutTicks + 1:
      sim.step(none, none)
    check sim.recentShouts.len == 0
    # Many frames at the SAME tick — a paused viewer. The dwell clock counts
    # only advancing frames, so the bubble must survive all of them.
    for _ in 0 ..< ShoutDwellFrames * 2:
      check sim.boardShoutTexts(state, spriteLabels) == @["one"]

  test "rapid re-shouts collapse to one readable text per dwell":
    var
      sim = namedGame(2)
      state = initGlobalViewerState()
      spriteLabels = initTable[int, string]()
    let none = newSeq[InputState](sim.players.len)
    # A comms-bus policy: a fresh payload every cooldown, at a playback so
    # fast each rendered frame swallows a whole cooldown. Unfloored, the
    # bubble text would change EVERY frame.
    var texts: seq[string]
    check sim.applyShout(0, "t0")
    for frame in 0 ..< ShoutDwellFrames + 1:
      let shown = sim.boardShoutTexts(state, spriteLabels)
      check shown.len == 1
      texts.add shown[0]
      for _ in 0 ..< ShoutCooldownTicks:
        sim.step(none, none)
      check sim.applyShout(0, "t" & $(frame + 1))
    # The first payload held for the full dwell...
    for frame in 0 ..< ShoutDwellFrames:
      check texts[frame] == "t0"
    # ...and the swap jumped to the CURRENT payload, not the next queued one.
    check texts[ShoutDwellFrames] == "t" & $ShoutDwellFrames

  test "player streams keep exact sim timing (no linger for bots)":
    var sim = namedGame(2)
    let none = newSeq[InputState](sim.players.len)
    sim.players[1].x = sim.players[0].x
    sim.players[1].y = sim.players[0].y
    check sim.applyShout(0, "one")
    check sim.shoutLabels(viewerIndex = 1).len == 1
    for _ in 0 ..< ShoutTicks + 1:
      sim.step(none, none)
    check sim.recentShouts.len == 0
    check sim.shoutLabels(viewerIndex = 1).len == 0

  test "a backward scrub drops lingering bubbles instead of ghosting them":
    var
      sim = namedGame(2)
      state = initGlobalViewerState()
      spriteLabels = initTable[int, string]()
    let none = newSeq[InputState](sim.players.len)
    check sim.applyShout(0, "one")
    discard sim.boardShoutTexts(state, spriteLabels)
    for _ in 0 ..< ShoutTicks + 1:
      sim.step(none, none)
    check sim.boardShoutTexts(state, spriteLabels) == @["one"]   # lingering
    # A scrub restores an earlier sim: tickCount jumps BACKWARD and the
    # restored recentShouts is authoritative. Linger state must snap, not
    # ghost a bubble from the abandoned timeline.
    sim.tickCount -= ShoutTicks
    check sim.boardShoutTexts(state, spriteLabels).len == 0

suite "board bubbles hold their on-screen size on oversize maps":
  # Spectator clients fit the whole board to the viewport, so a bubble drawn
  # at fixed map pixels shrinks as boards grow — on a colossal board it was
  # an unreadable speck. The board stream zooms the bubble's map footprint
  # by how far the map outgrew the standard field on its most-outgrown axis.
  test "the zoom ladder tracks the map size classes":
    # 2-team shells: 1235x659 scaled by the class factor (arena.nim
    # mapSizeScale) — small 0.85x, large 1.3x, huge 1.8x, giant 2.6x,
    # colossal 5.2x.
    check shoutBubbleZoomFor(1050, 560) == 1
    check shoutBubbleZoomFor(1235, 659) == 1
    check shoutBubbleZoomFor(1606, 857) == 1
    check shoutBubbleZoomFor(2223, 1186) == 2
    check shoutBubbleZoomFor(3211, 1713) == 3
    check shoutBubbleZoomFor(6422, 3427) == 5
    # 4-team squares (960x960 shell): the fit is height-driven, so the zoom
    # follows height ÷ 659, not width ÷ 1235.
    check shoutBubbleZoomFor(960, 960) == 1
    check shoutBubbleZoomFor(2496, 2496) == 4
    check shoutBubbleZoomFor(4992, 4992) == 8

  test "a zoomed bubble scales its whole map footprint":
    var sim = twoTeamGame()
    let previousDir = getCurrentDir()
    setCurrentDir(GameDir)  # the vector bubble reads data/font.ttf
    try:
      let
        base = sim.buildShoutBubble(Red, "push mid")
        zoomed = sim.buildShoutBubble(Red, "push mid", zoom = 4)
      # Height is pure geometry (font box + pads + tail), so it scales
      # exactly; width is vector text layout, so just pin that it grew.
      check zoomed.height == base.height * 4
      check zoomed.width > base.width * 2
      check zoomed.pixels.len == zoomed.width * zoomed.height * 4
    finally:
      setCurrentDir(previousDir)
