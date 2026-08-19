import
  helpers,
  std/[sets, tables, strutils, unittest],
  bitworld/spriteprotocol,
  ctf/[global, sim]

# Sprite-id collision + bot label-contract audit.
#
# The client keeps ONE sprite definition per id per connection, and a later
# definition REPLACES an earlier one — so two render sites claiming the same
# id is a silent, game-wide failure: whichever label loses, every exact-match
# label scan for it goes blind (the 2026-07-22 incident: UnitTagSpriteBase =
# 5000 clobbered SpritePlayerFireSpriteId = 5000 "fire icon", and every
# scripted bot stopped firing — zero shots per game — while nothing crashed
# and no unit test failed).
#
# Two guards, both over a FULL-FEATURE frame (carriers of every pickup, a
# visible enemy, live pickups on the floor):
#   1. within one packet, no sprite id may be defined twice with different
#      labels (two call sites claiming the same id);
#   2. after applying several ticks of packets in arrival order (client
#      semantics, later-def-wins), every label the baseline bot exact-match
#      scans for must still exist in the table (the label CONTRACT — also
#      catches cross-packet clobbering and silent renames).

proc fullFeatureGame(withCrown = true, crownOnly = false): SimServer =
  ## A game exercising every sprite family at once: a viewer, a visible
  ## enemy, teammates carrying shield / grenade / plasma arc, floor pickups
  ## untouched, and combat FX.
  var config = defaultGameConfig()
  if withCrown:
    config.slots.setLen(if crownOnly: MaxPlayers else: 6)
    for i in 0 ..< config.slots.len:
      config.slots[i].skin =
        if crownOnly or i mod 2 != 0: CrownSkin else: DefaultSkin
  result = initCtfForTest(config)
  for i in 0 ..< 6:
    discard result.addPlayer("p" & $i)
  result.startGame()
  for i in 0 ..< result.players.len:
    result.players[i].team = (if i mod 2 == 0: Red else: Blue)
  let
    cx = result.gameMap.center.x
    cy = result.gameMap.center.y
  # Viewer (0, Red) mid-map aiming east at a visible enemy (1, Blue).
  result.players[0].x = cx - 60
  result.players[0].y = cy
  result.players[0].aimBrads = 0
  # The enemy carries a shield so the carry marker + bubble render.
  result.players[1].x = cx + 60
  result.players[1].y = cy
  result.players[1].hasShield = true
  # Red teammates just behind the viewer, in its vision bubble, carrying
  # the grenade and the plasma arc so those markers render too.
  result.players[2].x = cx - 90
  result.players[2].y = cy - 20
  result.players[2].hasGrenade = true
  result.players[4].x = cx - 90
  result.players[4].y = cy + 20
  result.players[4].hasPlasmaArc = true

proc conflicts(messages: openArray[SpritePacketMessage]): seq[string] =
  ## Ids defined twice with different labels WITHIN one packet.
  var seen: Table[int, string]
  for message in messages:
    if message.kind != spkSprite:
      continue
    let id = message.sprite.id
    let label = message.sprite.label
    if id in seen and seen[id] != label:
      result.add("sprite id " & $id & ": \"" & seen[id] &
        "\" vs \"" & label & "\"")
    seen[id] = label

proc applyDefs(
  table: var Table[int, string],
  messages: openArray[SpritePacketMessage]
) =
  ## Client semantics: a later definition for an id replaces the earlier one.
  for message in messages:
    if message.kind == spkSprite:
      table[message.sprite.id] = message.sprite.label

proc actorDefinitionIds(
  messages: openArray[SpritePacketMessage]
): HashSet[int] =
  ## Skin-master definition ids, including live, corpse, and selected variants.
  ## Scoped to the per-skin soldier pools (all < RigHeadSpriteBase): the board
  ## turret-rig HEAD segment also carries the "player <color>" contract label and
  ## lives in its own pool at RigHeadSpriteBase+, so it must not count toward the
  ## unified-soldier pool arithmetic.
  for message in messages:
    if message.kind != spkSprite:
      continue
    if message.sprite.id >= RigHeadSpriteBase:
      continue
    let label = message.sprite.label
    if label.startsWith("player ") or label.startsWith("corpse ") or
        label.startsWith("selected player "):
      result.incl(message.sprite.id)

