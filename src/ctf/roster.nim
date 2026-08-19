## Roster machinery: slot identities and limits, join/auth resolution
## (resolvePlayerSlot), reward accounts, addPlayer/removePlayerAt,
## per-player records and playerResultsJson. Sole runtime consumer beyond
## the sim loop is server.nim. Stage 5 of
## docs/plans/2026-08-01-sim-split.md; re-exported by sim.nim.

import
  std/json,
  sim_types, sim_state

proc perkSetForJoin*(sim: SimServer, team: Team, address: string): PerkSet =
  ## The perk group for a seat about to join `team` as `address`. NAMED
  ## groups (object config form) match the seat's policyName exactly — an
  ## unmatched policy gets nothing, so an operator can pin which policy
  ## receives which buffs. Unnamed groups (array form) deal to the team's
  ## distinct POLICIES in join order — a seat of an already-seated policy
  ## shares that policy's group, a new policy takes the next one (clamped to
  ## the last, so a lone group is simply team-wide). Pure function of
  ## config + the join AND leave stream
  ## (both replay), so playback resolves identically and already-seated
  ## players never reshuffle. Caveat under churn: ranks derive from the
  ## CURRENT roster, so if a policy's seats all leave, the next new policy
  ## inherits its rank — seats of one policy are only guaranteed a shared
  ## group while the team's policy lineup stays stable (always true for
  ## league rosters, which seat once at start).
  let groups = sim.config.perks[team]
  if groups.len == 0:
    return {}
  let pol = policyName(address)
  # A NAMED group pins its perks to exactly that policy; a policy no named
  # group claims gets nothing on an all-named team. (The parser guarantees a
  # team's groups are all-named or all-unnamed.)
  if groups[0].pol.len > 0:
    for group in groups:
      if group.pol == pol:
        return group.perks
    return {}
  var seen: seq[string]
  for p in sim.players:
    if p.team != team:
      continue
    let seatedPol = policyName(p.address)
    if seatedPol notin seen:
      seen.add seatedPol
  var index = seen.find(pol)
  if index < 0:
    index = seen.len
  groups[min(index, groups.high)].perks

proc teamForSlot*(sim: SimServer, order: int): Team =
  ## Returns the configured or default team for one slot: slots deal round
  ## the active teams in enum order (the classic red/blue alternation on
  ## 2-team maps).
  let slot =
    if order >= 0 and order < sim.config.slots.len:
      sim.config.slots[order]
    else:
      PlayerSlotConfig()
  if slot.hasTeam:
    slot.team
  else:
    Team(order mod sim.gameMap.teamCount())

const IdentityNames* = [
  "alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta"]
  ## Per-team player identities, assigned by slot order within the team.

proc slotIdentityIndex*(sim: SimServer, order: int): int =
  ## Returns one slot's identity index (into IdentityNames): its rank among
  ## same-team slots. Derived from the config, not stored, so it is stable
  ## across matches, reconnects, and replays. Wraps past theta in the
  ## degenerate case of more than IdentityNames.len slots on one team.
  let team = sim.teamForSlot(order)
  for i in 0 ..< order:
    if sim.teamForSlot(i) == team:
      inc result
  result = result mod IdentityNames.len

const IdentityNameUnknown* = "?"
  ## Stands in for a slot name that cannot be resolved; see `shoutIdentityName`.

proc shoutIdentityName*(sim: SimServer, shout: Shout): string =
  ## One shout author's anonymous slot name (an `IdentityNames` entry), for the
  ## speech-bubble label.
  ##
  ## Deliberately NOT `shout.address`. The address is the connecting policy's
  ## own name, and EVERY player in earshot reads shout labels off the wire — so
  ## labeling a bubble with the address hands rivals a free roster of who is in
  ## the match, and hands them our own name every time our bots talk to each
  ## other. The slot letter carries the same signal a listener can actually use
  ## ("which teammate called this") with no identity attached.
  ##
  ## Resolved at render time rather than stored on `Shout`, which is
  ## flatty-serialized into `SimServer` and therefore into replays: an extra
  ## field there would be a GameVersion break for a string that only ever
  ## exists in a rendered label.
  ##
  ## A bubble OUTLIVES its author — it displays for ShoutTicks, and the shouter
  ## can disconnect inside that window (`removePlayerAt` drops the row) — so an
  ## unresolvable author falls back to IdentityNameUnknown rather than dropping
  ## the bubble, which is observable state.
  for player in sim.players:
    if player.address == shout.address:
      return IdentityNames[sim.slotIdentityIndex(player.joinOrder)]
  IdentityNameUnknown

