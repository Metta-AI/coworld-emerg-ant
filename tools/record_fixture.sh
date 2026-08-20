#!/bin/bash
# Records one full-scale CTF episode as a .bitreplay fixture.
# Usage: tools/record_fixture.sh <out.bitreplay> <seed> [maxTicks] [extraConfigJson]
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$1"; SEED="$2"; MAXTICKS="${3:-10000}"; EXTRA="${4:-}"; PORT="${PORT:-21000}"
[ -z "$EXTRA" ] && EXTRA='{}'
CFG=$(mktemp /tmp/ctf-fixture-cfg-$$-XXXXXX)
python3 - "$CFG" "$SEED" "$MAXTICKS" "$EXTRA" <<'PY'
import json, sys
cfg = json.load(open("config.json"))
# This tool records the legacy CTF regression fixtures even when the checked-in
# launch config selects another mode (currently Emerg-ant). Pin every launch
# field that mode tuning changes so the documented recipes do not inherit it.
cfg["gameMode"] = "ctf"
cfg["lives"] = 3
cfg["fireCooldownTicks"] = 12
cfg["carrierSpeedPct"] = 70
cfg["minPlayers"] = 16
cfg["tokens"] = cfg["tokens"][:16]
cfg["slots"] = cfg["slots"][:16]
cfg["players"] = cfg["players"][:16]
cfg["seed"] = int(sys.argv[2])
cfg["maxTicks"] = int(sys.argv[3])
cfg["speed"] = 16
cfg["maxGames"] = 1
cfg.update(json.loads(sys.argv[4]))
json.dump(cfg, open(sys.argv[1], "w"))
PY
LOG="${LOG:-/tmp/ctf-fixture-server-$$.log}"
COGAME_HOST=127.0.0.1 COGAME_PORT=$PORT \
COGAME_CONFIG_URI="file://$CFG" \
COGAME_SAVE_REPLAY_URI="file://$PWD/$OUT" \
./bin/ctf-server > "$LOG" 2>&1 &
SERVER_PID=$!

# Wait for the port to actually listen before spawning bots — a slow start
# would otherwise strand the bots and hang the lobby forever, silently.
for i in $(seq 1 40); do
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
for i in ${SLOTS:-$(seq 0 15)}; do
  CTF_BOT_FAST_READY=1 \
  COWORLD_PLAYER_WS_URL="ws://127.0.0.1:$PORT/player?slot=$i&token=0xBADA55_$i" \
    ./players/baseline/baseline.out >/dev/null 2>&1 &
  BOT_PIDS+=($!)
done

# Bounded wait: at speed 16 even a full-length episode finishes in minutes;
# anything longer is a hang, and hangs must be loud, not silent.
DEADLINE=$((SECONDS + 600))
while kill -0 $SERVER_PID 2>/dev/null; do
  if [ $SECONDS -ge $DEADLINE ]; then
    echo "server still running after 10 minutes — killing; log tail:" >&2
    tail -20 "$LOG" >&2
    kill $SERVER_PID 2>/dev/null || true
    for p in "${BOT_PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
    exit 1
  fi
  sleep 2
done
wait $SERVER_PID || { echo "server exited non-zero; log tail:" >&2; tail -20 "$LOG" >&2; }
for p in "${BOT_PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
rm -f "$CFG"
# A written replay under ~10KB is a truncated episode, not a fixture.
SIZE=$(stat -f%z "$OUT" 2>/dev/null || stat -c%s "$OUT" 2>/dev/null || echo 0)
if [ "$SIZE" -lt 10000 ]; then
  echo "replay missing or truncated ($SIZE bytes); server log tail:" >&2
  tail -20 "$LOG" >&2
  exit 1
fi
ls -la "$OUT"
