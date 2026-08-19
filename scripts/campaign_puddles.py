#!/usr/bin/env python3
"""Patch a paint-puddle GRADIENT into the Paintbot campaign's pinned cell maps.

Puddles only place on 2-team maps (the sim refuses 4-team symmetries), so the
gradient lives in the two 2-team zones of the 10x10 board (see
gen_campaign_maps.py for the zone scheme): one origin cell per zone gets the
densest splat set and the count falls off by Chebyshev ring —

    origin (1,1) and (8,1):  12 puddles
    ring 1:                   8
    ring 2:                   4
    everywhere else:          0

which puddles exactly 32 of the 100 cells. Counts are even on purpose: an odd
request anchors a splat dead center, and the gradient reads better as scattered
pairs. Placement is deterministic per cell (seeded from the cell key), patched
into the EXISTING prod map_spec — base terrain stays byte-identical.

Usage (each step is idempotent; OUT holds the working specs):
    nim c -d:release -o:/tmp/mapkit tools/mapkit.nim
    export MAPKIT=/tmp/mapkit CAMPAIGN_PUDDLES_OUT=/tmp/campaign_puddles
    python3 scripts/campaign_puddles.py plan     # print the gradient board
    python3 scripts/campaign_puddles.py fetch    # pull prod cell map_specs
    python3 scripts/campaign_puddles.py patch    # place puddles + validate + render
    python3 scripts/campaign_puddles.py upload   # POST cell-map (spec + preview)
    python3 scripts/campaign_puddles.py verify   # count puddled cells on prod

fetch/upload/verify hit prod (softmax.com) and need the team token in
~/.softmax/credentials.yaml plus elevated-privileges team auth; a custom
User-Agent dodges Cloudflare's urllib block.
"""

import base64
import json
import math
import os
import subprocess
import sys
import urllib.request
import zlib
from pathlib import Path

MAPKIT = Path(os.environ.get("MAPKIT", "mapkit"))
OUT = Path(os.environ.get("CAMPAIGN_PUDDLES_OUT", "campaign_puddles"))
LEAGUE = "b8fa9b35-ac22-48cf-a03f-07b397aff1c7"
API = "https://softmax.com/api/observatory"

ANCHORS = {"1v1": (0.0, 0.0), "2v2": (9.0, 0.0), "ffa4": (4.5, 9.0)}
ORIGINS = [(1, 1), (8, 1)]  # one per 2-team zone
PEAK = 12
STEP = 4  # per Chebyshev ring


def mode_for(x: int, y: int) -> str:
    return min(ANCHORS, key=lambda m: math.dist((x, y), ANCHORS[m]))


def puddle_count(x: int, y: int) -> int:
    """The gradient: PEAK at an origin, minus STEP per Chebyshev ring, floored
    at 0 — and always 0 in the 4-team zone, whatever the distance says."""
    if mode_for(x, y) == "ffa4":
        return 0
    d = min(max(abs(x - ox), abs(y - oy)) for ox, oy in ORIGINS)
    return max(0, PEAK - STEP * d)


def puddle_seed(x: int, y: int) -> int:
    return zlib.crc32(f"paintbot-puddles:{x},{y}".encode()) % 100_000


def targets() -> list[tuple[int, int, int]]:
    return [
        (x, y, puddle_count(x, y))
        for y in range(10)
        for x in range(10)
        if puddle_count(x, y) > 0
    ]


def token() -> str:
    import yaml

    creds = yaml.safe_load(open(Path.home() / ".softmax/credentials.yaml"))
    return creds["tokens"]["https://softmax.com/api"]


def api_call(path: str, payload: dict) -> dict:
    req = urllib.request.Request(
        f"{API}{path}",
        data=json.dumps(payload).encode(),
        headers={
            "Authorization": f"Bearer {token()}",
            "X-Use-Elevated-Privileges": "true",
            "Content-Type": "application/json",
            # Cloudflare 403s urllib's default UA.
            "User-Agent": "coworld-ctf-campaign-puddles",
        },
    )
    with urllib.request.urlopen(req) as resp:
        return json.loads(resp.read())


def sql(query: str) -> list[list]:
    return api_call("/sql/query", {"query": query})["rows"]


