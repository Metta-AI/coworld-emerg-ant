import
  helpers,
  std/[json, sequtils, unittest],
  bitworld/spriteprotocol,
  # jsonRow lives in ctf/events, not in the tool that used to own it.
  ctf/[events, sim],
  "../tools/extract_events"

proc eventsOf(sim: SimServer, kind: SimEventKind): seq[SimEvent] =
  sim.events.filterIt(it.kind == kind)

suite "rich analysis events":
  test "trigger, delayed fire, and impact share one action id and heading":
    var game = twoTeamGame(collectEvents = true)
    game.players[0].placeAtCenter(60, MapHeight div 2)
    game.players[0].aimBrads = 0
    game.players[1].placeAtCenter(100, MapHeight div 2)

    var trigger = game.none()
    trigger[0].attack = true
    game.step(trigger, game.none())

    let triggers = game.eventsOf(GunTrigger)
    check triggers.len == 1
    check triggers[0].source == 0
    check triggers[0].headingBrads == 0
    check triggers[0].actionId > 0
    check game.eventsOf(Shot).len == 0
    let triggerTick = triggers[0].tick
    # The trigger locks aim. Turning during the windup must not redirect it.
    game.players[0].aimBrads = 64

    var previous = trigger
    for _ in 0 ..< game.config.fireWindupTicks:
      game.step(game.none(), previous)
      previous = game.none()

    let
      shots = game.eventsOf(Shot)
      impacts = game.eventsOf(ShotImpact)
    check shots.len == 1
    check impacts.len == 1
    check shots[0].tick > triggerTick
    check shots[0].actionId == triggers[0].actionId
    check impacts[0].actionId == triggers[0].actionId
    check shots[0].headingBrads == 0
    check impacts[0].headingBrads == 0
    check impacts[0].target == 1
    check impacts[0].damages.len == 1
    if impacts[0].damages.len == 1:
      check impacts[0].damages[0].slot == 1
      check impacts[0].damages[0].amount == 1

  test "simultaneous lethal shots retain each trigger id and locked heading":
    var game = twoTeamGame(collectEvents = true)
    game.players[0].placeAtCenter(60, MapHeight div 2)
    game.players[0].aimBrads = 0
    game.players[0].hp = 1
    game.players[1].placeAtCenter(100, MapHeight div 2)
    game.players[1].aimBrads = 128
    game.players[1].hp = 1

    game.startFireWindup(0)
    game.startFireWindup(1)
    let triggers = game.eventsOf(GunTrigger)
    check triggers.len == 2

    # Killing a shooter resets their pending windup. Both released shots must
    # still use the trigger metadata captured before either kill is applied.
    game.players[0].aimBrads = 64
    game.players[1].aimBrads = 192
    for _ in 0 ..< game.config.fireWindupTicks:
      game.step(game.none(), game.none())

    let
      shots = game.eventsOf(Shot)
      impacts = game.eventsOf(ShotImpact)
    check shots.len == 2
    check impacts.len == 2
    for source, heading in [0, 128]:
      let
        trigger = triggers.filterIt(it.source == source)
        shot = shots.filterIt(it.source == source)
        impact = impacts.filterIt(it.source == source)
      check trigger.len == 1
      check shot.len == 1
      check impact.len == 1
      if trigger.len == 1 and shot.len == 1 and impact.len == 1:
        check shot[0].actionId == trigger[0].actionId
        check impact[0].actionId == trigger[0].actionId
        check shot[0].headingBrads == heading
        check impact[0].headingBrads == heading
        check impact[0].damages.len == 1

  test "a missed shot still reports its wall or range impact":
    var game = twoTeamGame(collectEvents = true)
    game.players[0].x = game.gameMap.center.x
    game.players[0].y = game.gameMap.center.y
    game.players[0].aimBrads = 64
    game.players[1].x = game.gameMap.center.x + 200
    game.players[1].y = game.gameMap.center.y
    game.tryFire(0)

    let impacts = game.eventsOf(ShotImpact)
    check impacts.len == 1
    check impacts[0].target == -1
    check impacts[0].damages.len == 0
    check impacts[0].x != 0 or impacts[0].y != 0

  test "grenade throw and impact correlate and carry splash damage":
    var game = initCtfForTest()
    for address in ["red0", "red1", "blue0"]:
      discard game.addPlayer(address)
    game.startGame()
    game.players[0].team = Red
    game.players[1].team = Red
    game.players[2].team = Blue
    game.collectEvents = true
    for i in 0 ..< 3:
      game.players[i].x = 300
      game.players[i].y = 300 + i * 4
      game.players[i].hp = GrenadeDamage + 1
    game.players[0].aimBrads = 0
    game.players[0].hasGrenade = true

    var held = game.none()
    held[0].c = true
    game.step(held, game.none())
    game.step(game.none(), held)

    let throws = game.eventsOf(GrenadeThrow)
    check throws.len == 1
    check throws[0].source == 0
    check throws[0].headingBrads == 0
    check throws[0].distance > 0
    check throws[0].actionId > 0

    while game.airborneGrenades.len > 0:
      game.step(game.none(), game.none())
    let impacts = game.eventsOf(GrenadeImpact)
    check impacts.len == 1
    check impacts[0].actionId == throws[0].actionId
    check impacts[0].damages.len == 3
    check impacts[0].damages.mapIt(it.slot) == @[0, 1, 2]
    for damage in impacts[0].damages:
      check damage.amount == GrenadeDamage

  test "an airborne grenade retains its actor after the thrower disconnects":
    var game = initCtfForTest()
    for address in ["red0", "blue0", "blue1"]:
      discard game.addPlayer(address)
    game.startGame()
    game.players[0].team = Red
    game.players[1].team = Blue
    game.players[2].team = Blue
    game.collectEvents = true
    game.players[1].x = 300
    game.players[1].y = 300
    game.players[1].aimBrads = 0
    game.players[1].hasGrenade = true
    game.players[2].x = 300
    game.players[2].y = 300
    game.players[2].hp = GrenadeDamage

    var held = game.none()
    held[1].c = true
    game.step(held, game.none())
    game.step(game.none(), held)
    let throws = game.eventsOf(GrenadeThrow)
    check throws.len == 1
    check throws[0].source == 1

    game.removePlayerAt(1)
    while game.airborneGrenades.len > 0:
      game.step(game.none(), game.none())

    let impacts = game.eventsOf(GrenadeImpact)
    check impacts.len == 1
    if impacts.len == 1:
      check impacts[0].source == 1
      check impacts[0].actionId == throws[0].actionId
    let kills = game.eventsOf(Kill)
    check kills.anyIt(it.source == 1 and it.target == 2)
    let deaths = game.eventsOf(Death)
    check deaths.anyIt(it.source == 2 and it.target == 1)
    let results = parseJson(game.playerResultsJson())
    check results["kills"][1].getInt == 1
    check results["kills"][2].getInt == 0

  test "action ids remain unique after the lobby resets its tick and slots":
    var game = twoTeamGame(collectEvents = true)
    game.players[0].placeAtCenter(60, MapHeight div 2)
    game.players[0].aimBrads = 0
    game.tryFire(0)
    let firstAction = game.eventsOf(Shot)[0].actionId

    game.resetToLobby()
    discard game.addPlayer("new-red")
    discard game.addPlayer("new-blue")
    game.startGame()
    game.players[0].team = Red
    game.players[1].team = Blue
    game.players[0].placeAtCenter(60, MapHeight div 2)
    game.players[0].aimBrads = 0
    game.events.setLen(0)
    game.tryFire(0)

    let secondAction = game.eventsOf(Shot)[0].actionId
    check secondAction != firstAction

  test "each active spray use reports heading and players damaged that tick":
    var game = twoTeamGame(collectEvents = true)
    game.players[0].placeAtCenter(60, MapHeight div 2)
    game.players[0].aimBrads = 0
    game.players[0].hasPlasmaArc = true
    game.players[1].placeAtCenter(100, MapHeight div 2)
    game.players[1].hp = PlasmaArcDamage + 1

    var attack = game.none()
    attack[0].attack = true
    game.step(attack, game.none())

    let uses = game.eventsOf(SprayUse)
    check uses.len == 1
    check uses[0].source == 0
    check uses[0].headingBrads == 0
    check uses[0].actionId > 0
    check uses[0].damages.len == 1
    if uses[0].damages.len == 1:
      check uses[0].damages[0].slot == 1
      check uses[0].damages[0].amount == PlasmaArcDamage

  test "pickups identify the item, player, and pickup location":
    var game = twoTeamGame(collectEvents = true)
    game.players[0].x = game.grenadeSpawns[0].x
    game.players[0].y = game.grenadeSpawns[0].y
    game.tryPickupGrenades(0)

    game.players[0].hp = game.config.hitPoints - 1
    game.players[0].x = game.medKitSpawns[0].x
    game.players[0].y = game.medKitSpawns[0].y
    game.tryPickupMedKits(0)

    game.players[0].x = game.shieldSpawns[0].x
    game.players[0].y = game.shieldSpawns[0].y
    game.tryPickupShields(0)

    game.players[0].x = game.plasmaArcSpawns[0].x
    game.players[0].y = game.plasmaArcSpawns[0].y
    game.tryPickupPlasmaArcs(0)

    let pickups = game.eventsOf(Pickup)
    check pickups.mapIt(it.item) == @["grenade", "med_kit", "shield", "spray_can"]
    for pickup in pickups:
      check pickup.source == 0
      check pickup.x != 0 or pickup.y != 0

  test "shouts carry the sanitized content and shouter":
    var game = twoTeamGame(collectEvents = true)
    check game.applyShout(0, " push mid ")
    let shouts = game.eventsOf(ShoutEvent)
    check shouts.len == 1
    check shouts[0].source == 0
    check shouts[0].content == "push mid"
    check shouts[0].x == float(game.recentShouts[0].x)
    check shouts[0].y == float(game.recentShouts[0].y)

  test "JSON rows expose correlation, heading, item, content, and damages":
    let row = SimEvent(
      tick: 12,
      kind: GrenadeImpact,
      source: 2,
      actionId: 7,
      headingBrads: 32,
      distance: 90,
      item: "grenade",
      content: "",
      x: 10,
      y: 20,
      damages: @[
        EventDamage(slot: 3, amount: 2, hp: 1, blocked: 0)
      ]
    ).jsonRow()
    for field in [
      "action_id", "heading_brads", "distance", "item", "content", "damages"
    ]:
      check row.hasKey(field)
    check row["kind"].getStr == "grenade_impact"
    check row["damages"].len == 1
    check row["damages"][0]["slot"].getInt == 3
