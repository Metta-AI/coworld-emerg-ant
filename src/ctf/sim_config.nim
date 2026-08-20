## GameConfig lifecycle: defaults, JSON readers, validation, update, and
## the config echo (configJson). Stage 5 of
## docs/plans/2026-08-01-sim-split.md; re-exported by sim.nim.

import
  std/[json, strutils],
  jsony,
  sim_types, arena

proc defaultGameConfig*(): GameConfig =
  ## Returns the default CTF gameplay config.
  GameConfig(
    motionScale: MotionScale,
    accel: Accel,
    frictionNum: FrictionNum,
    frictionDen: FrictionDen,
    maxSpeed: MaxSpeed,
    stopThreshold: StopThreshold,
    playerBouncePct: PlayerBouncePct,
    seed: 0xA6019,
    speed: 1,
    lives: Lives,
    hitPoints: HitPoints,
    respawnTicks: RespawnTicks,
    gunRange: GunRange,
    fireCooldownTicks: FireCooldownTicks,
    fireWindupTicks: FireWindupTicks,
    carrierSpeedPct: CarrierSpeedPct,
    aimTurnRate: AimTurnRate,
    visionConeDeg: VisionConeDeg,
    visionBubble: VisionBubble,
    minPlayers: MinPlayers,
    startWaitTicks: StartWaitTicks,
    lobbyJoinTimeoutTicks: 0,
    gameOverTicks: GameOverTicks,
    maxTicks: MaxTicks,
    maxGames: MaxGames,
    showPlayerLabels: true,
    fastMode: true,
    teams: 2,
    scoring: ClassicScoring,
    mapPath: DefaultMapPath,
    mapSeed: -1,
    mapPoolIndex: -1,
    mapGen: MapGenOverrides(windows: -1, pits: -1, pitDensity: -1),
    mapSpec: "",
    closedRoster: false,
    slots: @[],
    perkMods: DefaultPerkMods,
    puddleDamagePct: DefaultPuddleDamagePct,
    barrierPickups: 0,
    gameMode: CtfMode,
    forageGoal: DefaultForageGoal,
    foodRespawnTicks: DefaultFoodRespawnTicks,
    pheromoneWashTick: DefaultPheromoneWashTick,
    antSenseRadius: DefaultAntSenseRadius,
    biteDamage: DefaultBiteDamage,
    biteCooldownTicks: DefaultBiteCooldownTicks,
    barrageMaxPerSec: 0,
    barrageStartPerSec: BarrageStartPerSec,
    barrageStartSec: BarrageStartSec,
    barrageSaturateSec: BarrageSaturateSec
  )

proc readConfigInt(node: JsonNode, name: string, value: var int) =
  ## Reads one optional integer config field.
  if not node.hasKey(name):
    return
  let item = node[name]
  if item.kind != JInt:
    raise newException(CtfError, "Config field " & name & " must be an integer.")
  value = item.getInt()

proc readConfigBool(node: JsonNode, name: string, value: var bool) =
  ## Reads one optional boolean config field.
  if not node.hasKey(name):
    return
  let item = node[name]
  if item.kind != JBool:
    raise newException(CtfError, "Config field " & name & " must be a boolean.")
  value = item.getBool()

proc readConfigString(node: JsonNode, name: string, value: var string) =
  ## Reads one optional string config field.
  if not node.hasKey(name):
    return
  let item = node[name]
  if item.kind != JString:
    raise newException(CtfError, "Config field " & name & " must be a string.")
  value = item.getStr()

proc readSlotTeam(text: string, slotIndex: int): Team =
  ## Reads one slot team string.
  case text.strip().toLowerAscii()
  of "red":
    Red
  of "blue":
    Blue
  of "green":
    Green
  of "yellow":
    Yellow
  else:
    raise newException(
      CtfError,
      "Config field slots[" & $slotIndex &
        "].team must be red, blue, green, or yellow."
    )

proc normalizedSlotColor(text: string): string =
  ## Returns a normalized slot color name.
  result = text.strip().toLowerAscii()
  result = result.replace("_", " ")
  result = result.replace("-", " ")
  result = result.replace(" ", "")

proc playerColorText*(color: uint8): string =
  ## Returns the readable player color name.
  for i in 0 ..< PlayerColors.len:
    if PlayerColors[i] == color:
      return PlayerColorNames[i]
  "unknown"