proc playerSlotLimit*(config: GameConfig): int =
  ## Returns the number of slots players may occupy.
  if config.closedRoster: config.slots.len else: MaxPlayers

proc usedSkins*(config: GameConfig): set[Skin] =
  ## Returns the skins needed by slots that can join this game.
  if config.slots.len < config.playerSlotLimit():
    result.incl(DefaultSkin)
  for slot in config.slots:
    result.incl(slot.skin)

proc canAddPlayer*(sim: SimServer): bool =
  ## Returns whether the game has room for another player.
  sim.players.len < sim.config.playerSlotLimit()

proc playerLimitError(config: GameConfig): string =
  ## Returns a user-facing message for the current player cap.
  if config.closedRoster:
    let limit = config.playerSlotLimit()
    return "Configured roster is full (" & $limit &
      (if limit == 1: " player)." else: " players).")
  "can't do more than " & $MaxPlayers & " players."

proc slotConfig(config: GameConfig, slotIndex: int): PlayerSlotConfig =
  ## Returns one slot config or an empty config for missing entries.
  if slotIndex >= 0 and slotIndex < config.slots.len:
    config.slots[slotIndex]
  else:
    PlayerSlotConfig()

proc slotRestricted(config: GameConfig, slotIndex: int): bool =
  ## Returns true when a slot has identity restrictions.
  let slot = config.slotConfig(slotIndex)
  slot.name.len > 0 or slot.token.len > 0

proc slotAuthMatches(
  config: GameConfig,
  slotIndex: int,
  address,
  token: string
): bool =
  ## Returns true when a player satisfies one configured slot.
  let slot = config.slotConfig(slotIndex)
  if slot.name.len > 0 and address != slot.name:
    return false
  if slot.token.len > 0 and token != slot.token:
    return false
  true

proc hasConfiguredToken(config: GameConfig, token: string): bool =
  ## Returns true when a token matches any configured slot.
  for slot in config.slots:
    if slot.token.len > 0 and slot.token == token:
      return true
  false

proc hasConfiguredTokens(config: GameConfig): bool =
  ## Returns true when any slot has an auth token.
  for slot in config.slots:
    if slot.token.len > 0:
      return true
  false

proc validatePlayerSlot(
  config: GameConfig,
  slotIndex: int,
  address,
  token: string
) =
  ## Raises when a player does not satisfy one configured slot.
  let slot = config.slotConfig(slotIndex)
  if slot.name.len > 0 and address != slot.name:
    raise newException(
      CtfError,
      "Player name does not match configured slot " & $slotIndex & "."
    )
  if slot.token.len > 0 and token != slot.token:
    raise newException(
      CtfError,
      "Player token does not match configured slot " & $slotIndex & "."
    )

proc configuredPlayerName*(config: GameConfig, requestedSlot: int, token: string): string =
  ## Returns the configured identity for a tokenized slot request.
  if token.len == 0:
    return ""
  if requestedSlot >= 0 and requestedSlot < config.slots.len:
    let slot = config.slots[requestedSlot]
    if slot.name.len > 0 and slot.token.len > 0 and slot.token == token:
      return slot.name
    return ""
  for slot in config.slots:
    if slot.name.len > 0 and slot.token.len > 0 and slot.token == token:
      return slot.name
  ""

proc playerJoinAllowed*(
  config: GameConfig,
  address: string,
  requestedSlot: int,
  token: string
): bool =
  ## Returns whether a player websocket request can pass configured slot auth.
  if requestedSlot >= config.playerSlotLimit():
    return false
  if token.len > 0 and config.hasConfiguredTokens() and
      not config.hasConfiguredToken(token):
    return false
  if requestedSlot >= 0:
    return config.slotAuthMatches(requestedSlot, address, token)
  for i in 0 ..< config.slots.len:
    let slot = config.slots[i]
    let matchedName = slot.name.len > 0 and slot.name == address
    let matchedToken =
      slot.token.len > 0 and token.len > 0 and slot.token == token
    if matchedName or matchedToken:
      return config.slotAuthMatches(i, address, token)
  not config.closedRoster

