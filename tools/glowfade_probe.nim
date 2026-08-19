import std/strformat
import ../src/ctf/sim
import ../src/ctf/global
import toolutil

# Deterministic probe for the heart-taken endzone glow fade: drives
# buildSpriteProtocolUpdates with a team's flag carried vs home and reports how
# the per-team crossfade stage ramps toward dark and back to full glow.

chdirGameDir()

var config = defaultGameConfig()
var game = initSimServer(config)
game.gameEventLoggingEnabled = false

var state = initGlobalViewerState()

proc frame(g: var SimServer, st: var GlobalViewerState): string =
  var nxt: GlobalViewerState
  let packet = g.buildSpriteProtocolUpdates(
    st, nxt, replayTick = 0, replayEnabled = true, replayMaxTick = 100)
  st = nxt
  &"redStage={st.endzoneFade[Red]} blueStage={st.endzoneFade[Blue]} bytes={packet.len}"

echo "-- both home --"
game.flags[Red].carrier = -1
game.flags[Blue].carrier = -1
for i in 0 ..< 3:
  echo frame(game, state)

echo "-- Red heart taken (carrier=0): should ramp 0->max --"
game.flags[Red].carrier = 0
for i in 0 ..< (GlowFadeStages + 2):
  echo frame(game, state)

echo "-- Red heart returns home: should ramp back to 0 --"
game.flags[Red].carrier = -1
for i in 0 ..< (GlowFadeStages + 2):
  echo frame(game, state)

echo "-- Blue heart taken then home --"
game.flags[Blue].carrier = 3
for i in 0 ..< 3: echo frame(game, state)
game.flags[Blue].carrier = -1
for i in 0 ..< (GlowFadeStages + 1): echo frame(game, state)

echo "GlowFadeStages=", GlowFadeStages
echo "OK"
