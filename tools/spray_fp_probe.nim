## Verifies the broadcast/FPV JSON contract for the SPRAY CAN: poses one seat
## holding a can and firing it into another, then prints the exact JSON the
## broadcast client reads — `self.items`, the tactical-map item tokens, and
## `self.paintTick`.
##
## The client's ITEM_LABEL table, the FPV item-billboard icon switch, and the
## minimap dot colors all key off these literal strings, so this is the
## machine-side half of the viewer check (the pixel half is tools/spray_probe.nim).
##
## Usage (from the repo root): nim r tools/spray_fp_probe.nim
import
  std/json,
  ../src/ctf/broadcast, ../src/ctf/sim,
  toolutil

proc fpFrame(sim: SimServer, povSlot: int): JsonNode =
  ## The `fp` node of a chrome frame for one POV slot (as the PiP tests do).
  let parsed = parseJson(sim.buildStateJson(
    events = newJArray(),
    playing = false,
    speed = 1,
    maxTick = 10000,
    looping = false,
    transportEnabled = true,
    mismatchTick = -1,
    povSlot = povSlot
  ))
  if parsed.hasKey("fp"): parsed["fp"] else: newJNull()

proc main() =
  chdirGameDir()
  var game = initSimServer(defaultGameConfig())
  game.gameEventLoggingEnabled = false
  let
    red = game.addPlayer("red0")
    blue = game.addPlayer("blue0")
  game.startGame()
  game.players[red].team = Red
  game.players[blue].team = Blue

  proc placeAt(i, x, y: int) =
    game.players[i].x = x - CollisionW div 2
    game.players[i].y = y - CollisionH div 2

  # RED holds a can and sprays BLUE 100px east (a pose with clear line of sight).
  let midY = MapHeight div 2
  placeAt(red, 300, midY - 90)
  placeAt(blue, 400, midY - 90)
  game.players[red].aimBrads = 0
  game.players[red].hasPlasmaArc = true
  game.players[red].fireCooldown = 0
  game.players[blue].hp = 3
  inc game.tickCount                     # so paintTick differs from the sentinel
  game.tryFireArc(red)

  let
    redFp = game.fpFrame(game.players[red].joinOrder)
    blueFp = game.fpFrame(game.players[blue].joinOrder)

  echo "RED holds a can → self.items = ", redFp["self"]["items"]
  echo "BLUE was sprayed → hp = ", blueFp["self"]["hp"],
    "   self.paintTick = ", blueFp["self"]["paintTick"],
    "   (tick ", game.tickCount, ")"

  var mapTokens = newJArray()
  for it in redFp["map"]["items"]:
    if it["item"].getStr() notin ["grenade", "medkit", "shield"]:
      mapTokens.add it["item"]
  echo "spray map item tokens = ", mapTokens

main()