proc slotOccupied(sim: SimServer, slotIndex: int): bool =
  ## Returns true when a player already owns a slot.
  for player in sim.players:
    if player.joinOrder == slotIndex:
      return true
  false

proc matchingConfiguredSlot(
  sim: SimServer,
  address,
  token: string
): int =
  ## Returns a matching configured slot for a player or -1.
  for i in 0 ..< sim.config.slots.len:
    if sim.slotOccupied(i):
      continue
    let slot = sim.config.slots[i]
    let couldMatchName = slot.name.len > 0 and slot.name == address
    let couldMatchToken = slot.token.len > 0 and slot.token == token
    if (couldMatchName or couldMatchToken) and
        sim.config.slotAuthMatches(i, address, token):
      return i
  -1

proc conflictingConfiguredSlot(
  sim: SimServer,
  address,
  token: string
): int =
  ## Returns a configured slot matched by name or token but not both.
  for i in 0 ..< sim.config.slots.len:
    if sim.slotOccupied(i):
      continue
    let slot = sim.config.slots[i]
    let matchedName = slot.name.len > 0 and slot.name == address
    let matchedToken =
      slot.token.len > 0 and token.len > 0 and slot.token == token
    if (matchedName or matchedToken) and
        not sim.config.slotAuthMatches(i, address, token):
      return i
  -1

proc namedConfiguredSlot(sim: SimServer, address: string): int =
  ## Returns an open configured slot with a matching name.
  for i in 0 ..< sim.config.slots.len:
    if sim.slotOccupied(i):
      continue
    let slot = sim.config.slots[i]
    if slot.name.len > 0 and slot.name == address:
      return i
  -1

proc nextAutoSlot(sim: SimServer, address, token: string): int =
  ## Returns the next open unrestricted or matching slot.
  let slotLimit = sim.config.playerSlotLimit()
  for i in sim.nextJoinOrder ..< slotLimit:
    if sim.slotOccupied(i):
      continue
    if not sim.config.slotRestricted(i) or
        sim.config.slotAuthMatches(i, address, token):
      return i
  for i in 0 ..< sim.nextJoinOrder:
    if i >= slotLimit:
      break
    if sim.slotOccupied(i):
      continue
    if not sim.config.slotRestricted(i) or
        sim.config.slotAuthMatches(i, address, token):
      return i
  -1

proc advanceJoinOrder(sim: var SimServer) =
  ## Moves the auto-slot cursor to the next open slot.
  while sim.nextJoinOrder < MaxPlayers and
      sim.slotOccupied(sim.nextJoinOrder):
    inc sim.nextJoinOrder

proc resolvePlayerSlot*(
  sim: SimServer,
  address,
  token: string,
  requestedSlot: int
): int =
  ## Returns the slot a player should use or raises on rejection.
  if requestedSlot >= MaxPlayers:
    raise newException(
      CtfError,
      "Player slot must be between 0 and 7."
    )
  if token.len > 0 and sim.config.hasConfiguredTokens() and
      not sim.config.hasConfiguredToken(token):
    raise newException(CtfError, "Player token is not configured.")
  if requestedSlot >= 0:
    if requestedSlot >= sim.config.playerSlotLimit():
      raise newException(CtfError, "Player slot is outside configured roster.")
    if sim.slotOccupied(requestedSlot):
      raise newException(
        CtfError,
        "Player slot " & $requestedSlot & " is already occupied."
      )
    sim.config.validatePlayerSlot(requestedSlot, address, token)
    return requestedSlot
  result = sim.matchingConfiguredSlot(address, token)
  if result >= 0:
    return result
  let conflict = sim.conflictingConfiguredSlot(address, token)
  if conflict >= 0:
    raise newException(
      CtfError,
      "Player credentials do not match configured slot " & $conflict & "."
    )
  result = sim.nextAutoSlot(address, token)
  if result < 0:
    raise newException(CtfError, "No available player slot.")

proc nextPlayerSlot*(sim: SimServer): int =
  ## Returns the slot required for the next live player index.
  sim.players.len

