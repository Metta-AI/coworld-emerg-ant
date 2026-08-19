"""Map which of our policy versions was champion over which round range.

Needed because the leaderboard aggregates the whole policy-slot history: to
judge a new lever you must compare ITS rounds against the prior version's
rounds, and to do that you first need the boundaries.

Usage: tenures.py [first_round] [last_round]
"""
import sys

import rounds as R


def label_for(detail):
    row = R.our_row(detail)
    if not row:
        return None, None, None
    pv = row.get("policy_version") or {}
    meta = row.get("result_metadata") or {}
    return (str(pv.get("label")), row.get("rank"),
            meta.get("completed_episode_count"))


if __name__ == "__main__":
    first = int(sys.argv[1]) if len(sys.argv) > 1 else 1600
    last = int(sys.argv[2]) if len(sys.argv) > 2 else 10 ** 9
    rs = [r for r in R.list_rounds(limit=1000)
          if first <= (r.get("round_number") or 0) <= last
          and r.get("status") == "completed"]
    rs.sort(key=lambda r: r["round_number"])
    print(f"{len(rs)} completed rounds in r{first}..r{last}")

    runs = []  # (label, start, end, ranks[], eps[])
    for r in rs:
        lab, rank, eps = label_for(R.round_detail(r["id"]))
        lab = lab or "NO-ROW"
        if runs and runs[-1][0] == lab:
            runs[-1][2] = r["round_number"]
            runs[-1][3].append(rank)
            runs[-1][4].append(eps)
        else:
            runs.append([lab, r["round_number"], r["round_number"], [rank], [eps]])

    print(f"\n{'label':16} {'rounds':>16} {'n':>5} {'meanRank':>9} {'zeroEp':>7} {'meanEp':>7}")
    for lab, a, b, ranks, eps in runs:
        rk = [x for x in ranks if x is not None]
        ep = [x for x in eps if x is not None]
        zero = sum(1 for x in ep if x == 0)
        print(f"{lab:16} {f'r{a}..r{b}':>16} {len(ranks):>5} "
              f"{(sum(rk)/len(rk) if rk else float('nan')):>9.2f} {zero:>7} "
              f"{(sum(ep)/len(ep) if ep else float('nan')):>7.1f}")