proc readSlotColor(text: string, slotIndex: int): uint8 =
  ## Reads one slot color string.
  case text.normalizedSlotColor()
  of "red":
    PlayerColors[0]
  of "orange":
    PlayerColors[1]
  of "yellow":
    PlayerColors[2]
  of "lightblue", "cyan":
    PlayerColors[3]
  of "pink":
    PlayerColors[4]
  of "lime":
    PlayerColors[5]
  of "blue":
    PlayerColors[6]
  of "paleblue":
    PlayerColors[7]
  of "gray", "grey":
    PlayerColors[8]
  of "white":
    PlayerColors[9]
  of "darkbrown":
    PlayerColors[10]
  of "brown":
    PlayerColors[11]
  of "darkteal", "teal":
    PlayerColors[12]
  of "green":
    PlayerColors[13]
  of "darknavy", "navy":
    PlayerColors[14]
  of "black":
    PlayerColors[15]
  else:
    raise newException(
      CtfError,
      "Config field slots[" & $slotIndex & "].color is unknown."
    )

proc readSlotSkin(node: JsonNode, slotIndex: int): Skin =
  ## Reads one tolerant cosmetic skin value.
  if node.kind == JString:
    case node.getStr()
    of "default":
      return DefaultSkin
    of "crown":
      return CrownSkin
    else:
      discard
  stderr.writeLine(
    "Warning: config slots[" & $slotIndex & "].skin value " & $node &
      " is unrecognized; using default."
  )
  DefaultSkin

proc readConfigSlots(node: JsonNode, slots: var seq[PlayerSlotConfig]) =
  ## Reads optional fixed player slot config entries.
  if not node.hasKey("slots"):
    return
  let items = node["slots"]
  if items.kind != JArray:
    raise newException(CtfError, "Config field slots must be an array.")
  slots.setLen(0)
  for i, item in items.elems:
    if item.kind != JObject:
      raise newException(
        CtfError,
        "Config field slots[" & $i & "] must be an object."
      )
    if item.hasKey("name"):
      raise newException(
        CtfError,
        "Config field slots[" & $i & "].name is not supported; use players[" &
          $i & "].name instead."
      )
    var slot: PlayerSlotConfig
    item.readConfigString("token", slot.token)
    if item.hasKey("team"):
      let team = item["team"]
      if team.kind != JString:
        raise newException(
          CtfError,
          "Config field slots[" & $i & "].team must be a string."
        )
      slot.team = readSlotTeam(team.getStr(), i)
      slot.hasTeam = true
    if item.hasKey("color"):
      let color = item["color"]
      if color.kind != JString:
        raise newException(
          CtfError,
          "Config field slots[" & $i & "].color must be a string."
        )
      slot.color = readSlotColor(color.getStr(), i)
      slot.hasColor = true
    if item.hasKey("skin"):
      slot.skin = readSlotSkin(item["skin"], i)
    slots.add(slot)

proc readConfigPlayers(node: JsonNode, slots: var seq[PlayerSlotConfig]) =
  ## Reads optional fixed player display names by slot index.
  if node.hasKey("player_names"):
    raise newException(
      CtfError,
      "Config field player_names is not supported; use players[].name instead."
    )
  if not node.hasKey("players"):
    return
  let items = node["players"]
  if items.kind != JArray:
    raise newException(CtfError, "Config field players must be an array.")
  if items.len > MaxPlayers:
    raise newException(
      CtfError,
      "Config field players cannot have more than " & $MaxPlayers &
        " entries."
    )
  if slots.len < items.len:
    slots.setLen(items.len)
  for i, item in items.elems:
    if item.kind != JObject:
      raise newException(
        CtfError,
        "Config field players[" & $i & "] must be an object."
      )
    if not item.hasKey("name"):
      raise newException(
        CtfError,
        "Config field players[" & $i & "].name is required."
      )
    let nameNode = item["name"]
    if nameNode.kind != JString:
      raise newException(
        CtfError,
        "Config field players[" & $i & "].name must be a string."
      )
    let name = nameNode.getStr()
    if name.len == 0:
      raise newException(
        CtfError,
        "Config field players[" & $i & "].name must not be empty."
      )
    slots[i].name = name

proc defaultSlotName(slotIndex: int): string =
  ## Returns the canonical name for one generated tournament slot.
  "Player" & $(slotIndex + 1)

proc readConfigTokens(
  node: JsonNode,
  slots: var seq[PlayerSlotConfig],
  closedRoster: bool
) =
  ## Reads optional fixed player slot tokens.
  if not node.hasKey("tokens"):
    return
  let items = node["tokens"]
  if items.kind != JArray:
    raise newException(CtfError, "Config field tokens must be an array.")
  if items.len > MaxPlayers:
    raise newException(
      CtfError,
      "Config field tokens cannot have more than " & $MaxPlayers & " entries."
    )
  if slots.len < items.len:
    slots.setLen(items.len)
  for i, item in items.elems:
    if item.kind != JString:
      raise newException(
        CtfError,
        "Config field tokens[" & $i & "] must be a string."
      )
    let token = item.getStr()
    if slots[i].token.len > 0 and slots[i].token != token:
      raise newException(
        CtfError,
        "Config field tokens[" & $i & "] conflicts with slots[" & $i &
          "].token."
      )
    slots[i].token = token
    if closedRoster and slots[i].name.len == 0:
      slots[i].name = defaultSlotName(i)

