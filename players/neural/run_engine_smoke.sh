#!/bin/bash
## Run the real 32-seat engine with independently selectable team policies.
set -euo pipefail

cd "$(dirname "$0")/../.."
OUT="${1:-build/neural-engine-smoke.replay}"
RED_POLICY="${2:-neural}"
BLUE_POLICY="${3:-neural}"
PORT="${PORT:-21819}"
MAX_TICKS="${MAX_TICKS:-1200}"
WASH_TICK="${WASH_TICK:-500}"
SEED="${SEED:-}"

case "$RED_POLICY:$BLUE_POLICY" in
  neural:neural|neural:heuristic|heuristic:neural|heuristic:heuristic) ;;
  *) echo "policies must be neural or heuristic" >&2; exit 2 ;;
esac

mkdir -p "$(dirname "$OUT")"
OUT="$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"
CFG=$(mktemp /tmp/emerg-ant-neural-XXXXXX)
LOG="$OUT.log"
SERVER_PID=""
BOT_PIDS=()

cleanup() {
  [ -z "$SERVER_PID" ] || kill "$SERVER_PID" 2>/dev/null || true
  for pid in "${BOT_PIDS[@]}"; do kill "$pid" 2>/dev/null || true; done
  rm -f "$CFG"
}
trap cleanup EXIT

python3 - "$CFG" "$MAX_TICKS" "$WASH_TICK" "$SEED" <<'PY'
import json, sys
config = json.load(open("config.json"))
config.update({
    "forageGoal": 1,
    "maxTicks": int(sys.argv[2]),
    "pheromoneWashTick": int(sys.argv[3]),
    "speed": 16,
    "startWaitTicks": 0,
    "gameOverTicks": 1,
    "maxGames": 1,
    "lobbyJoinTimeoutTicks": 1000,
})
if sys.argv[4]:
    config["seed"] = int(sys.argv[4])
json.dump(config, open(sys.argv[1], "w"))
PY

nim c -d:release --out:bin/ctf-server src/ctf.nim
nim c -d:release --opt:speed --out:players/baseline/baseline.out \
  players/baseline/baseline.nim

COGAME_HOST=127.0.0.1 COGAME_PORT="$PORT" \
COGAME_CONFIG_URI="file://$CFG" COGAME_SAVE_REPLAY_URI="file://$OUT" \
  ./bin/ctf-server >"$LOG" 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 40); do
  nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
  kill -0 "$SERVER_PID" 2>/dev/null || { tail -30 "$LOG"; exit 1; }
  sleep 0.25
done
nc -z 127.0.0.1 "$PORT" || { tail -30 "$LOG"; exit 1; }

for slot in $(seq 0 31); do
  if [ $((slot % 2)) -eq 0 ]; then POLICY="$RED_POLICY"; else POLICY="$BLUE_POLICY"; fi
  EMERG_ANT_POLICY="$POLICY" CTF_BOT_FAST_READY=1 \
  COWORLD_PLAYER_WS_URL="ws://127.0.0.1:$PORT/player?slot=$slot&token=0xBADA55_$slot" \
    ./players/baseline/baseline.out >/dev/null 2>&1 &
  BOT_PIDS+=($!)
done

DEADLINE=$((SECONDS + 180))
while kill -0 "$SERVER_PID" 2>/dev/null; do
  [ "$SECONDS" -lt "$DEADLINE" ] || { echo "engine smoke timed out" >&2; exit 1; }
  sleep 1
done
wait "$SERVER_PID"
SERVER_PID=""
test -s "$OUT"
grep -E "harvested neutral food|delivered neutral food|rain washed|red win|blue win|draw" "$LOG" || true
ls -lh "$OUT" "$LOG"
