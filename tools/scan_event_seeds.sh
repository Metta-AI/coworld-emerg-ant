#!/bin/bash
# Scans seeds for an event-substrate recording whose kill mix exercises all
# three weapons (gun, grenade, spray). Prints one line per seed; leaves the
# best candidate at tests/replays/ctf.bitreplay.
# Usage: tools/scan_event_seeds.sh <seed> [seed...]
set -uo pipefail
cd "$(dirname "$0")/.."
mkdir -p .scan
EXTRACTOR=./tools/extract_events.out
[ -x "$EXTRACTOR" ] || EXTRACTOR=./tools/extract_events
for SEED in "$@"; do
  # record_fixture.sh prefixes $PWD, so the output path must be repo-relative.
  REL=".scan/seed$SEED.bitreplay"
  OUT="$PWD/$REL"
  PORT=$((21000 + SEED % 500)) tools/record_fixture.sh \
    "$REL" "$SEED" 10000 '{"lives":9,"carrierSpeedPct":1}' >/dev/null 2>&1
  [ -s "$OUT" ] || { echo "seed $SEED: RECORD FAILED"; continue; }
  "$EXTRACTOR" "$OUT" --out "/tmp/ctf-events-seed$SEED.jsonl" \
    >/dev/null 2>&1 || { echo "seed $SEED: EXTRACT FAILED"; continue; }
  python3 - "$SEED" "/tmp/ctf-events-seed$SEED.jsonl" <<'PY'
import json, sys, collections
seed, path = sys.argv[1], sys.argv[2]
kills = collections.Counter()
kinds = collections.Counter()
for line in open(path):
    r = json.loads(line)
    k = r.get("kind")
    kinds[k] += 1
    if k == "kill":
        kills[r["weapon"]] += 1
weapons = sorted(kills)
ok = len(weapons) == 3
print(f"seed {seed}: kills={dict(kills)} steals={kinds['flag_steal']} "
      f"returns={kinds['flag_return']} heals={kinds['heal']} "
      f"captures={kinds['capture']} {'ALL THREE' if ok else ''}")
PY
done