proc readTeamKey(text, field: string): Team =
  ## Reads one team-keyed map key (handicaps, perks).
  case text.strip().toLowerAscii()
  of "red":
    Red
  of "blue":
    Blue
  of "green":
    Green
  of "yellow":
    Yellow
  else:
    raise newException(
      CtfError,
      "Config field " & field & " has key " & text &
        "; expected red, blue, green, or yellow."
    )

proc readHandicapPermille(value: JsonNode, teamName: string): int =
  ## Reads one 0.0..1.0 handicap and returns it as a permille (0..1000).
  var f: float
  case value.kind
  of JFloat:
    f = value.getFloat()
  of JInt:
    f = float(value.getInt())
  else:
    raise newException(
      CtfError,
      "Config field handicaps." & teamName & " must be a number between 0 and 1."
    )
  if f < 0.0 or f > 1.0:
    raise newException(
      CtfError,
      "Config field handicaps." & teamName & " must be between 0 and 1."
    )
  # Round to the nearest permille. f is in [0, 1], so this lands in [0, 1000];
  # exactly 0.0 maps to 0 (the byte-identical no-handicap path).
  int(f * 1000.0 + 0.5)

proc readPerkGroup(value: JsonNode, teamName: string): PerkSet =
  ## Reads one perk group: an array of perk name strings.
  if value.kind != JArray:
    raise newException(
      CtfError,
      "Config field perks." & teamName & " group must be an array of perk names."
    )
  for item in value:
    if item.kind != JString:
      raise newException(
        CtfError,
        "Config field perks." & teamName & " has a non-string perk name."
      )
    try:
      result.incl(parsePerk(item.getStr()))
    except CtfError:
      raise newException(
        CtfError,
        "Config field perks." & teamName & " has unknown perk " &
          item.getStr() & "; expected armor, scope, grenade, thruster, or luck."
      )

proc readConfigPerks(node: JsonNode, config: var GameConfig) =
  ## Reads the optional per-team perk map. A team's value is one of:
  ##   a flat array  — {"red": ["armor", "scope"]} — one team-wide group;
  ##   nested arrays — {"blue": [["grenade"], ["thruster", "luck"]]} —
  ##     unnamed per-policy groups dealt in join order (CTF-Doubles);
  ##   an object     — {"blue": {"botA": ["grenade"], "botB": ["luck"]}} —
  ##     groups PINNED to policy names (policyName match; an unmatched
  ##     policy gets nothing).
  ## Omitted teams keep no perks. Like handicaps, a perk set named for an
  ## inactive team is accepted and simply never applies.
  if not node.hasKey("perks"):
    return
  let perks = node["perks"]
  if perks.kind != JObject:
    raise newException(CtfError, "Config field perks must be an object.")
  for teamName, value in perks.pairs:
    let team = readTeamKey(teamName, "perks")
    var groups: seq[PerkGroup]
    case value.kind
    of JObject:
      # Named groups, pinned to their policies.
      if value.len == 0:
        raise newException(
          CtfError,
          "Config field perks." & teamName &
            " is an empty object; omit the team instead."
        )
      for pol, group in value.pairs:
        if pol.len == 0:
          raise newException(
            CtfError,
            "Config field perks." & teamName & " has an empty policy name."
          )
        groups.add PerkGroup(pol: pol, perks: readPerkGroup(group, teamName))
    of JArray:
      if value.len == 0:
        # A flat empty array has no meaning ("no perks" is spelled by
        # omitting the team) and would otherwise register as one empty group
        # — flipping the has-perks gates (pmods, marker content) on a
        # perk-free team. An empty NESTED group ([["armor"], []]) stays
        # legal: it means "this policy gets nothing".
        raise newException(
          CtfError,
          "Config field perks." & teamName &
            " is an empty array; omit the team instead."
        )
      elif value[0].kind == JArray:
        for group in value:
          groups.add PerkGroup(perks: readPerkGroup(group, teamName))
      else:
        groups.add PerkGroup(perks: readPerkGroup(value, teamName))
    else:
      raise newException(
        CtfError,
        "Config field perks." & teamName &
          " must be an array of perk names, an array of groups, or a " &
          "policy-name object."
      )
    config.perks[team] = groups