proc resolveTrustedPlayerSlot(
  sim: SimServer,
  address: string,
  requestedSlot: int
): int =
  ## Returns a trusted replay slot without requiring the original token.
  if requestedSlot >= MaxPlayers:
    raise newException(
      CtfError,
      "Player slot must be between 0 and 7."
    )
  if requestedSlot >= 0:
    if requestedSlot >= sim.config.playerSlotLimit():
      raise newException(CtfError, "Player slot is outside configured roster.")
    if sim.slotOccupied(requestedSlot):
      raise newException(
        CtfError,
        "Player slot " & $requestedSlot & " is already occupied."
      )
    return requestedSlot
  result = sim.namedConfiguredSlot(address)
  if result >= 0:
    return result
  result = sim.nextAutoSlot(address, "")
  if result < 0:
    raise newException(CtfError, "No available player slot.")

proc rewardAccountIndex(sim: SimServer, address: string): int =
  ## Returns the reward account index for an address.
  for i in 0 ..< sim.rewardAccounts.len:
    if sim.rewardAccounts[i].address == address:
      return i
  -1

proc ensureRewardAccount(sim: var SimServer, address: string): int =
  ## Returns the reward account index, creating the account if needed.
  result = sim.rewardAccountIndex(address)
  if result < 0:
    sim.rewardAccounts.add RewardAccount(
      address: address,
      slotIndex: -1,
      reward: 0
    )
    result = sim.rewardAccounts.high

proc bindRewardAccountSlot(
  sim: var SimServer,
  accountIndex,
  slotIndex: int
) =
  ## Binds a reward account to the stable player slot for this match.
  if accountIndex < 0 or accountIndex >= sim.rewardAccounts.len:
    return
  for i in 0 ..< sim.rewardAccounts.len:
    if i != accountIndex and sim.rewardAccounts[i].slotIndex == slotIndex:
      sim.rewardAccounts[i].slotIndex = -1
  sim.rewardAccounts[accountIndex].slotIndex = slotIndex

proc rewardAccountIndexForSlot*(sim: SimServer, slotIndex: int): int =
  ## Returns the newest reward account index for a player slot.
  if slotIndex < 0 or sim.rewardAccounts.len == 0:
    return -1
  for i in countdown(sim.rewardAccounts.high, 0):
    if sim.rewardAccounts[i].slotIndex == slotIndex:
      return i
  -1

proc playerIndexForSlot*(sim: SimServer, slotIndex: int): int =
  ## Returns the live player index for a player slot.
  for i in 0 ..< sim.players.len:
    if sim.players[i].joinOrder == slotIndex:
      return i
  -1

proc legacyGrenadeThrowerIndex*(
  sim: SimServer,
  grenade: AirborneGrenade
): int {.inline.} =
  ## Retains GV24's mutable-index kill counter solely because player.kills is
  ## hashed. Attribution and results use throwerSlot/throwerAccount instead.
  if grenade.thrower >= 0 and grenade.thrower < sim.players.len:
    grenade.thrower
  else:
    -1

proc playerResultSlotCount(sim: SimServer): int =
  ## Returns the number of player slots represented in final results.
  result = sim.config.slots.len
  if sim.config.closedRoster:
    return
  for player in sim.players:
    result = max(result, player.joinOrder + 1)
  for account in sim.rewardAccounts:
    if account.slotIndex >= 0:
      result = max(result, account.slotIndex + 1)

proc playerAddressOccupied*(sim: SimServer, address: string): bool =
  ## Returns true when a player identity is already connected.
  for player in sim.players:
    if player.address == address:
      return true
  false

proc removePlayerAt*(sim: var SimServer, playerIndex: int) =
  ## Removes one live player and keeps index-keyed state aligned.
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return
  for team in sim.teams():
    if sim.flags[team].carrier == playerIndex:
      sim.logGameEvent(teamText(team) & " heart returned home")
      sim.resetFlag(team)
    elif sim.flags[team].carrier > playerIndex:
      dec sim.flags[team].carrier
  sim.players.delete(playerIndex)
  if playerIndex < sim.fovCaches.len:
    sim.fovCaches.delete(playerIndex)

