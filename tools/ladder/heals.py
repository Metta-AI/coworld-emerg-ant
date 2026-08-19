"""Mechanism check: did medEcon actually move the HEAL economy on the field?

The winrate says whether v28 is better; this says whether it is better FOR THE
REASON WE CLAIMED. medEcon routes a wounded bot to the med kits' static engine
coords, so the falsifiable prediction is: our heals per episode go UP, and the
field's heal advantage over us shrinks toward parity.

League replays are free to download, and re-simulating one revalidates its
hashes every step — so a clean run also proves the recording is deterministic
on our engine. Heal events carry `source` = the healed player index, and the
episode's participants give us index -> policy, which is what lets us split
"our heals" from "their heals".

Prereqs:
  - an extract_events binary matching the replays' GameVersion
    (nim c -d:release tools/extract_events.nim from a checkout of that
    engine version; point CTF_EXTRACT_EVENTS at it, default
    /tmp/medcheck/extract_events)
  - h2h.py already ran over the round range, so /tmp/ctfladder/eps_*.json exists

⚠️ ENGINE MATCHING: the hosted coworld build churns fast (v26's tenure spans
0.7.80..0.7.94, v28's spans 0.7.94..0.7.102) and a replay from a build whose
GameVersion differs from our lab engine refuses to re-simulate at all
("Replay game version does not match"). Comparing v26 heals to v28 heals is
therefore only legitimate on a SHARED coworld build — pass --cw to pin one.

Usage: heals.py <first_round> <last_round> <our_version> [n_episodes] [--cw VER]
       heals.py 1847 1938 28 40 --cw 0.7.94
"""
import glob
import json
import os
import subprocess
import sys
import urllib.request

import rounds as R

BIN = os.environ.get("CTF_EXTRACT_EVENTS", "/tmp/medcheck/extract_events")
WORK = "/tmp/medcheck/work"
# Attrition window: 81% of the pre-fix K-D deficit was booked in ticks 1000..3000.
ATTR_LO, ATTR_HI = 1000, 3000


def our_episodes(first, last, ver):
    """Cached episodes in range where we ran policy version `ver`."""
    out = []
    for p in sorted(glob.glob("/tmp/ctfladder/eps_*.json")):
        for e in json.load(open(p)):
            if e.get("status") != "completed" or not e.get("replay_url"):
                continue
            mine = [x for x in e.get("participants", [])
                    if x.get("player_id") == R.OUR_PLY]
            if not mine or mine[0].get("version") != ver:
                continue
            rnd = e.get("round_number")
            if rnd is not None and not (first <= rnd <= last):
                continue
            out.append(e)
    return out


def analyze(e):
    """Re-simulate one episode; return per-side heal/kill/death counts."""
    os.makedirs(WORK, exist_ok=True)
    rp = f"{WORK}/{e['episode_id']}.replay"
    ev = f"{WORK}/{e['episode_id']}.jsonl"
    if not os.path.exists(rp):
        urllib.request.urlretrieve(e["replay_url"], rp)
    if not os.path.exists(ev):
        r = subprocess.run([BIN, rp, "--out", ev], capture_output=True, text=True)
        if r.returncode != 0:
            return None
    # seat index -> is-ours. policy_version_ids is per-AGENT and positional.
    pvids = e.get("policy_version_ids") or []
    ours_pv = {x["policy_version_id"] for x in e["participants"]
               if x.get("player_id") == R.OUR_PLY}
    mine = [i for i, pv in enumerate(pvids) if pv in ours_pv]
    if not mine:
        return None
    mineset = set(mine)
    s = {"heal_us": 0, "heal_them": 0, "healhp_us": 0, "healhp_them": 0,
         "kill_us": 0, "kill_them": 0,
         "akill_us": 0, "akill_them": 0, "ticks": 0}
    try:
        for line in open(ev):
            o = json.loads(line)
            if o.get("type") == "summary":
                s["ticks"] = o.get("ticks", 0)
                continue
            k, src, tick = o.get("kind"), o.get("source"), o.get("tick", 0)
            if k == "heal":
                side = "us" if src in mineset else "them"
                s[f"heal_{side}"] += 1
                s[f"healhp_{side}"] += max(0, o.get("amount") or 0)
            elif k == "kill":
                side = "us" if src in mineset else "them"
                s[f"kill_{side}"] += 1
                if ATTR_LO <= tick <= ATTR_HI:
                    s[f"akill_{side}"] += 1
    except FileNotFoundError:
        return None
    return s


def main():
    argv = sys.argv[1:]
    cw = None
    if "--cw" in argv:
        i = argv.index("--cw")
        cw = argv[i + 1]
        argv = argv[:i] + argv[i + 2:]
    first, last, ver = int(argv[0]), int(argv[1]), int(argv[2])
    cap = int(argv[3]) if len(argv) > 3 else 40
    eps = our_episodes(first, last, ver)
    if cw:
        eps = [e for e in eps if e.get("coworld_version") == cw]
        print(f"  pinned to coworld {cw}: {len(eps)} candidate episodes")
    # deterministic spread across the tenure, no RNG
    if len(eps) > cap:
        step = len(eps) / cap
        eps = [eps[int(i * step)] for i in range(cap)]
    print(f"v{ver} r{first}..r{last}: analyzing {len(eps)} episodes")

    tot = {}
    ok = 0
    for i, e in enumerate(eps):
        s = analyze(e)
        if not s:
            print(f"  [{i}] FAILED {e['episode_id'][:8]}")
            continue
        ok += 1
        for k, v in s.items():
            tot[k] = tot.get(k, 0) + v
    if not ok:
        print("  no episodes analyzed")
        return
    print(f"\n=== v{ver}: {ok} episodes re-simulated (hash-validated) ===")
    print(f"  HEALS   ours {tot['heal_us']/ok:6.2f}/ep   "
          f"theirs {tot['heal_them']/ok:6.2f}/ep   "
          f"ratio theirs/ours = "
          f"{(tot['heal_them']/max(1,tot['heal_us'])):.2f}x")
    print(f"  HEAL HP ours {tot['healhp_us']/ok:6.2f}/ep   "
          f"theirs {tot['healhp_them']/ok:6.2f}/ep")
    kd = tot["kill_us"] / max(1, tot["kill_them"])
    print(f"  KILLS   ours {tot['kill_us']/ok:6.2f}/ep   "
          f"theirs {tot['kill_them']/ok:6.2f}/ep   K/D = {kd:.3f}")
    akd = tot["akill_us"] / max(1, tot["akill_them"])
    print(f"  ATTRITION WINDOW ticks {ATTR_LO}..{ATTR_HI}: "
          f"ours {tot['akill_us']/ok:6.2f}/ep  theirs {tot['akill_them']/ok:6.2f}/ep"
          f"  K/D = {akd:.3f}")
    print(f"  mean ticks {tot['ticks']/ok:.0f}")


if __name__ == "__main__":
    main()
