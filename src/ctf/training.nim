## Fixed numeric view of Emerg-ant state for headless training. Every field is
## derived from information available to that seat's Sprite v1 player stream.
import sim

const
  AntObservationFeatures* = 18 + AntFoodPatchCount * 3 + 32 * 5 +
    11 * 11 + 2 * 4 * 4

proc antObservation*(sim: var SimServer, seat: int): seq[float32] =
  doAssert sim.config.isEmergAnt()
  doAssert sim.phase in {Playing, GameOver}
  doAssert seat in 0 ..< sim.players.len
  let player = sim.players[seat]
  if player.alive:
    discard sim.refreshPlayerFov(seat)
  let
    mapWidth = float32(MapWidth)
    mapHeight = float32(MapHeight)
    cx = player.x + CollisionW div 2
    cy = player.y + CollisionH div 2
    home = sim.gameMap.flagHome(player.team)
    enemy = sim.gameMap.flagHome(if player.team == Red: Blue else: Red)
  var carrying = false
  for slot in sim.objectiveSlots():
    if sim.objectiveState(slot).carrier == seat:
      carrying = true
  result = @[
    float32(ord(player.alive)), float32(ord(sim.isQueen(seat))),
    float32(cx) / mapWidth, float32(cy) / mapHeight,
    float32(player.hp) / float32(sim.config.hitPoints),
    float32(player.aimBrads) / 255,
    float32(player.fireCooldown) / 60,
    float32(ord(carrying)),
    float32(ord(player.pheromoneKind)) / 3,
    float32(player.pheromoneRate) / 3,
    float32(sim.teamForageScore(player.team)) / float32(sim.config.forageGoal),
    float32(sim.teamForageScore(if player.team == Red: Blue else: Red)) /
      float32(sim.config.forageGoal),
    float32(sim.gameTicksElapsed()) / float32(sim.config.maxTicks),
    float32(ord(player.team)),
    float32(home.x - cx) / mapWidth, float32(home.y - cy) / mapHeight,
    float32(enemy.x - cx) / mapWidth, float32(enemy.y - cy) / mapHeight
  ]
  for slot in sim.objectiveSlots():
    let food = sim.objectiveState(slot)
    let visible = player.alive and sim.flagVisibleTo(seat, slot)
    result.add(float32(ord(visible)))
    result.add(if visible: float32(food.x - cx) / mapWidth else: 0'f32)
    result.add(if visible: float32(food.y - cy) / mapHeight else: 0'f32)
  for otherSeat in 0 ..< 32:
    let visible = otherSeat < sim.players.len and
      sim.players[otherSeat].alive and
      (otherSeat == seat or (player.alive and sim.playerVisibleTo(seat, otherSeat)))
    result.add(float32(ord(visible)))
    if visible:
      let other = sim.players[otherSeat]
      result.add(float32(other.x + CollisionW div 2 - cx) / mapWidth)
      result.add(float32(other.y + CollisionH div 2 - cy) / mapHeight)
      result.add(float32(ord(other.team == player.team)))
      result.add(float32(ord(sim.isQueen(otherSeat))))
    else:
      result.add([0'f32, 0'f32, 0'f32, 0'f32])
  for dy in -5 .. 5:
    for dx in -5 .. 5:
      let
        x = cx + dx * FovCellSize
        y = cy + dy * FovCellSize
      result.add(if x in 0 ..< MapWidth and y in 0 ..< MapHeight and
        sim.walkMask[y * MapWidth + x]: 1'f32 else: 0'f32)
  var trail: array[2 * 4 * 4, float32]
  for mark in sim.pheromones:
    let
      dx = mark.x - cx
      dy = mark.y - cy
    if abs(dx) > 96 or abs(dy) > 96:
      continue
    let quadrant = ord(dx >= 0) + 2 * ord(dy >= 0)
    let index = (ord(mark.team) * 4 + ord(mark.kind)) * 4 + quadrant
    trail[index] = min(1'f32, trail[index] + 0.25'f32)
  for value in trail:
    result.add(value)
  doAssert result.len == AntObservationFeatures
