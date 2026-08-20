#!/bin/bash
# Records one 32-player 4-team CTF episode on a generated "colossal" map
# (5.2x scale — 2x giant): 32 seats dealt round the four teams (slot mod 4,
# 8 per team), each seat a baseline bot. Demo tooling for the oversize
# experiment; mirrors record_four_team_demo.sh.
# Usage: tools/record_colossal_demo.sh <out.bitreplay RELATIVE to repo root> <seed> [maxTicks] [speed]
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$1"; SEED="$2"; MAXTICKS="${3:-5000}"; SPEED="${4:-16}"; PORT="${PORT:-21300}"
CFG=$(mktemp /tmp/ctf-colossal-demo-cfg-$$-XXXXXX)
python3 - "$CFG" "$SEED" "$MAXTICKS" "$SPEED" <<'PY'
import json, sys
cfg = json.load(open("config.json"))
cfg["gameMode"] = "ctf"
cfg["lives"] = 3
cfg["fireCooldownTicks"] = 12
cfg["carrierSpeedPct"] = 70
cfg["seed"] = int(sys.argv[2])
cfg["maxTicks"] = int(sys.argv[3])
cfg["speed"] = int(sys.argv[4])
cfg["maxGames"] = 1
cfg["teams"] = 4
cfg["mapPath"] = "gen"
cfg["mapSeed"] = int(sys.argv[2])
cfg["mapSize"] = "colossal"
cfg["minPlayers"] = 32
cfg.pop("slots", None)
cfg["tokens"] = [f"0xBADA55_{i}" for i in range(32)]
# Hosted-style seat names: one policy per team, seated eight times each.
pols = ["redshift:v1", "bluesteel:v1", "greenhorn:v1", "goldrush:v1"]
counts = [0, 0, 0, 0]
players = []
for slot in range(32):
    team = slot % 4
    counts[team] += 1
    players.append({"name": f"{pols[team]}_({counts[team]})"})
cfg["players"] = players
json.dump(cfg, open(sys.argv[1], "w"))
PY
LOG="${LOG:-/tmp/ctf-colossal-demo-server.log}"
BOTLOG="${BOTLOG:-/tmp/ctf-colossal-demo-bots.log}"
COGAME_HOST=127.0.0.1 COGAME_PORT=$PORT \
COGAME_CONFIG_URI="file://$CFG" \
COGAME_SAVE_REPLAY_URI="file://$PWD/$OUT" \
./bin/ctf-server > "$LOG" 2>&1 &
SERVER_PID=$!

# Wait for the port to listen before spawning bots (map generation at this
# scale takes a while — allow several minutes).
for i in $(seq 1 2400); do
  nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
  if ! kill -0 $SERVER_PID 2>/dev/null; then
    echo "server died during startup; log tail:" >&2
    tail -20 "$LOG" >&2
    exit 1
  fi
  sleep 0.5
done
nc -z 127.0.0.1 "$PORT" || { echo "server never listened" >&2; tail -20 "$LOG" >&2; exit 1; }

BOT_PIDS=()
for i in $(seq 0 31); do
  CTF_BOT_FAST_READY=1 \
  COWORLD_PLAYER_WS_URL="ws://127.0.0.1:$PORT/player?slot=$i&token=0xBADA55_$i" \
    ./players/baseline/baseline.out >> "$BOTLOG" 2>&1 &
  BOT_PIDS+=($!)
done

# Bounded wait — a hang must be loud, not silent.
DEADLINE=$((SECONDS + 1800))
while kill -0 $SERVER_PID 2>/dev/null; do
  if [ $SECONDS -ge $DEADLINE ]; then
    echo "server still running after 30 minutes — killing; log tails:" >&2
    tail -20 "$LOG" >&2
    tail -10 "$BOTLOG" >&2
    kill $SERVER_PID 2>/dev/null || true
    for p in "${BOT_PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
    exit 1
  fi
  sleep 2
done
if ! wait $SERVER_PID; then
  echo "server exited non-zero; log tail:" >&2
  tail -20 "$LOG" >&2
fi
for p in "${BOT_PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
rm -f "$CFG"
SIZE=$(stat -f%z "$OUT" 2>/dev/null || echo 0)
if [ "$SIZE" -lt 10000 ]; then
  echo "replay missing or truncated ($SIZE bytes); server log tail:" >&2
  tail -20 "$LOG" >&2
  exit 1
fi
ls -la "$OUT"
