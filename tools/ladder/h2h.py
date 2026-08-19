"""Head-to-head episode winrate for our champion, per opponent, over a round range.

The leaderboard's win_rate is cumulative over the WHOLE policy-slot history
(it mixes v26's and v28's tenure), so it cannot answer "did the new lever
help". This walks the per-episode records instead and buckets by opponent.

Usage:
  h2h.py <first_round> [last_round]        # our-pv-agnostic: whatever Picasso ran
  h2h.py 1847 1938

Caches /tmp/ctfladder/eps_<round_id>.json so re-runs are free.
"""
import json
import os
import sys
from collections import defaultdict

import ctfapi
import rounds as R

CACHE = "/tmp/ctfladder"
OUR_PLY = R.OUR_PLY


def episodes_cached(rid):
    os.makedirs(CACHE, exist_ok=True)
    p = f"{CACHE}/eps_{rid}.json"
    if os.path.exists(p):
        with open(p) as f:
            return json.load(f)
    eps = ctfapi.episodes(rid)
    with open(p, "w") as f:
        json.dump(eps, f)
    return eps


def opp_label(p):
    return f"{p.get('player_name')} {p.get('policy_name')}:v{p.get('version')}"


def collect(first, last):
    """Return (per_opponent dict, our_pv_labels seen, n_rounds)."""
    rs = [r for r in R.list_rounds()
          if first <= (r.get("round_number") or 0) <= last
          and r.get("status") == "completed"]
    rs.sort(key=lambda r: r["round_number"])
    per = defaultdict(lambda: {"w": 0, "l": 0, "d": 0})
    labels = defaultdict(int)
    used = 0
    for r in rs:
        eps = episodes_cached(r["id"])
        found = False
        for e in eps:
            if e.get("status") != "completed":
                continue
            mine = [p for p in e.get("participants", []) if p.get("player_id") == OUR_PLY]
            if not mine:
                continue
            found = True
            my_pv = mine[0]["policy_version_id"]
            labels[f"{mine[0].get('policy_name')}:v{mine[0].get('version')}"] += 1
            opps = {opp_label(p) for p in e.get("participants", [])
                    if p.get("player_id") != OUR_PLY}
            sc = {s["policy_version_id"]: s["score"] for s in (e.get("scores") or [])}
            my = sc.get(my_pv)
            if my is None:
                continue
            k = "w" if my > 0 else ("l" if my < 0 else "d")
            for o in opps:
                per[o][k] += 1
        if found:
            used += 1
    return per, labels, used


def report(title, per, labels, used, first, last):
    print(f"\n=== {title}: r{first}..r{last} — {used} rounds with our episodes ===")
    print("  our policy versions seen:", dict(labels))
    tw = sum(v["w"] for v in per.values())
    tl = sum(v["l"] for v in per.values())
    td = sum(v["d"] for v in per.values())
    tot = tw + tl + td
    if not tot:
        print("  NO EPISODES FOUND")
        return None
    print(f"\n  {'opponent':44} {'W':>5} {'L':>5} {'D':>4} {'n':>5} {'winrate':>8}")
    rows = sorted(per.items(), key=lambda kv: -(kv[1]["w"] + kv[1]["l"] + kv[1]["d"]))
    for o, v in rows:
        n = v["w"] + v["l"] + v["d"]
        print(f"  {o[:44]:44} {v['w']:>5} {v['l']:>5} {v['d']:>4} {n:>5} "
              f"{v['w']/n:>8.3f}")
    print(f"\n  OVERALL episode winrate: {tw}/{tot} = {tw/tot:.4f}   (draws {td})")
    return {"per": {k: dict(v) for k, v in per.items()}, "w": tw, "l": tl, "d": td,
            "wr": tw / tot, "rounds": used}


if __name__ == "__main__":
    first = int(sys.argv[1])
    last = int(sys.argv[2]) if len(sys.argv) > 2 else 10 ** 9
    per, labels, used = collect(first, last)
    report("H2H", per, labels, used, first, last)
