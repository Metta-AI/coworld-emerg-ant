## Measures the gap between where the spray cone DAMAGES and where the spray
## animation PAINTS, using the real sim and the real FX geometry.
##
## Damage side: place a victim at a grid of offsets from the attacker, fire the
## can, and read the hp that actually came off (sim.tryFireArc, no mocking).
## Paint side: the exported FX slot procs (plasmaPulseForward/plasmaPulseRight)
## plus the puff diameter rule, giving the outermost painted pixel.
##
## Usage (from the repo root): nim r tools/spray_gap_probe.nim
import
  std/strformat,
  ../src/ctf/global, ../src/ctf/sim,
  toolutil

proc twoTeamGame(): SimServer =
  chdirGameDir()
  result = initSimServer(defaultGameConfig())
  result.gameEventLoggingEnabled = false
  discard result.addPlayer("red0")
  discard result.addPlayer("blue0")
  result.startGame()
  result.players[0].team = Red
  result.players[1].team = Blue

proc placeAtCenter(player: var Player, x, y: int) =
  player.x = x - CollisionW div 2
  player.y = y - CollisionH div 2

proc damages(game: var SimServer, dx, dy: int): bool =
  ## Fires one burst at a victim `dx` forward / `dy` sideways of the attacker
  ## and reports whether any hp actually came off.
  game.players[0].hasPlasmaArc = true
  game.players[0].aimBrads = 0
  game.players[0].fireCooldown = 0
  game.players[0].arcTicksLeft = 0
  game.players[0].placeAtCenter(60, MapHeight div 2)
  let
    ax = game.players[0].x + CollisionW div 2
    ay = game.players[0].y + CollisionH div 2
  game.players[1].alive = true
  game.players[1].respawnTimer = 0
  game.players[1].hp = 99
  game.players[1].placeAtCenter(ax + dx, ay + dy)
  game.tryFireArc(0)
  game.players[1].hp < 99

proc main() =
  var game = twoTeamGame()

  echo "=== DAMAGE (real sim): forward sweep on the aim axis ==="
  var lastHit = -1
  for d in countup(100, 220, 2):
    if game.damages(d, 0):
      lastHit = d
    elif lastHit >= 0:
      echo &"  hp comes off out to {lastHit}px; first miss at {d}px " &
        &"(PlasmaArcReach = {PlasmaArcReach})"
      break

  echo "\n=== DAMAGE (real sim): lateral sweep, half-width by distance ==="
  for d in [40, 80, 120, 134]:
    var lastSide = -1
    for s in countup(0, 80, 1):
      if game.damages(d, s): lastSide = s else: break
    echo &"  forward {d:3}px -> hp comes off out to {lastSide:3}px sideways"

  # A cog is PAINTED when the plume touches its body, and DAMAGED when its
  # center is inside the cone. Both are measured against the same body radius,
  # so it CANCELS: the honest comparison is the plume's own outermost pixel
  # against the bare cone. (Adding the body to only one side is the mistake
  # that made this weapon's overdraw look contained when it was not.)
  echo "\n=== PAINT vs CONE: does anything painted escape damage? ==="
  let slope = float(PlasmaArcMaxWidth) / (2.0 * float(PlasmaArcReach))
  var
    tip = 0.0
    worstLateral = -1e9
    worstAt = 0.0
  for stage in 0 ..< PlasmaArcFxStages:
    for pulse in 0 ..< PlasmaArcFxPulses:
      let
        f = float(plasmaPulseForward(pulse, stage))
        w = abs(float(plasmaPulseRight(pulse, stage)))
        r = float(plasmaPulseDiameter(pulse, stage)) / 2
      tip = max(tip, f + r)
      if (w + r) - slope * f > worstLateral:
        worstLateral = (w + r) - slope * f
        worstAt = f
  echo &"  forward: paint tip {tip:.1f}px vs cone reach {PlasmaArcReach}px"
  if tip <= float(PlasmaArcReach):
    echo &"    CONTAINED with {float(PlasmaArcReach) - tip:.1f}px to spare — " &
      "nothing the paint engulfs walks away clean"
  else:
    echo &"    OVERDRAW {tip - float(PlasmaArcReach):.1f}px: a cog centered up to " &
      &"{tip + float(PlasmaArcBodyRadius):.1f}px out is painted but unhurt"
  echo &"  lateral: worst overdraw {worstLateral:.1f}px (at {int(worstAt)}px forward)"
  if worstLateral > 0:
    echo "    an EDGE GRAZE only: the mist is drawn oversize so its puffs " &
      "merge, so it runs wider than the cone that sizes them"

main()