proc addPlayer*(
  sim: var SimServer,
  address: string,
  requestedSlot = -1,
  token = "",
  trusted = false
): int =
  ## Adds one player, optionally validating and using a requested slot.
  if not sim.canAddPlayer():
    raise newException(CtfError, sim.config.playerLimitError())
  if sim.playerAddressOccupied(address):
    raise newException(
      CtfError,
      "Player name is already connected."
    )
  let
    order =
      if trusted:
        sim.resolveTrustedPlayerSlot(address, requestedSlot)
      else:
        sim.resolvePlayerSlot(address, token, requestedSlot)
    nextSlot = sim.nextPlayerSlot()
  if not trusted and order != nextSlot:
    raise newException(
      CtfError,
      "Player slot " & $order & " cannot join before slot " &
        $nextSlot & "."
    )
  let
    slot = sim.config.slotConfig(order)
    team = sim.teamForSlot(order)
    color =
      if slot.hasColor:
        slot.color
      else:
        teamColor(team)
    accountIndex = sim.ensureRewardAccount(address)
    perks = sim.perkSetForJoin(team, address)
  let spawn = sim.spawnPosition(team, order div sim.gameMap.teamCount())
  sim.bindRewardAccountSlot(accountIndex, order)
  sim.rewardAccounts[accountIndex].hasTeam = false
  sim.rewardAccounts[accountIndex].won = false
  sim.rewardAccounts[accountIndex].abandoned = false
  sim.players.add Player(
    x: spawn.x,
    y: spawn.y,
    homeX: spawn.x,
    homeY: spawn.y,
    aimBrads: sim.gameMap.spawnAimBrads(team),
    flipH: sim.gameMap.spawnFlipH(team),
    windupBrads: -1,
    arcAimBrads: -1,
    team: team,
    alive: true,
    lives: sim.config.livesFor(team),
    hp: sim.config.maxHpFor(team, perks),
    perks: perks,
    joinOrder: order,
    address: address,
    color: color,
    skin: slot.skin,
    lastShoutTick: -1,
    paintHitTick: -1,
    reward: sim.rewardAccounts[accountIndex].reward
  )
  sim.fovCaches.add PlayerFov(
    valid: false,
    visible: newSeq[bool](FovCellCount)
  )
  sim.advanceJoinOrder()
  sim.arrangeHomePositions()
  sim.players.high

proc addReward*(sim: var SimServer, playerIndex, amount: int) =
  ## Adds accumulated reward to a player and its address account.
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return
  let address = sim.players[playerIndex].address
  let index = sim.ensureRewardAccount(address)
  sim.bindRewardAccountSlot(index, sim.players[playerIndex].joinOrder)
  sim.rewardAccounts[index].reward += amount
  sim.players[playerIndex].reward = sim.rewardAccounts[index].reward

proc rewardAccountForPlayer*(
  sim: var SimServer,
  playerIndex: int
): int =
  ## Returns the reward account index for a player, creating it if missing.
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return -1
  let address = sim.players[playerIndex].address
  result = sim.ensureRewardAccount(address)
  sim.bindRewardAccountSlot(result, sim.players[playerIndex].joinOrder)

proc recordGameTeamAssigned*(
  sim: var SimServer,
  playerIndex: int
) =
  ## Records the team assignment for one player at game start.
  let index = sim.rewardAccountForPlayer(playerIndex)
  if index < 0:
    return
  sim.rewardAccounts[index].team = sim.players[playerIndex].team
  sim.rewardAccounts[index].hasTeam = true
  sim.rewardAccounts[index].won = false
  sim.rewardAccounts[index].abandoned = false
  inc sim.rewardAccounts[index].games[sim.players[playerIndex].team]

proc recordGameAbandon*(sim: var SimServer, playerIndex: int) =
  ## Marks a player as abandoned for the current game.
  let index = sim.rewardAccountForPlayer(playerIndex)
  if index < 0:
    return
  sim.rewardAccounts[index].abandoned = true

proc recordGameWin*(sim: var SimServer, playerIndex: int) =
  ## Increments the lifetime per-team win counter for one player.
  let index = sim.rewardAccountForPlayer(playerIndex)
  if index < 0:
    return
  sim.rewardAccounts[index].won = true
  inc sim.rewardAccounts[index].wins[sim.players[playerIndex].team]

