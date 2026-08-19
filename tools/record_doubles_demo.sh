#!/bin/bash
# Records one CTF episode seated like a CTF-Doubles league round: 4 policies,
# 2 per team (slots A,B,A,B,A,B,A,B,C,D,C,D,C,D,C,D — Red = A+C, Blue = B+D),
# with hosted-style " (N)" per-connection name suffixes. Demo fixture for the
# multi-team replay viewer.
# Usage: tools/record_doubles_demo.sh <out.bitreplay> <seed> [maxTicks]
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$1"; SEED="$2"; MAXTICKS="${3:-5000}"; PORT="${PORT:-21100}"
CFG=$(mktemp /tmp/ctf-doubles-demo-cfg-$$-XXXXXX)
python3 - "$CFG" "$SEED" "$MAXTICKS" <<'PY'
import json, sys
cfg = json.load(open("config.json"))
cfg["seed"] = int(sys.argv[2])
cfg["maxTicks"] = int(sys.argv[3])
cfg["speed"] = 16
cfg["maxGames"] = 1
# Doubles-style roster names: front half alternates policies A,B; back half
# C,D (Red = A+C, Blue = B+D by slot parity), with the hosted-style per-seat
# suffix in its on-the-wire underscore form. The server assigns each slot its
# configured name, so the bots connect with slot+token only.
pols = {"A": "ctf-focusfire:v62", "B": "beacon:v33",
        "C": "osprey:v3", "D": "picasso:v9"}
counts = {k: 0 for k in pols}
players = []
for slot in range(16):
    key = ("A" if slot % 2 == 0 else "B") if slot < 8 else \
          ("C" if slot % 2 == 0 else "D")
    counts[key] += 1
    players.append({"name": f"{pols[key]}_({counts[key]})"})
cfg["players"] = players
json.dump(cfg, open(sys.argv[1], "w"))
PY
LOG="${LOG:-/tmp/ctf-doubles-demo-server.log}"
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
for i in $(seq 0 15); do
  CTF_BOT_FAST_READY=1 \
  COWORLD_PLAYER_WS_URL="ws://127.0.0.1:$PORT/player?slot=$i&token=0xBADA55_$i" \
    ./players/baseline/baseline.out >/dev/null 2>&1 &
  BOT_PIDS+=($!)
done

# Bounded wait: hangs must be loud, not silent.
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
# A written replay under ~10KB is a truncated episode, not a demo.
SIZE=$(stat -f%z "$OUT" 2>/dev/null || stat -c%s "$OUT" 2>/dev/null || echo 0)
if [ "$SIZE" -lt 10000 ]; then
  echo "replay missing or truncated ($SIZE bytes); server log tail:" >&2
  tail -20 "$LOG" >&2
  exit 1
fi
ls -la "$OUT"