proc readPerkModPermille(node: JsonNode, name: string, value: var int) =
  ## Reads one optional 0.0..1.0 perk-mod fraction into a permille.
  if not node.hasKey(name):
    return
  let item = node[name]
  var f: float
  case item.kind
  of JFloat:
    f = item.getFloat()
  of JInt:
    f = float(item.getInt())
  else:
    raise newException(
      CtfError,
      "Config field perkMods." & name & " must be a number between 0 and 1."
    )
  if f < 0.0 or f > 1.0:
    raise newException(
      CtfError,
      "Config field perkMods." & name & " must be between 0 and 1."
    )
  value = int(f * 1000.0 + 0.5)

proc readPerkModInt(node: JsonNode, name: string, value: var int) =
  ## Reads one optional integer perk mod, sanity-capped at 100 so a
  ## fat-fingered extra digit errors instead of shipping an absurd game.
  if not node.hasKey(name):
    return
  let item = node[name]
  if item.kind != JInt or item.getInt() < 0 or item.getInt() > 100:
    raise newException(
      CtfError,
      "Config field perkMods." & name & " must be an integer in 0..100."
    )
  value = item.getInt()

proc readConfigPerkMods(node: JsonNode, config: var GameConfig) =
  ## Reads the optional perk-magnitude overrides, e.g.
  ## {"armorHp": 1, "scopeAim": 0.5, "grenadeRange": 0.25,
  ##  "thrusterSpeed": 0.1, "luckChance": 0.1, "luckDamage": 2}.
  ## Fractions are authored 0..1 and stored as integer permille (the
  ## handicaps rule), so every in-sim derivation stays integer or perk-gated.
  ## Mods without a `perks` block are accepted and inert (nothing reads them
  ## until a seat carries the perk), mirroring the inactive-team tolerance.
  if not node.hasKey("perkMods"):
    return
  let mods = node["perkMods"]
  if mods.kind != JObject:
    raise newException(CtfError, "Config field perkMods must be an object.")
  for key in mods.keys:
    if key notin ["armorHp", "scopeAim", "grenadeRange", "thrusterSpeed",
        "luckChance", "luckDamage"]:
      raise newException(
        CtfError, "Config field perkMods has unknown key " & key & ".")
  mods.readPerkModInt("armorHp", config.perkMods.armorHp)
  mods.readPerkModPermille("scopeAim", config.perkMods.scopeAim)
  mods.readPerkModPermille("grenadeRange", config.perkMods.grenadeRange)
  mods.readPerkModPermille("thrusterSpeed", config.perkMods.thrusterSpeed)
  mods.readPerkModPermille("luckChance", config.perkMods.luckChance)
  mods.readPerkModInt("luckDamage", config.perkMods.luckDamage)
  if config.perkMods.luckDamage < 1:
    raise newException(
      CtfError, "Config field perkMods.luckDamage must be at least 1.")

proc readConfigHandicaps(node: JsonNode, config: var GameConfig) =
  ## Reads the optional per-team handicap map, e.g. {"red": 0.0, "blue": 0.6}.
  ## Omitted teams stay at 0 (no handicap). A handicap named for an inactive
  ## team is accepted and simply never applies, so a caller (e.g. Campaign)
  ## can set all four teams without knowing the active count.
  if not node.hasKey("handicaps"):
    return
  let handicaps = node["handicaps"]
  if handicaps.kind != JObject:
    raise newException(CtfError, "Config field handicaps must be an object.")
  for teamName, value in handicaps.pairs:
    config.handicaps[readTeamKey(teamName, "handicaps")] =
      readHandicapPermille(value, teamName)

