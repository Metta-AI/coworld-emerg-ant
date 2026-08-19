#!/usr/bin/env python3
"""Generate the 10x10 Paintbot campaign map set with mapkit.

Usage:
    nim c -d:release -o:/tmp/mapkit tools/mapkit.nim
    MAPKIT=/tmp/mapkit CAMPAIGN_MAPS_OUT=/tmp/campaign_maps \
        python3 scripts/gen_campaign_maps.py all      # or explicit cells: 0,0 3,4 ...

Idempotent: a cell with an existing spec+info file is skipped, so shards can
run in parallel over disjoint cell lists and a killed run just resumes.

Scheme:
- Mode zones by nearest anchor: 1v1 at (0,0) top-left, 2v2 at (9,0) top-right,
  ffa4 at (4.5,9) bottom-middle. Zones spread from their anchors (Voronoi).
- Symmetry per zone: 1v1 -> mirror, 2v2 -> rot180, ffa4 -> quadmirror
  (the rectangular 4-team symmetry). All maps standard size (1235x659).
- Organic terrain: caves style everywhere.
- Density gradient: obstacle fill is highest at the board center (4.5,4.5)
  and falls off toward the edges.
- Neighbor similarity: params vary smoothly across the grid (fillProb from the
  density field, blobScale drifts with x, cave cell size drifts with y), and
  each cell's seed is deterministic in its coordinates.
"""

import json
import math
import subprocess
import sys
import zlib
from pathlib import Path

import os

MAPKIT = Path(os.environ.get("MAPKIT", "mapkit"))
OUT = Path(os.environ.get("CAMPAIGN_MAPS_OUT", "campaign_maps"))

ANCHORS = {"1v1": (0.0, 0.0), "2v2": (9.0, 0.0), "ffa4": (4.5, 9.0)}
SYMMETRY = {"1v1": "mirror", "2v2": "rot180", "ffa4": "quadmirror"}
CENTER = (4.5, 4.5)
DMAX = math.dist((0.0, 0.0), CENTER)  # farthest corner from board center


def mode_for(x: int, y: int) -> str:
    return min(ANCHORS, key=lambda m: math.dist((x, y), ANCHORS[m]))


def density_norm(x: int, y: int) -> float:
    """0.0 at board center (densest) .. 1.0 at the far corners (sparsest)."""
    return min(1.0, math.dist((x, y), CENTER) / DMAX)


def params_for(x: int, y: int, mode: str) -> dict:
    d = density_norm(x, y)
    # NOTE: never vary `cell` — some values (e.g. 44) systematically break the
    # style's sightline anchors and no seed validates.
    if mode == "ffa4":
        # Quad-mirror boards: the small quadrant CA grid is bistable at the
        # default birth/death — loosen thresholds so organic blobs survive,
        # and run a fill band tuned to the tighter cover/route budget.
        return {
            "fillProb": round(0.26 + (1.0 - d) * 0.08, 3),
            "birth": 4,
            "death": 3,
            "blobScale": 0.55,
        }
    fill = 0.17 + (1.0 - d) * 0.14  # 0.17 edge .. 0.31 center
    return {
        "fillProb": round(fill, 3),
        "blobScale": round(0.46 + 0.06 * (x / 9.0) + 0.03 * (y / 9.0), 3),
    }


def features_for(x: int, y: int, mode: str) -> list[str]:
    """Trench + glass flags. 2-team maps carry generous trenches and glass
    (scaled with the density field); trenches never place on 4-team maps,
    and quads keep the default glass draw."""
    if mode == "ffa4":
        return []
    d = density_norm(x, y)
    pits = 4 + round(8 * (1.0 - d))      # 4 at the edges .. 12 mid-board
    windows = 3 + round(3 * (1.0 - d))   # 3 .. 6
    return ["--pits", str(pits), "--windows", str(windows)]


def base_seed(x: int, y: int) -> int:
    return zlib.crc32(f"paintbot-campaign:{x},{y}".encode()) % 100_000


def polygon_count(path: Path) -> int:
    spec = json.loads(path.read_text())
    return sum(1 for o in spec["leftObstacles"] if o.get("kind") == "polygon")


def generate_cell(x: int, y: int, max_tries: int = 80) -> dict:
    """Retry seeds until the validator passes. Quad-mirror cells keep probing
    for several passing candidates and keep the most ORGANIC one (most blob
    polygons): their pass band is much tighter, and many passing seeds carry
    few or no caves blobs."""
    mode = mode_for(x, y)
    params = params_for(x, y, mode)
    spec_path = OUT / f"cell_{x}_{y}.json"
    tmp_path = OUT / f"cell_{x}_{y}.tmp.json"
    want_candidates = 5 if mode == "ffa4" else 1
    best: tuple[int, int, int] | None = None  # (blobs, -tries, seed)
    found = 0
    for k in range(max_tries):
        seed = base_seed(x, y) + k * 7919
        cmd = [
            str(MAPKIT), "generate", "--style", "caves",
            "--seed", str(seed), "--size", "standard",
            "--symmetry", SYMMETRY[mode], "--endzone", "column",
            "-o", str(tmp_path),
        ]
        if mode == "ffa4":
            cmd += ["--layout", "corners"]
        cmd += features_for(x, y, mode)
        for key, val in params.items():
            cmd += ["--param", f"{key}={val}"]
        subprocess.run(cmd, check=True, capture_output=True)
        ok = subprocess.run(
            [str(MAPKIT), "validate", str(tmp_path)], capture_output=True
        )
        if ok.returncode != 0:
            continue
        found += 1
        blobs = polygon_count(tmp_path)
        if best is None or (blobs, -k, seed) > best:
            best = (blobs, -k, seed)
            tmp_path.replace(spec_path)
        else:
            tmp_path.unlink()
        if found >= want_candidates:
            break
    if best is None:
        raise RuntimeError(f"cell {x},{y}: no passing seed in {max_tries} tries")
    return {"cell": f"{x},{y}", "mode": mode, "seed": best[2],
            "tries": -best[1] + 1, "blobs": best[0], "params": params}


def print_board() -> None:
    glyph = {"1v1": "1", "2v2": "2", "ffa4": "4"}
    print("mode grid (x right, y down):")
    for y in range(10):
        row = []
        for x in range(10):
            d = density_norm(x, y)
            row.append(f"{glyph[mode_for(x, y)]}{int((1 - d) * 9)}")
        print("  " + " ".join(row))
    counts = {}
    for y in range(10):
        for x in range(10):
            m = mode_for(x, y)
            counts[m] = counts.get(m, 0) + 1
    print("zone sizes:", counts)


if __name__ == "__main__":
    OUT.mkdir(exist_ok=True)
    print_board()
    if sys.argv[1:] == ["all"]:
        cells = [(x, y) for y in range(10) for x in range(10)]
    else:
        cells = [tuple(map(int, a.split(","))) for a in sys.argv[1:]]
    if not cells:
        sys.exit(0)
    for x, y in cells:
        info_path = OUT / f"cell_{x}_{y}.info.json"
        if info_path.exists() and (OUT / f"cell_{x}_{y}.json").exists():
            print(f"{x},{y}: already done, skipping", flush=True)
            continue
        info = generate_cell(x, y)
        info_path.write_text(json.dumps(info, indent=2))
        print(f"{info['cell']}: {info['mode']} seed={info['seed']} "
              f"tries={info['tries']} params={info['params']}", flush=True)
    