suite "sprite id collisions":
  test "only configured skin sprite pools are registered":
    var
      defaultGame = fullFeatureGame(withCrown = false)
      mixedGame = fullFeatureGame()
      crownGame = fullFeatureGame(crownOnly = true)
      defaultState = initGlobalViewerState()
      mixedState = initGlobalViewerState()
      crownState = initGlobalViewerState()
    let
      defaultIds = defaultGame.buildGlobalMessages(defaultState)
        .actorDefinitionIds()
      mixedIds = mixedGame.buildGlobalMessages(mixedState)
        .actorDefinitionIds()
      crownIds = crownGame.buildGlobalMessages(crownState)
        .actorDefinitionIds()
    check defaultIds.len == 3 * 2 * SoldierRotations
    check mixedIds.len == 2 * defaultIds.len
    check crownIds.len == defaultIds.len
    for id in defaultIds:
      check id in mixedIds
      check id notin crownIds

  test "no two render sites claim one sprite id in a packet":
    var game = fullFeatureGame()
    # Exercise the collision-prone extras: a spectator-selected Blue player
    # (the outlined-soldier pool) and a landed shot (sound/impact rings).
    game.players[0].fireCooldown = 0
    game.tryFire(0)
    var pstate: PlayerViewerState
    var gstate = initGlobalViewerState()
    gstate.selectedJoinOrder = game.players[1].joinOrder
    check game.buildPlayerMessages(0, pstate).conflicts() == newSeq[string]()
    check game.buildPlayerMessages(1, pstate).conflicts() == newSeq[string]()
    check game.buildGlobalMessages(gstate).conflicts() == newSeq[string]()

  test "a 4-team frame defines no colliding sprite ids":
    # The widened pools (soldier/corpse/selected strides, rig blocks, flag
    # 700..703, carry hearts 600..663, endzone fades 4100..4131) all get
    # exercised by a full 4-team frame with green/yellow seated.
    var config = defaultGameConfig()
    config.teams = 4
    config.mapPath = "gen"
    config.mapGen.layout = "corners"
    config.mapSeed = 42
    var game = initCtfForTest(config)
    for i in 0 ..< 8:
      discard game.addPlayer("p" & $i)
    game.startGame()
    let green = game.gameMap.flagHome(Green)
    game.players[0].x = green.x - CollisionW div 2
    game.players[0].y = green.y - CollisionH div 2
    game.tryPickupFlags(0)
    check game.flags[Green].carrier == 0
    var pstate: PlayerViewerState
    var gstate = initGlobalViewerState()
    gstate.selectedJoinOrder = game.players[3].joinOrder
    check game.buildPlayerMessages(0, pstate).conflicts() == newSeq[string]()
    check game.buildPlayerMessages(3, pstate).conflicts() == newSeq[string]()
    check game.buildGlobalMessages(gstate).conflicts() == newSeq[string]()

  test "bot-critical labels survive a full-feature frame":
    # Every label the baseline bot exact-match scans for. A missing entry
    # means either a silent rename or a sprite-id clobber — both blind every
    # scripted bot in the league while nothing else fails.
    var game = fullFeatureGame()
    var pstate: PlayerViewerState
    var defs: Table[int, string]
    let none = newSeq[InputState](game.players.len)
    # Floor-pickup sprites define lazily on first sight (fog-gated), so walk
    # the viewer past each spawn family; the def table accumulates.
    let stops = [
      (game.players[0].x, game.players[0].y),
      (game.grenadeSpawns[0].x, game.grenadeSpawns[0].y),
      (game.shieldSpawns[0].x, game.shieldSpawns[0].y),
      (game.plasmaArcSpawns[0].x, game.plasmaArcSpawns[0].y),
      (game.medKitSpawns[0].x, game.medKitSpawns[0].y),
    ]
    for stop in stops:
      # Hover NEXT TO the spawn (not on it) so nothing is picked up.
      game.players[0].x = stop[0] + 40
      game.players[0].y = stop[1]
      game.players[0].aimBrads = 128    # aim west, spawn in the cone
      defs.applyDefs(game.buildPlayerMessages(0, pstate))
      game.step(none, none)
      defs.applyDefs(game.buildPlayerMessages(0, pstate))
    var labels = initHashSet[string]()
    var prefixes = initHashSet[string]()
    for label in defs.values:
      labels.incl(label)
      let space = label.find(' ')
      if space > 0:
        prefixes.incl(label[0 .. space])
    for needed in [
      "fire icon",            # the bot's trigger gate (shotReady)
      "walkability map",      # the bot's navigation grid
      "med kit",              # pickup routing
      "shield",               # endzone pickup
      "shield carried",       # own/enemy carry state
      "grenade",              # corner pickup
      "grenade carried",      # own carry state (nade state machine)
      "spray can carried",    # own carry state (spray discipline)
    ]:
      check needed in labels
    # Actor and HUD families the bot parses by prefix.
    check "player " in prefixes    # "player red right" etc (actorsFor)
    check "hp " in prefixes        # overhead pips "hp N/3"
    check "lives " in prefixes     # own-HUD hp/lives text

  test "4-team rig sprites stay inside the dynamic wire window":
    # REGRESSION (the 2026-08-02 black-stripe reports): rig pose KEYS exceed
    # u16 — a yellow (4th team) rear-leg key is >= ~70040, and the wire's
    # addU16 wrapped it mod 65536 onto the low sprite ids, permanently
    # redefining once-only map-band sprites as 96x96 leg art on every client
    # (full-width black stripes; the emitter's dedup cache keys on the full
    # id, so the clobbered band was never re-sent). Rig ids must reach the
    # wire only through the dense dynamic window at DynamicSpriteWireBase+:
    # across a maneuvering 4-team game, no rig segment may define a sprite
    # below the window, and every map-band id keeps its band label.
    var config = defaultGameConfig()
    config.teams = 4
    config.mapPath = "gen"
    config.mapGen.layout = "corners"
    config.mapSeed = 42
    var game = initCtfForTest(config)
    for i in 0 ..< 8:
      discard game.addPlayer("p" & $i)
    game.startGame()
    var gstate = initGlobalViewerState()
    var defs: Table[int, string]
    var inputs = newSeq[InputState](game.players.len)
    let none = newSeq[InputState](game.players.len)
    for tick in 0 ..< 48:
      # Sweep aim/heading through all 16 rig steps while moving and turning,
      # so leg swing/shorten and wheel caster fan the pose keys out across
      # the pool (the persistent gstate steps each cog's drive state).
      for i in 0 ..< game.players.len:
        game.players[i].aimBrads = (tick * 16 + i * 32) mod 256
        inputs[i].up = tick mod 4 < 2
        inputs[i].down = tick mod 4 >= 2
        inputs[i].left = tick mod 2 == 0
        inputs[i].right = tick mod 2 == 1
      defs.applyDefs(game.buildGlobalMessages(gstate))
      game.step(inputs, none)
    var sawRigLimb = false
    for id, label in defs:
      if label.startsWith("cog "):
        sawRigLimb = true
        check id >= DynamicSpriteWireBase
      if id >= MapBandSpriteBase and id < MapBandSpriteBase + 60:
        check label.startsWith("map band")
    # The invariants above are vacuous unless rig limbs actually rendered.
    check sawRigLimb
    # The debug pool shares the dynamic window but its RAW keys overlap the
    # rig keys (both start at 40000): the namespaced remap must still hand
    # debug sprites their own slots, never one already claimed by a rig pose
    # (or any other sprite this game defined).
    check debugSpriteId(0, 0) notin defs
    check debugSpriteId(0, 0) >= DynamicSpriteWireBase