proc validate(config: GameConfig) =
  ## Raises if a gameplay config has invalid values.
  if config.motionScale <= 0:
    raise newException(CtfError, "Config field motionScale must be positive.")
  if config.frictionDen <= 0:
    raise newException(CtfError, "Config field frictionDen must be positive.")
  if config.minPlayers < 1:
    raise newException(CtfError, "Config field minPlayers must be at least 1.")
  if config.teams notin [2, 4]:
    raise newException(CtfError, "Config field teams must be 2 or 4.")
  if config.scoring notin [ClassicScoring, PotScoring]:
    raise newException(
      CtfError,
      "Config field scoring must be " & ClassicScoring & " or " & PotScoring &
        "; got " & config.scoring & "."
    )
  if config.gameMode notin [CtfMode, EmergAntMode]:
    raise newException(
      CtfError,
      "Config field gameMode must be " & CtfMode & " or " & EmergAntMode &
        "; got " & config.gameMode & "."
    )
  if config.forageGoal < 1:
    raise newException(CtfError, "Config field forageGoal must be at least 1.")
  if config.gameMode == EmergAntMode and config.teams != 2:
    raise newException(CtfError, "Emerg-ant mode requires exactly 2 teams.")
  if config.foodRespawnTicks < 1:
    raise newException(
      CtfError, "Config field foodRespawnTicks must be at least 1.")
  if config.pheromoneWashTick < 0:
    raise newException(
      CtfError, "Config field pheromoneWashTick must not be negative.")
  if config.antSenseRadius < 1:
    raise newException(CtfError, "Config field antSenseRadius must be at least 1.")
  if config.biteDamage < 1:
    raise newException(CtfError, "Config field biteDamage must be at least 1.")
  if config.biteCooldownTicks < 1:
    raise newException(
      CtfError, "Config field biteCooldownTicks must be at least 1.")
  for i, slot in config.slots:
    if slot.hasTeam and ord(slot.team) >= config.teams:
      raise newException(
        CtfError,
        "Config field slots[" & $i & "].team is " & teamText(slot.team) &
          " but the game seats " & $config.teams & " teams."
      )
  if config.minPlayers > MaxPlayers:
    raise newException(CtfError, "can't do more than " & $MaxPlayers & " players.")
  if config.lives < 1:
    raise newException(CtfError, "Config field lives must be at least 1.")
  if config.hitPoints < 1:
    raise newException(CtfError, "Config field hitPoints must be at least 1.")
  if config.gunRange <= 0:
    raise newException(CtfError, "Config field gunRange must be positive.")
  if config.fireWindupTicks < 0:
    raise newException(CtfError, "Config field fireWindupTicks must not be negative.")
  if config.carrierSpeedPct <= 0 or config.carrierSpeedPct > 100:
    raise newException(CtfError, "Config field carrierSpeedPct must be 1..100.")
  if config.playerBouncePct < 0 or config.playerBouncePct > 100:
    raise newException(CtfError, "Config field playerBouncePct must be 0..100.")
  if config.aimTurnRate < 1:
    raise newException(CtfError, "Config field aimTurnRate must be at least 1.")
  if config.visionConeDeg < 0 or config.visionConeDeg > 180:
    raise newException(CtfError, "Config field visionConeDeg must be between 0 and 180.")
  if config.puddleDamagePct < 0 or config.puddleDamagePct > 100:
    raise newException(CtfError, "Config field puddleDamagePct must be 0..100.")
  if config.barrierPickups < 0 or
      config.barrierPickups > MaxBarrierPickupsPerTeam:
    raise newException(CtfError,
      "Config field barrierPickups must be 0.." & $MaxBarrierPickupsPerTeam & ".")
  if config.visionBubble < 0:
    raise newException(CtfError, "Config field visionBubble must be non-negative.")
  if config.speed notin [1, 2, 3, 4, 8, 16]:
    raise newException(
      CtfError,
      "Config field speed must be 1, 2, 3, 4, 8, or 16."
    )
  if config.startWaitTicks < 0:
    raise newException(CtfError, "Config field startWaitTicks must be non-negative.")
  if config.lobbyJoinTimeoutTicks < 0:
    raise newException(CtfError, "Config field lobbyJoinTimeoutTicks must be non-negative.")
  if config.respawnTicks < 0 or config.fireCooldownTicks < 0:
    raise newException(CtfError, "Timer config fields must not be negative.")
  if config.gameOverTicks < 0 or config.maxTicks < 0 or config.maxGames < 0:
    raise newException(CtfError, "Timer config fields must not be negative.")
  if config.barrageMaxPerSec < 0 or config.barrageMaxPerSec > BarrageAbsMaxPerSec:
    raise newException(
      CtfError,
      "Config field barrageMaxPerSec must be 0.." & $BarrageAbsMaxPerSec & ".")
  if config.barrageMaxPerSec > 0:
    if config.maxTicks <= 0:
      raise newException(
        CtfError,
        "Config field barrageMaxPerSec requires a time limit (maxTicks > 0): " &
          "the barrage starts off the game clock."
      )
    if config.barrageStartPerSec < 1 or
        config.barrageStartPerSec > config.barrageMaxPerSec:
      raise newException(
        CtfError,
        "Config field barrageStartPerSec must be 1..barrageMaxPerSec."
      )
    if config.barrageStartSec < 1:
      raise newException(
        CtfError, "Config field barrageStartSec must be at least 1.")
    if config.barrageSaturateSec < 1:
      raise newException(
        CtfError, "Config field barrageSaturateSec must be at least 1.")
  if config.slots.len > MaxPlayers:
    raise newException(CtfError, "Config field slots cannot have more than 8 entries.")
  if config.closedRoster and config.slots.len < config.minPlayers:
    raise newException(
      CtfError,
      "Config field closedRoster requires at least minPlayers configured slots."
    )
  if config.closedRoster:
    for i, slot in config.slots:
      if slot.name.len == 0:
        raise newException(
          CtfError,
          "Config field closedRoster requires players[" & $i & "].name."
        )
      if slot.token.len == 0:
        raise newException(
          CtfError,
          "Config field closedRoster requires slots[" & $i & "].token."
        )
  for i in 0 ..< config.slots.len:
    for j in i + 1 ..< config.slots.len:
      if config.slots[i].name.len > 0 and
          config.slots[i].name == config.slots[j].name:
        raise newException(
          CtfError,
          "Config field players has duplicate name " & config.slots[i].name & "."
        )
      if config.slots[i].token.len > 0 and
          config.slots[i].token == config.slots[j].token:
        raise newException(
          CtfError,
          "Config field slots has duplicate token."
        )