def cmd_plan() -> None:
    print("puddle gradient (x right, y down; . = none):")
    for y in range(10):
        print("  " + " ".join(
            f"{puddle_count(x, y):2d}" if puddle_count(x, y) else " ."
            for x in range(10)
        ))
    cells = targets()
    print(f"{len(cells)} cells get puddles, "
          f"{sum(c for _, _, c in cells)} puddles requested in total")


def cmd_fetch() -> None:
    OUT.mkdir(exist_ok=True)
    keys = ", ".join(f"'{x},{y}'" for x, y, _ in targets())
    rows = sql(
        "SELECT key, value->>'map_ref', value->'map_spec' "
        "FROM leagues, jsonb_each(commissioner_state->'cells') AS c(key, value) "
        f"WHERE id = '{LEAGUE}' AND key IN ({keys})"
    )
    assert len(rows) == len(targets()), f"expected {len(targets())} cells, got {len(rows)}"
    for key, map_ref, spec in rows:
        # Every gradient cell must be a 2-team variant, or the patch would
        # refuse (and the gradient scheme drifted from the prod board).
        assert map_ref in ("1v1", "2v2"), f"cell {key} is {map_ref}, not 2-team"
        assert spec, f"cell {key} has no pinned map_spec"
        x, y = key.split(",")
        path = OUT / f"cell_{x}_{y}.json"
        path.write_text(spec if isinstance(spec, str) else json.dumps(spec))
        print(f"{key}: fetched map_spec ({map_ref})", flush=True)


def cmd_patch() -> None:
    for x, y, count in targets():
        spec = OUT / f"cell_{x}_{y}.json"
        if not spec.exists():
            sys.exit(f"missing {spec} — run fetch first")
        seed = puddle_seed(x, y)
        place = subprocess.run(
            [str(MAPKIT), "puddles", str(spec),
             "--count", str(count), "--seed", str(seed)],
            check=True, capture_output=True, text=True,
        )
        subprocess.run([str(MAPKIT), "validate", str(spec)],
                       check=True, capture_output=True)
        subprocess.run(
            [str(MAPKIT), "render", str(spec),
             "-o", str(OUT / f"cell_{x}_{y}.png")],
            check=True, capture_output=True,
        )
        placed = len(json.loads(spec.read_text()).get("puddles", []))
        note = "" if placed == count else f"  (WANTED {count})"
        print(f"{x},{y}: {placed} puddles seed={seed}{note}", flush=True)


def cmd_upload() -> None:
    for x, y, count in targets():
        spec = OUT / f"cell_{x}_{y}.json"
        png = OUT / f"cell_{x}_{y}.png"
        loaded = json.loads(spec.read_text())
        assert loaded.get("puddles"), f"{spec} has no puddles — run patch first"
        resp = api_call(
            f"/v2/leagues/league_{LEAGUE}/campaign/cell-map",
            {
                "cell": f"{x},{y}",
                "map_spec": loaded,
                "preview_png_base64": base64.b64encode(png.read_bytes()).decode(),
            },
        )
        print(f"{x},{y}: uploaded, preview={resp.get('preview_url')}", flush=True)


def cmd_verify() -> None:
    rows = sql(
        "SELECT key, jsonb_array_length(value->'map_spec'->'puddles') "
        "FROM leagues, jsonb_each(commissioner_state->'cells') AS c(key, value) "
        f"WHERE id = '{LEAGUE}' AND value->'map_spec' ? 'puddles' ORDER BY key"
    )
    print(f"{len(rows)} cells carry puddles on prod:")
    for key, n in rows:
        x, y = map(int, key.split(","))
        want = puddle_count(x, y)
        note = "" if n <= want and want > 0 else "  UNEXPECTED"
        print(f"  {key}: {n} (gradient wants {want}){note}")


if __name__ == "__main__":
    cmds = {"plan": cmd_plan, "fetch": cmd_fetch, "patch": cmd_patch,
            "upload": cmd_upload, "verify": cmd_verify}
    if sys.argv[1:2] and sys.argv[1] in cmds:
        cmds[sys.argv[1]]()
    else:
        sys.exit(f"usage: {sys.argv[0]} {'|'.join(cmds)}")
