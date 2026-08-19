"""Where do we stand right now? Leaderboard + our champion state + recent-round trend."""
import ctfapi

print("=== CHAMPION STATE (mine, Ctf league) ===")
for x in ctfapi.my_memberships():
    pv = x.get("policy_version") or {}
    if x.get("is_champion") or x.get("status") == "competing":
        print(f"  champ={x.get('is_champion')} status={x.get('status')}/{x.get('substatus')} "
              f"label={pv.get('label')} pv={ctfapi.gid(pv)} div={ctfapi.gid(x.get('division'))}")

def n(v, w=6, p=None):
    if v is None:
        return "-".rjust(w)
    if p is not None:
        return f"{v:>{w}.{p}f}"
    return f"{v:>{w}}"


rows = ctfapi.leaderboard(include_recent_rounds=40)
print(f"\n=== LEADERBOARD ({len(rows)} entrants) ===")
print(f"{'rk':>3} {'policy':38} {'Elo':>7} {'rds':>5} {'epW':>6} {'epN':>6} {'wr':>6}")
ours = None
for r in rows:
    label = str(r.get("policy_label"))
    line = (f"{n(r.get('rank'), 3)} {label[:38]:38} {n(r.get('score'), 7, 1)} "
            f"{n(r.get('rounds_played'), 5)} {n(r.get('episode_wins'))} "
            f"{n(r.get('episodes_played'))} {n(r.get('win_rate'), 6, 3)}")
    if "Picasso" in label:
        ours = r
        line += "   <== US"
    print(line)

if ours:
    rr = [x for x in (ours.get("recent_rounds") or []) if x.get("status") == "completed"]
    rr.sort(key=lambda x: x.get("round_number") or 0)
    print(f"\n=== OUR RECENT COMPLETED ROUNDS ({len(rr)}) ===")
    for x in rr:
        print(f"  r{x.get('round_number')} rank={x.get('rank')} score={x.get('score')} "
              f"completed={x.get('completed_at')}")
    if rr:
        ranks = [x["rank"] for x in rr if x.get("rank") is not None]
        print(f"\n  mean rank over {len(ranks)} recent completed rounds: {sum(ranks)/len(ranks):.2f}")
        half = len(ranks) // 2
        if half:
            print(f"  older half mean rank: {sum(ranks[:half])/half:.2f}   "
                  f"newer half mean rank: {sum(ranks[half:])/len(ranks[half:]):.2f}")