proc update*(config: var GameConfig, jsonText: string) =
  ## Updates a gameplay config from a JSON object.
  if jsonText.len == 0:
    return
  var node: JsonNode
  try:
    node = fromJson(jsonText)
  except jsony.JsonError as e:
    raise newException(CtfError, "Could not parse config JSON: " & e.msg)
  if node.kind != JObject:
    raise newException(CtfError, "Config must be a JSON object.")
  node.readConfigInt("motionScale", config.motionScale)
  node.readConfigInt("accel", config.accel)
  node.readConfigInt("frictionNum", config.frictionNum)
  node.readConfigInt("frictionDen", config.frictionDen)
  node.readConfigInt("maxSpeed", config.maxSpeed)
  node.readConfigInt("stopThreshold", config.stopThreshold)
  node.readConfigInt("playerBouncePct", config.playerBouncePct)
  node.readConfigInt("seed", config.seed)
  node.readConfigInt("speed", config.speed)
  node.readConfigInt("lives", config.lives)
  node.readConfigInt("hitPoints", config.hitPoints)
  node.readConfigInt("respawnTicks", config.respawnTicks)
  node.readConfigInt("gunRange", config.gunRange)
  node.readConfigInt("fireCooldownTicks", config.fireCooldownTicks)
  node.readConfigInt("fireWindupTicks", config.fireWindupTicks)
  node.readConfigInt("carrierSpeedPct", config.carrierSpeedPct)
  node.readConfigInt("aimTurnRate", config.aimTurnRate)
  node.readConfigInt("visionConeDeg", config.visionConeDeg)
  node.readConfigInt("visionBubble", config.visionBubble)
  node.readConfigInt("minPlayers", config.minPlayers)
  node.readConfigInt("startWaitTicks", config.startWaitTicks)
  node.readConfigInt("gameStartWaitTicks", config.startWaitTicks)
  node.readConfigInt("lobbyJoinTimeoutTicks", config.lobbyJoinTimeoutTicks)
  node.readConfigInt("gameOverTicks", config.gameOverTicks)
  node.readConfigInt("maxTicks", config.maxTicks)
  node.readConfigInt("maxGameTicks", config.maxTicks)
  node.readConfigInt("maxGames", config.maxGames)
  node.readConfigInt("barrageMaxPerSec", config.barrageMaxPerSec)
  node.readConfigInt("barrageStartPerSec", config.barrageStartPerSec)
  node.readConfigInt("barrageStartSec", config.barrageStartSec)
  node.readConfigInt("barrageSaturateSec", config.barrageSaturateSec)
  node.readConfigBool("showPlayerLabels", config.showPlayerLabels)
  node.readConfigBool("fastMode", config.fastMode)
  node.readConfigInt("teams", config.teams)
  node.readConfigString("scoring", config.scoring)
  node.readConfigString("map", config.mapPath)
  node.readConfigString("mapPath", config.mapPath)
  node.readConfigInt("mapSeed", config.mapSeed)
  node.readConfigInt("mapPoolIndex", config.mapPoolIndex)
  node.readConfigString("mapSize", config.mapGen.size)
  node.readConfigString("mapSymmetry", config.mapGen.symmetry)
  node.readConfigInt("mapColumns", config.mapGen.columns)
  node.readConfigInt("mapWindows", config.mapGen.windows)
  node.readConfigInt("mapPits", config.mapGen.pits)
  node.readConfigInt("mapPitDensity", config.mapGen.pitDensity)
  node.readConfigInt("mapPuddles", config.mapGen.puddles)
  node.readConfigInt("puddleDamagePct", config.puddleDamagePct)
  node.readConfigInt("barrierPickups", config.barrierPickups)
  node.readConfigString("gameMode", config.gameMode)
  node.readConfigInt("forageGoal", config.forageGoal)
  node.readConfigInt("foodRespawnTicks", config.foodRespawnTicks)
  node.readConfigInt("pheromoneWashTick", config.pheromoneWashTick)
  node.readConfigInt("antSenseRadius", config.antSenseRadius)
  node.readConfigInt("biteDamage", config.biteDamage)
  node.readConfigInt("biteCooldownTicks", config.biteCooldownTicks)
  node.readConfigString("mapCenterFeature", config.mapGen.centerFeature)
  node.readConfigString("mapLayout", config.mapGen.layout)
  node.readConfigString("mapEndzone", config.mapGen.endzone)
  node.readConfigInt("mapEndzoneRadius", config.mapGen.endzoneRadius)
  node.readConfigInt("mapBaseDepth", config.mapGen.baseDepth)
  if node.hasKey("mapSpec"):
    if node["mapSpec"].kind != JObject:
      raise newException(CtfError, "Config field mapSpec must be an object.")
    config.mapSpec = $node["mapSpec"]
  ## Resolve the effective map ONCE: a generated map is expanded and pinned
  ## as mapSpec here, so the replay carries the exact geometry and playback
  ## never re-runs the generator. The gun range follows the selected map
  ## unless the config sets it explicitly: each map def carries its own
  ## map-wide default.
  let mapMeta = resolveCtfMapMetadata(config)
  if config.mapSpec.len == 0 and mapMeta.path == GenMapName:
    config.mapSpec = mapSpecJson(mapMeta)
  if not node.hasKey("gunRange"):
    config.gunRange = mapMeta.gunRange
  node.readConfigSlots(config.slots)
  node.readConfigHandicaps(config)
  node.readConfigPerks(config)
  node.readConfigPerkMods(config)
  node.readConfigBool("closedRoster", config.closedRoster)
  node.readConfigTokens(config.slots, config.closedRoster)
  node.readConfigPlayers(config.slots)
  config.validate()