proc recordKill*(sim: var SimServer, playerIndex: int) =
  ## Increments the kill counter for one player.
  let index = sim.rewardAccountForPlayer(playerIndex)
  if index >= 0:
    inc sim.rewardAccounts[index].kills
  inc sim.players[playerIndex].kills

proc recordTeamKill*(sim: var SimServer, killerIndex, victimIndex: int) =
  ## Counts a teammate kill (the endscreen "backstab" badge). Weapon-agnostic:
  ## bullets, grenade blasts, and spray cones all land here.
  if killerIndex < 0 or killerIndex >= sim.players.len:
    return
  if victimIndex < 0 or victimIndex >= sim.players.len:
    return
  if killerIndex == victimIndex:
    return
  if sim.players[killerIndex].team == sim.players[victimIndex].team:
    inc sim.players[killerIndex].teamKills

proc recordDeath*(sim: var SimServer, playerIndex: int) =
  ## Increments the death counter for one player.
  let index = sim.rewardAccountForPlayer(playerIndex)
  if index >= 0:
    inc sim.rewardAccounts[index].deaths
  inc sim.players[playerIndex].deaths

proc recordCapture*(sim: var SimServer, playerIndex: int) =
  ## Increments the capture counter for one player.
  let index = sim.rewardAccountForPlayer(playerIndex)
  if index >= 0:
    inc sim.rewardAccounts[index].captures
  inc sim.players[playerIndex].captures

proc playerResultsJson*(sim: SimServer): string =
  ## Returns final player rewards and win states as JSON.
  var
    resultSlots: seq[int] = @[]
    names = newJArray()
    scores = newJArray()
    win = newJArray()
    teamList = newJArray()
    killsList = newJArray()
    deathsList = newJArray()
    capturesList = newJArray()
    shotsFiredList = newJArray()
    shotsHitList = newJArray()
    results = newJObject()
  for slotIndex in 0 ..< sim.playerResultSlotCount():
    resultSlots.add(slotIndex)
  for slotIndex in resultSlots:
    let
      playerIndex = sim.playerIndexForSlot(slotIndex)
      accountIndex =
        if playerIndex >= 0:
          sim.rewardAccountIndex(sim.players[playerIndex].address)
        else:
          sim.rewardAccountIndexForSlot(slotIndex)
      slotConfig = sim.config.slotConfig(slotIndex)
    var
      name =
        if slotConfig.name.len > 0:
          slotConfig.name
        else:
          "player-" & $slotIndex
      reward = 0
      playerTeam = Red
      hasTeam = false
      playerWon = false
      kills = 0
      deaths = 0
      captures = 0
      shotsFired = 0
      shotsHit = 0
    if accountIndex >= 0:
      let account = sim.rewardAccounts[accountIndex]
      name = account.address
      reward = account.reward
      playerTeam = account.team
      hasTeam = account.hasTeam
      playerWon = account.won
      kills = account.kills
      deaths = account.deaths
      captures = account.captures
    if playerIndex >= 0:
      let player = sim.players[playerIndex]
      name = player.address
      if accountIndex < 0:
        reward = player.reward
      playerTeam = player.team
      hasTeam = true
      playerWon = not sim.isDraw and player.team == sim.winner
      # Accuracy counters live only on the player (analysis-only, never
      # mirrored into reward accounts): a slot whose player left reports 0.
      shotsFired = player.shotsFired
      shotsHit = player.shotsHit
    if not hasTeam and slotConfig.hasTeam:
      playerTeam = slotConfig.team
      hasTeam = true
    names.add(%name)
    scores.add(%reward)
    win.add(%playerWon)
    teamList.add(%(if hasTeam: teamText(playerTeam) else: "unknown"))
    killsList.add(%kills)
    deathsList.add(%deaths)
    capturesList.add(%captures)
    shotsFiredList.add(%shotsFired)
    shotsHitList.add(%shotsHit)
  results["names"] = names
  results["scores"] = scores
  results["win"] = win
  results["team"] = teamList
  results["kills"] = killsList
  results["deaths"] = deathsList
  results["captures"] = capturesList
  # shotsFired/shotsHit stay OUT of the results payload: the platform's
  # episode-results schema is closed (additionalProperties: false) and the
  # certifier rejects unknown fields, blocking every canonical upload. The
  # counters remain on the players for replay-side analysis; re-add here
  # only after the platform schema learns the fields.
  $results

