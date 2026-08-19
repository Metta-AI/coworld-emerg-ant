"""Fetch rounds for the Ctf league and cache them to disk.

Usage: rounds.py [since_round_number]
Caches /tmp/ctfladder/round_<n>.json so re-runs are free.
"""
import json
import os
import sys

import ctfapi

CACHE = "/tmp/ctfladder"
OUR_PV_V28 = "d1755958-dfdc-4f1c-9f9a-8a8d93f47802"
OUR_PV_V26 = "27078392-921d-4d80-97ab-ba7f6e15d5bf"
OUR_PLY = "ply_281ba4ec-d1a2-4e37-a609-a391d30421d2"


def list_rounds(limit=400):
    out, offset = [], 0
    while True:
        r = ctfapi.get(f"/v2/rounds?league_id={ctfapi.LEAGUE}&limit=100&offset={offset}")
        entries = r.get("entries") or []
        out += entries
        offset += 100
        if not entries or offset >= min(limit, r.get("total_count") or 0):
            break
    return out


def round_detail(rid):
    os.makedirs(CACHE, exist_ok=True)
    p = f"{CACHE}/{rid}.json"
    if os.path.exists(p):
        with open(p) as f:
            return json.load(f)
    d = ctfapi.round_detail(rid)
    with open(p, "w") as f:
        json.dump(d, f)
    return d


def our_row(detail):
    for row in detail.get("results", []) or []:
        pv = row.get("policy_version") or {}
        if ctfapi.gid(pv) in (OUR_PV_V28, OUR_PV_V26) or "Picasso" in str(pv.get("label")):
            return row
    return None


if __name__ == "__main__":
    since = int(sys.argv[1]) if len(sys.argv) > 1 else 1847
    rs = [r for r in list_rounds() if (r.get("round_number") or 0) >= since]
    rs.sort(key=lambda r: r["round_number"])
    print(f"{len(rs)} rounds >= r{since}")
    print(f"{'round':>6} {'status':10} {'label':13} {'rank':>4} {'score':>7} {'eps':>4} {'completed_at'}")
    for r in rs:
        if r.get("status") != "completed":
            print(f"{r['round_number']:>6} {str(r.get('status')):10} (skipped)")
            continue
        d = round_detail(r["id"])
        row = our_row(d)
        if not row:
            print(f"{r['round_number']:>6} {'completed':10} NO-PICASSO-ROW")
            continue
        pv = row.get("policy_version") or {}
        meta = row.get("result_metadata") or {}
        print(f"{r['round_number']:>6} {'completed':10} {str(pv.get('label')):13} "
              f"{str(row.get('rank')):>4} {str(row.get('score')):>7} "
              f"{str(meta.get('completed_episode_count')):>4} {r.get('completed_at')}")