proc slotTeamText(slot: PlayerSlotConfig): string =
  ## Returns a JSON team string for one slot.
  if not slot.hasTeam:
    return ""
  teamText(slot.team)

proc slotColorText(slot: PlayerSlotConfig): string =
  ## Returns a JSON color string for one slot.
  if not slot.hasColor:
    return ""
  playerColorText(slot.color)

proc skinText(skin: Skin): string =
  ## Returns a JSON skin string.
  case skin
  of DefaultSkin:
    "default"
  of CrownSkin:
    "crown"

proc configJson*(config: GameConfig): string =
  ## Returns the complete replay JSON for a gameplay config.
  var
    players = newJArray()
    slots = newJArray()
    tokens = newJArray()
    includePlayers = false
  for slot in config.slots:
    var item = newJObject()
    if slot.name.len > 0:
      includePlayers = true
    tokens.add(%slot.token)
    players.add(%*{"name": slot.name})
    if slot.hasTeam:
      item["team"] = %slot.slotTeamText()
    if slot.hasColor:
      item["color"] = %slot.slotColorText()
    if slot.skin != DefaultSkin:
      item["skin"] = %slot.skin.skinText()
    slots.add(item)
  var node = %*{
    "motionScale": config.motionScale,
    "accel": config.accel,
    "frictionNum": config.frictionNum,
    "frictionDen": config.frictionDen,
    "maxSpeed": config.maxSpeed,
    "stopThreshold": config.stopThreshold,
    "playerBouncePct": config.playerBouncePct,
    "seed": config.seed,
    "speed": config.speed,
    "lives": config.lives,
    "hitPoints": config.hitPoints,
    "respawnTicks": config.respawnTicks,
    "gunRange": config.gunRange,
    "fireCooldownTicks": config.fireCooldownTicks,
    "fireWindupTicks": config.fireWindupTicks,
    "carrierSpeedPct": config.carrierSpeedPct,
    "aimTurnRate": config.aimTurnRate,
    "visionConeDeg": config.visionConeDeg,
    "visionBubble": config.visionBubble,
    "minPlayers": config.minPlayers,
    "startWaitTicks": config.startWaitTicks,
    "lobbyJoinTimeoutTicks": config.lobbyJoinTimeoutTicks,
    "gameOverTicks": config.gameOverTicks,
    "maxTicks": config.maxTicks,
    "maxGameTicks": config.maxTicks,
    "maxGames": config.maxGames,
    "mapPath": config.mapPath,
    "mapSeed": config.mapSeed,
    "mapPoolIndex": config.mapPoolIndex,
    "mapSize": config.mapGen.size,
    "mapSymmetry": config.mapGen.symmetry,
    "mapColumns": config.mapGen.columns,
    "mapWindows": config.mapGen.windows,
    "mapPits": config.mapGen.pits,
    "mapPitDensity": config.mapGen.pitDensity,
    "mapCenterFeature": config.mapGen.centerFeature,
    "mapLayout": config.mapGen.layout,
    "mapEndzone": config.mapGen.endzone,
    "mapEndzoneRadius": config.mapGen.endzoneRadius,
    "mapBaseDepth": config.mapGen.baseDepth,
    "closedRoster": config.closedRoster,
    "showPlayerLabels": config.showPlayerLabels,
    "fastMode": config.fastMode,
    "teams": config.teams,
    "scoring": config.scoring,
    "tokens": tokens,
    "slots": slots
  }
  if config.gameMode != CtfMode:
    node["gameMode"] = %config.gameMode
    node["forageGoal"] = %config.forageGoal
    node["foodRespawnTicks"] = %config.foodRespawnTicks
    node["pheromoneWashTick"] = %config.pheromoneWashTick
    node["antSenseRadius"] = %config.antSenseRadius
    node["biteDamage"] = %config.biteDamage
    node["biteCooldownTicks"] = %config.biteCooldownTicks
  if includePlayers:
    node["players"] = players
  # Echo the puddle keys only when the mode departs from the default, so a
  # puddle-free game's replay config stays byte-identical to pre-puddle
  # builds (same rule as the handicaps echo below).
  if config.mapGen.puddles > 0:
    node["mapPuddles"] = %config.mapGen.puddles
  if config.mapGen.puddles > 0 or
      config.puddleDamagePct != DefaultPuddleDamagePct:
    node["puddleDamagePct"] = %config.puddleDamagePct
  # Same rule for the barrier knob: echoed only when the mode is on, so a
  # barrier-free game's replay config stays byte-identical to older builds.
  if config.barrierPickups > 0:
    node["barrierPickups"] = %config.barrierPickups
  # Echo only the handicapped teams, as their authored 0..1 floats, so a
  # default (unhandicapped) game's replay config carries no handicaps key.
  var handicaps = newJObject()
  for team in Red .. Yellow:
    if config.handicaps[team] > 0:
      handicaps[teamText(team)] = %(config.handicaps[team].float / 1000.0)
  if handicaps.len > 0:
    node["handicaps"] = handicaps
  # Echo only the perked teams, in their authored shape — a policy-name
  # object for named (pinned) groups, one flat name array for a single
  # unnamed group, nested arrays for several — so a default (perk-free)
  # game's replay config carries no perks key.
  var perks = newJObject()
  for team in Red .. Yellow:
    if config.perks[team].len == 0:
      continue
    proc groupNames(group: PerkGroup): JsonNode =
      result = newJArray()
      for perk in Perk:
        if perk in group.perks:
          result.add(%perkText(perk))
    if config.perks[team][0].pol.len > 0:
      var named = newJObject()
      for group in config.perks[team]:
        named[group.pol] = groupNames(group)
      perks[teamText(team)] = named
    else:
      var groups = newJArray()
      for group in config.perks[team]:
        groups.add(groupNames(group))
      perks[teamText(team)] =
        if config.perks[team].len == 1: groups[0] else: groups
  if perks.len > 0:
    node["perks"] = perks
  # Echo perkMods only when some magnitude differs from its default, as the
  # authored shapes (fractions as 0..1 floats, counts as integers).
  if config.perkMods != DefaultPerkMods:
    node["perkMods"] = %*{
      "armorHp": config.perkMods.armorHp,
      "scopeAim": config.perkMods.scopeAim.float / 1000.0,
      "grenadeRange": config.perkMods.grenadeRange.float / 1000.0,
      "thrusterSpeed": config.perkMods.thrusterSpeed.float / 1000.0,
      "luckChance": config.perkMods.luckChance.float / 1000.0,
      "luckDamage": config.perkMods.luckDamage
    }
  # Echo the barrage keys only when the mode is on, so a default game's
  # replay config stays byte-identical to the pre-barrage echo.
  if config.barrageMaxPerSec > 0:
    node["barrageMaxPerSec"] = %config.barrageMaxPerSec
    node["barrageStartPerSec"] = %config.barrageStartPerSec
    node["barrageStartSec"] = %config.barrageStartSec
    node["barrageSaturateSec"] = %config.barrageSaturateSec
  if config.mapSpec.len > 0:
    node["mapSpec"] = fromJson(config.mapSpec)
  $node
