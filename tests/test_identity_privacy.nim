import
  helpers,
  std/[os, sequtils, strutils, unittest],
  bitworld/spriteprotocol,
  ctf/[global, sim]

# A player-observable frame must never name a CONNECTING PLAYER.
#
# A policy's connection address is its own name — in the league, the name of the
# build. Labels are the whole observation schema, so any label that carries an
# address is broadcast intel: rivals learn who is seated, and every time our
# bots talk to each other they say whose build is talking. That is a leak no
# amount of play skill can take back, and it is INVISIBLE — the label still
# renders, every test still passes, and the only symptom is that the other side
# knows things.
#
# The shout bubble was exactly that leak (`red shout daveey: H2`, fixed by
# `shoutIdentityName`). This test is deliberately broader than that one label:
# it sweeps EVERY sprite label in a player frame for a sentinel address, so the
# NEXT feature that reaches for `player.address` fails here instead of shipping.
#
# The board/broadcast stream is exempt on purpose and asserted separately: it is
# the human spectator/replay view, where the roster rows and the nameplates over
# each player's head are the point. Bots are never served that stream — they get
# `buildSpriteProtocolPlayerUpdates`. Keeping the exemption ASSERTED rather than
# merely unmentioned is what makes the player-side claim meaningful.

# Long, unmistakable, and sharing no substring with any label vocabulary word,
# so a hit is a real leak and never a coincidental match on "p0" or "red".
const SentinelAddresses = [
  "Qsentinel-alpha", "Qsentinel-bravo", "Qsentinel-charlie", "Qsentinel-delta"]

proc sentinelGame(): SimServer =
  ## Four sentinel-named seats piled on one spot — nothing is fogged out of any
  ## viewer's frame — with a live shout per team and a carried heart. Those are
  ## the three features that have ever rendered a player's name: the speech
  ## bubble, the scoreboard row, and the carrier nameplate.
  result = initCtfForTest(defaultGameConfig())
  for address in SentinelAddresses:
    discard result.addPlayer(address)
  result.startGame()
  for i in 1 ..< result.players.len:
    result.players[i].x = result.players[0].x
    result.players[i].y = result.players[0].y
  discard result.applyShout(0, "H2")      # red
  discard result.applyShout(1, "H3")      # blue
  result.flags[Blue].carrier = 0
  result.players[0].carryingFlag = true

proc labelsFor(sim: var SimServer, viewerIndex: int): seq[string] =
  ## Every sprite label one viewer receives in a frame: a seat index for the
  ## player stream a bot reads, -1 for the board/broadcast stream.
  let previousDir = getCurrentDir()
  setCurrentDir(GameDir)
  var packet: seq[uint8]
  try:
    if viewerIndex >= 0:
      var state, nextState: PlayerViewerState
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
    if message.kind == spkSprite:
      result.add message.sprite.label

proc leaks(labels: seq[string]): seq[string] =
  for label in labels:
    for address in SentinelAddresses:
      if address in label:
        result.add label
        break

suite "player frames never name a connecting player":
  test "no label in any player's frame contains a connection address":
    var sim = sentinelGame()
    # Sweep every seat, not just one: the carrier, its teammate, and both
    # enemies see different label sets (own HUD, fog, carrier nameplate).
    for viewer in 0 ..< sim.players.len:
      let labels = sim.labelsFor(viewer)
      # A frame that carried nothing would pass the leak check vacuously.
      check labels.len > 50
      let leaked = labels.leaks()
      if leaked.len > 0:
        checkpoint("\nSEAT " & $viewer & " RECEIVED " & $leaked.len &
          " LABEL(S) NAMING A CONNECTING PLAYER:\n    " &
          leaked.join("\n    ") & """

    A policy's address is its own name. Every label in a player frame is read
    off the wire by that policy's rivals, so this hands them the roster — and
    it fails no other test, because the label still renders fine.
    Emit the player's anonymous slot letter instead (IdentityNames, via
    sim.slotIdentityIndex / shoutIdentityName), or move the emission to the
    board stream if it is spectator chrome.
""")
        fail()

  test "a player's own frame does carry the shout it can hear":
    # Guards the sweep above against passing because shouts stopped rendering.
    var sim = sentinelGame()
    let heard = sim.labelsFor(1).filterIt(" shout " in it)
    check heard.len == 2                       # one per team, both in earshot
    check heard.allIt(it.endsWith(": H2") or it.endsWith(": H3"))

  test "the board stream still names players, on purpose":
    # The spectator/replay view is the exemption. Asserting it keeps the
    # player-side guarantee honest: if this ever came up empty, the sweep above
    # would be proving nothing about where addresses are allowed to go.
    var sim = sentinelGame()
    check sim.labelsFor(-1).leaks().len > 0
