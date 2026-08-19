"""Matched-opponent A/B between two of our tenures on the live ladder.

WHY THIS EXISTS: a raw tenure-vs-tenure winrate is confounded, because the
field re-arms underneath us. Over r1672..r1938 daveey went v56 -> v62, beacon
v28 -> v33 and Jordan v2 -> v9. If the field got harder while our winrate held
flat, the flat number is HIDING a real gain — and if the field got softer it is
hiding a real loss. So we also compare only against opponent versions that
appear in BOTH tenures, weighted by the smaller of the two sample sizes.

Reads the episode cache h2h.py already wrote (/tmp/ctfladder/eps_*.json), so
it is free to re-run once the sweeps are done.

Usage:
  matched.py <aFirst> <aLast> <bFirst> <bLast> [min_n]
  matched.py 1672 1846 1847 1938 20
"""
import sys

import h2h


def wr(v):
    n = v["w"] + v["l"] + v["d"]
    return (v["w"] / n if n else float("nan")), n


def main():
    af, al, bf, bl = (int(x) for x in sys.argv[1:5])
    min_n = int(sys.argv[5]) if len(sys.argv) > 5 else 20

    pa, la, ra = h2h.collect(af, al)
    pb, lb, rb = h2h.collect(bf, bl)

    aw = sum(v["w"] for v in pa.values())
    an = sum(v["w"] + v["l"] + v["d"] for v in pa.values())
    bw = sum(v["w"] for v in pb.values())
    bn = sum(v["w"] + v["l"] + v["d"] for v in pb.values())

    print(f"=== A r{af}..r{al}  {dict(la)}  {ra} rounds ===")
    print(f"    raw episode winrate {aw}/{an} = {aw/an:.4f}")
    print(f"=== B r{bf}..r{bl}  {dict(lb)}  {rb} rounds ===")
    print(f"    raw episode winrate {bw}/{bn} = {bw/bn:.4f}")
    print(f"\n    RAW DELTA (confounded by field churn): "
          f"{(bw/bn - aw/an)*100:+.2f} pp")

    common = [o for o in set(pa) & set(pb)
              if wr(pa[o])[1] >= min_n and wr(pb[o])[1] >= min_n]
    only_a = sorted(set(pa) - set(pb), key=lambda o: -wr(pa[o])[1])
    only_b = sorted(set(pb) - set(pa), key=lambda o: -wr(pb[o])[1])

    print(f"\n=== MATCHED OPPONENTS (same policy version in both, "
          f"n>={min_n} each) ===")
    print(f"  {'opponent':44} {'A wr':>7} {'nA':>5} {'B wr':>7} {'nB':>5} "
          f"{'delta':>8} {'wt':>5}")
    num = den = 0.0
    for o in sorted(common, key=lambda o: -min(wr(pa[o])[1], wr(pb[o])[1])):
        wa, na = wr(pa[o])
        wb, nb = wr(pb[o])
        w = min(na, nb)
        num += (wb - wa) * w
        den += w
        print(f"  {o[:44]:44} {wa:>7.3f} {na:>5} {wb:>7.3f} {nb:>5} "
              f"{(wb-wa)*100:>+7.1f}p {w:>5}")
    if den:
        print(f"\n  ⭐ MATCHED-OPPONENT DELTA (weighted by min(nA,nB)): "
              f"{num/den*100:+.2f} pp   over {int(den)} matched episodes")
        up = sum(1 for o in common if wr(pb[o])[0] > wr(pa[o])[0])
        print(f"     opponents improved: {up}/{len(common)}")

    def blk(title, keys, per):
        print(f"\n  {title}")
        for o in keys[:10]:
            w_, n_ = wr(per[o])
            if n_ >= min_n:
                print(f"    {o[:44]:44} wr {w_:>6.3f}  n {n_:>5}")

    blk(f"only in A (retired from field, n>={min_n}):", only_a, pa)
    blk(f"only in B (NEW opposition v28 faces, n>={min_n}):", only_b, pb)


if __name__ == "__main__":
    main()
