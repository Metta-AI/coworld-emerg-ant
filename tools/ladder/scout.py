"""scout — measure a policy against the REAL league field from free public replays.

The whole point: a hosted A/B costs ~a day. Every completed league round already
holds 110 head-to-head episodes whose replays are public, downloadable without
auth, and re-simulable to ground truth. So the field test is already paid for —
we just have to read it. Reserve hosted A/Bs for the final gate.

Pipeline (each stage caches, so re-runs are nearly free):
  1. index    /v2/rounds -> /v2/rounds/{id}/episodes?limit=1000   [JSON cache]
  2. fetch    episode replay_url -> ~/.ctf/scout/replays/*.replay [S3, no auth]
  3. extract  bin/extract_events -> ~/.ctf/scout/events/*.jsonl   [tier-2 sink]
  4. report   aggregate ground-truth attribution per opponent

Usage:
  scout.py index  [--rounds N] [--since ROUND]
  scout.py fetch  [--rounds N] [--player NAME] [--limit N]
  scout.py report [--rounds N] [--player NAME] [--vs NAME]
  scout.py run    [--rounds N] [--player NAME]     # index + fetch + report

⚠️ /v2/rounds/{id}/episodes defaults to limit=50 but a round holds 110 episodes.
The default SILENTLY TRUNCATES and can drop our own pairings entirely. Always
pass limit=1000 — ctfapi.episodes() does.
"""
import argparse
import collections
import concurrent.futures as futures
import json
import os
import subprocess
import sys
import urllib.request

import ctfapi

CACHE = os.path.expanduser("~/.ctf/scout")
ROUNDS_DIR = f"{CACHE}/rounds"
REPLAY_DIR = f"{CACHE}/replays"
EVENT_DIR = f"{CACHE}/events"
OURS = "softmaxwell"

# The extractor must come from a checkout that has the tier-2 SimEvent sink
# (sim.collectEvents). Override with CTF_SCOUT_BIN.
EXTRACT_BIN = os.environ.get(
    "CTF_SCOUT_BIN",
    os.path.expanduser("~/projects/coworld-ctf-scout/bin/extract_events"),
)
OUR_GV = None  # resolved from the extractor's checkout at startup

# Ticks are 1/30s. The 2026-07-28 attrition finding put most of our K-D deficit
# in the mid-game, so bucket the fight rather than reporting one flat number.
TICK_BUCKETS = [(0, 1000), (1000, 3000), (3000, 6000), (6000, 10**9)]

# Our extractor can only re-simulate replays recorded on ITS GameVersion. The
# hosted engine moves, so this is the hard horizon on how far back the free
# corpus reaches — read it off the binary rather than hard-coding a number.
SKIPPED_GV = collections.Counter()
SKIPPED_BUILD = collections.Counter()  # (GameVersion, coworld_version) -> n


def our_game_version():
    d = os.path.dirname(os.path.dirname(EXTRACT_BIN))
    try:
        with open(f"{d}/src/ctf/sim.nim") as f:
            for line in f:
                if "GameVersion* =" in line:
                    return line.split('"')[1]
    except OSError:
        pass
    return None


def _dirs():
    for d in (ROUNDS_DIR, REPLAY_DIR, EVENT_DIR):
        os.makedirs(d, exist_ok=True)


# ---------------------------------------------------------------- 1. index


def recent_rounds(count=6, since=None):
    """Completed rounds, newest first. Rounds land ~every 9 min (~165/day)."""
    out, offset = [], 0
    while True:
        r = ctfapi.get(
            f"/v2/rounds?league_id={ctfapi.LEAGUE}&limit=100&offset={offset}")
        entries = r.get("entries") or []
        if not entries:
            break
        out += [e for e in entries if e.get("status") == "completed"]
        offset += 100
        if since is None:
            if len(out) >= count:
                break
        elif min((e.get("round_number") or 0) for e in entries) < since:
            break
        if offset >= (r.get("total_count") or 0):
            break
    out.sort(key=lambda e: -(e.get("round_number") or 0))
    if since is not None:
        return [e for e in out if (e.get("round_number") or 0) >= since]
    return out[:count]


def round_episodes(rnd):
    """Episode list for one round, cached. Uses limit=1000 (see module note)."""
    _dirs()
    p = f"{ROUNDS_DIR}/r{rnd['round_number']}_{rnd['id']}.json"
    if os.path.exists(p):
        with open(p) as f:
            return json.load(f)
    eps = ctfapi.episodes(rnd["id"])
    with open(p, "w") as f:
        json.dump(eps, f)
    return eps


def index(rounds=6, since=None, until=None):
    """Returns [(round_number, episode)] for every completed episode.

    Pass `until` to pin the window: the league completes a round every ~9 min,
    so a bare `rounds=N` sweep names a DIFFERENT set of rounds each run and a
    long fetch can drift under its own report.
    """
    out = []
    picked = recent_rounds(rounds if until is None else rounds + 64, since)
    if until is not None:
        picked = [r for r in picked if (r.get("round_number") or 0) <= until]
        if since is None:
            picked = picked[:rounds]
    for rnd in picked:
        eps = round_episodes(rnd)
        got = [e for e in eps if e.get("status") == "completed"
               and e.get("replay_url")]
        out += [(rnd["round_number"], e) for e in got]
        if len(eps) != len(got):
            print(f"  r{rnd['round_number']}: {len(got)}/{len(eps)} usable",
                  file=sys.stderr)
    return out


# ------------------------------------------------------- episode roster


def entrants(ep):
    """{player_name: [positions]} — position parity picks the team."""
    by = collections.defaultdict(list)
    for p in ep.get("participants") or []:
        by[p["player_name"]].append(p["position"])
    return by


def policy_of(ep, player):
    for p in ep.get("participants") or []:
        if p["player_name"] == player:
            return f"{p['policy_name']}:v{p['version']}"
    return "?"


def score_of(ep, player):
    """+1 win / -1 loss for one player, from the episode's own scores."""
    pv = {p["player_name"]: p["policy_version_id"]
          for p in ep.get("participants") or []}
    want = pv.get(player)
    for s in ep.get("scores") or []:
        if s.get("policy_version_id") == want:
            return s.get("score")
    return None


def matchup(ep, player=OURS):
    """(player, opponent) for a head-to-head episode, or None."""
    e = entrants(ep)
    if player not in e or len(e) != 2:
        return None
    opp = next(n for n in e if n != player)
    return player, opp


# ---------------------------------------------------------------- 2. fetch


def replay_path(ep):
    return f"{REPLAY_DIR}/{ep['replay_url'].split('/')[-1]}"


def event_path(ep):
    name = ep["replay_url"].split("/")[-1].replace(".replay", ".jsonl")
    return f"{EVENT_DIR}/{name}"


def download(ep):
    """Public S3, no auth needed. Cached by replay filename."""
    p = replay_path(ep)
    if os.path.exists(p) and os.path.getsize(p) > 0:
        return p
    try:
        with urllib.request.urlopen(ep["replay_url"], timeout=90) as r:
            data = r.read()
        tmp = p + ".part"
        with open(tmp, "wb") as f:
            f.write(data)
        os.replace(tmp, p)
        return p
    except Exception as e:  # noqa: BLE001 — a dead URL must not kill the sweep
        print(f"  download failed {ep['episode_id'][:8]}: {e}", file=sys.stderr)
        return None


def replay_game_version(path):
    """The GameVersion a replay was recorded under, straight from the header
    (magic|fmt|"ctf"|len|version). Cheap: no re-simulation, so we can report
    the engine horizon up front instead of as N opaque extraction failures."""
    try:
        with open(path, "rb") as f:
            head = f.read(64)
    except OSError:
        return None
    i = head.find(b"ctf")
    if i < 0 or i + 4 > len(head):
        return None
    n = head[i + 3]
    return head[i + 5:i + 5 + n].decode("ascii", "replace") or None


def extract(ep):
    """Re-simulate to the tier-2 event stream. Hash-validated every step, so a
    clean run also proves the recording is deterministic under our engine."""
    out = event_path(ep)
    if os.path.exists(out) and os.path.getsize(out) > 0:
        return out
    src = download(ep)
    if not src:
        return None
    gv = replay_game_version(src)
    if gv and OUR_GV and gv != OUR_GV:
        # Recorded on an engine we can't re-simulate. Not a bug and not fixable
        # by retrying: it bounds which rounds the free corpus reaches. Record
        # the coworld build too, so the fix is a specific checkout to build.
        SKIPPED_GV[gv] += 1
        SKIPPED_BUILD[(gv, ep.get("coworld_version") or "?")] += 1
        return None
    r = subprocess.run([EXTRACT_BIN, src, "--out", out],
                       capture_output=True, text=True)
    if r.returncode != 0:
        # A GameVersion mismatch or hash failure lands here — expected when the
        # hosted engine has moved past our checkout. Report, don't crash.
        msg = (r.stderr or "").strip().splitlines()
        print(f"  extract failed {ep['episode_id'][:8]}: "
              f"{msg[-1] if msg else 'rc=' + str(r.returncode)}",
              file=sys.stderr)
        if os.path.exists(out):
            os.remove(out)
        return None
    return out


def fetch_all(eps, workers=8):
    """Download + extract concurrently. Returns count of usable extractions."""
    _dirs()
    if not os.path.exists(EXTRACT_BIN):
        sys.exit(f"extractor not found: {EXTRACT_BIN}\n"
                 "Build it in a checkout that has the tier-2 sink:\n"
                 "  nim c -d:release -o:bin/extract_events tools/extract_events.nim\n"
                 "or set CTF_SCOUT_BIN.")
    ok = 0
    SKIPPED_GV.clear()
    with futures.ThreadPoolExecutor(max_workers=workers) as pool:
        for got in pool.map(lambda re: extract(re[1]), eps):
            ok += bool(got)
    if SKIPPED_GV:
        old = "  ".join(f"GV{g}={n}" for g, n in SKIPPED_GV.most_common())
        print(f"  engine horizon: skipped {sum(SKIPPED_GV.values())} episode(s) "
              f"recorded on another GameVersion ({old}); our extractor is "
              f"GV{OUR_GV}.", file=sys.stderr)
        for (g, cw), n in SKIPPED_BUILD.most_common():
            newer = "newer" if OUR_GV and g > OUR_GV else "older"
            print(f"    GV{g} = coworld {cw} ({n} eps, {newer} than us)"
                  + ("  <- the hosted engine MOVED; rebuild the extractor on "
                     "current main" if newer == "newer" else ""),
                  file=sys.stderr)
    return ok


# --------------------------------------------------------------- 3. report


def load_events(ep):
    """(events, summary) from one extraction, or (None, None)."""
    p = event_path(ep)
    if not os.path.exists(p):
        return None, None
    events, summary = [], None
    with open(p) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            row = json.loads(line)
            if row.get("type") == "summary":
                summary = row
            else:
                events.append(row)
    return events, summary


class Side:
    """Ground-truth tallies for ONE player's slots in a set of episodes."""

    def __init__(self):
        self.eps = 0
        self.wins = 0
        self.kills = 0
        self.deaths = 0
        self.shots = 0
        self.hits = 0
        self.dmg_dealt = 0
        self.dmg_taken = 0
        self.blocked = 0
        self.heals = 0
        self.heal_hp = 0
        self.steals = 0
        self.captures = 0
        self.lost_carry = 0
        self.weapon_dmg = collections.Counter()
        self.killed_by = collections.Counter()
        self.bucket_k = collections.Counter()
        self.bucket_d = collections.Counter()

    @property
    def acc(self):
        return self.hits / self.shots if self.shots else 0.0

    @property
    def kd(self):
        return self.kills / self.deaths if self.deaths else float(self.kills)


def bucket(tick):
    for lo, hi in TICK_BUCKETS:
        if lo <= tick < hi:
            return f"{lo}-{hi if hi < 10**8 else 'end'}"
    return "?"


def tally(eps, player=OURS, vs=None):
    """Walks every extraction and attributes each event to a side using the
    roster recorded IN the replay — never an assumed slot mapping."""
    per_opp = collections.defaultdict(lambda: (Side(), Side()))
    seat = collections.defaultdict(lambda: [0, 0])  # team -> [wins, eps]
    # Which policy VERSION each opponent fielded, per opponent — the whole
    # point of the sweep is catching a rival's new version early.
    versions = collections.defaultdict(collections.Counter)
    short = []  # episodes an entrant played a seat down
    used = 0

    for _rnd, ep in eps:
        m = matchup(ep, player)
        if not m:
            continue
        _me, opp = m
        if vs and opp != vs:
            continue
        events, summary = load_events(ep)
        if not summary or not summary.get("finished"):
            continue

        # The replay's own roster: slot -> which side, by recorded join name.
        addr = summary.get("slot_address") or []
        teams = summary.get("slot_team") or []
        # Hosted replays record "<player>" and "<player> (2)".."(8)".
        side_of = {}
        empty = 0
        unknown = []
        for i, a in enumerate(addr):
            base = a.split(" (")[0]
            if base == player:
                side_of[i] = "me"
            elif base == opp:
                side_of[i] = "them"
            elif not base:
                # An unfilled seat: that agent never joined, so the episode ran
                # short-handed. Real and worth counting, not a parse failure.
                empty += 1
            else:
                unknown.append(base)
        if unknown or not addr:
            # A name we can't place means our roster assumption is wrong —
            # skip rather than mis-attribute kills to the wrong side.
            print(f"  r{_rnd} vs {opp}: unplaceable slots {unknown} — skipped",
                  file=sys.stderr)
            continue
        if empty:
            short.append((_rnd, opp, empty))

        used += 1
        mine, theirs = per_opp[opp]
        versions[opp][policy_of(ep, opp)] += 1
        versions[player][policy_of(ep, player)] += 1
        mine.eps += 1
        theirs.eps += 1

        my_team = next((teams[i] for i, s in side_of.items() if s == "me"), "?")
        won = summary.get("winner") == my_team
        mine.wins += won
        theirs.wins += (summary.get("winner") == ("red" if my_team == "blue"
                                                  else "blue"))
        seat[my_team][0] += won
        seat[my_team][1] += 1

        for i, s in side_of.items():
            side = mine if s == "me" else theirs
            fired = summary.get("slot_shots_fired") or []
            hit = summary.get("slot_shots_hit") or []
            if i < len(fired):
                side.shots += fired[i]
            if i < len(hit):
                side.hits += hit[i]

        for ev in events:
            k, src, tgt = ev["kind"], ev["source"], ev["target"]
            ssrc, stgt = side_of.get(src), side_of.get(tgt)
            if k == "kill" and ssrc and stgt:
                a = mine if ssrc == "me" else theirs
                v = mine if stgt == "me" else theirs
                a.kills += 1
                v.deaths += 1
                a.bucket_k[bucket(ev["tick"])] += 1
                v.bucket_d[bucket(ev["tick"])] += 1
                v.killed_by[ev.get("weapon") or "?"] += 1
            elif k == "damage" and ssrc and stgt:
                a = mine if ssrc == "me" else theirs
                v = mine if stgt == "me" else theirs
                a.dmg_dealt += ev["amount"]
                a.weapon_dmg[ev.get("weapon") or "?"] += ev["amount"]
                v.dmg_taken += ev["amount"]
                v.blocked += ev.get("blocked") or 0
            elif k == "heal" and ssrc:
                # A med-kit Heal records the HEALED player in `source`, not
                # `target` (sim.updateMedKits). Reading target here silently
                # drops every heal — and med-kit uptake is a watched lever.
                side = mine if ssrc == "me" else theirs
                side.heals += 1
                side.heal_hp += ev["amount"]
            elif k == "flag_steal" and ssrc:
                (mine if ssrc == "me" else theirs).steals += 1
            elif k == "capture" and ssrc:
                (mine if ssrc == "me" else theirs).captures += 1
            elif k == "flag_return" and ssrc:
                (mine if ssrc == "me" else theirs).lost_carry += 1

    return per_opp, seat, versions, used, short


def pct(n, d):
    return f"{100.0 * n / d:5.1f}%" if d else "    - "


def report(eps, player=OURS, vs=None):
    per_opp, seat, versions, used, short = tally(eps, player, vs)
    if not used:
        print("no attributable episodes — run `fetch` first?")
        return

    tot_e = sum(m.eps for m, _ in per_opp.values())
    tot_w = sum(m.wins for m, _ in per_opp.values())
    print(f"\n{player}: {tot_w}/{tot_e} episodes won "
          f"({pct(tot_w, tot_e).strip()}) across {len(per_opp)} opponents")
    print("ground truth re-simulated from public league replays "
          f"({used} extractions)\n")

    # Seat bias first: the map is Red-favored, so a per-opponent number that
    # isn't seat-split can be the map talking instead of the policy.
    for team in ("red", "blue"):
        w, e = seat[team]
        print(f"  as {team:4} {w:3}/{e:<3} {pct(w, e)}")

    hdr = (f"\n{'opponent':22} {'their policy':22} {'eps':>4} {'win':>6} "
           f"{'K':>4} {'D':>4} {'K/D':>5} {'acc':>6} {'oacc':>6} "
           f"{'dmg+':>5} {'dmg-':>5} {'blk':>4} {'heal':>5} "
           f"{'stl':>4} {'cap':>4} {'drop':>5}")
    print(hdr)
    rows = sorted(per_opp.items(), key=lambda kv: kv[1][0].wins / max(kv[1][0].eps, 1))
    for opp, (m, t) in rows:
        # Name every version an opponent fielded in the window: two entries
        # here means they shipped mid-window, which is the signal we want.
        opp_pol = ",".join(v for v, _ in versions[opp].most_common(2))
        print(f"  {opp[:21]:21} {opp_pol[:21]:21} {m.eps:>4} "
              f"{pct(m.wins, m.eps)} {m.kills:>4} {m.deaths:>4} "
              f"{m.kd:>5.2f} {m.acc*100:>5.1f}% {t.acc*100:>5.1f}% "
              f"{m.dmg_dealt:>5} {m.dmg_taken:>5} {m.blocked:>4} "
              f"{m.heals:>5} {m.steals:>4} {m.captures:>4} {m.lost_carry:>5}")

    # Where the fight is actually lost, in time.
    print(f"\n  {'tick bucket':14} {'our K':>6} {'our D':>6} {'K-D':>6}")
    agg_k, agg_d = collections.Counter(), collections.Counter()
    for m, _ in per_opp.values():
        agg_k.update(m.bucket_k)
        agg_d.update(m.bucket_d)
    for lo, hi in TICK_BUCKETS:
        b = f"{lo}-{hi if hi < 10**8 else 'end'}"
        k, d = agg_k[b], agg_d[b]
        if k or d:
            print(f"  {b:14} {k:>6} {d:>6} {k - d:>+6}")

    wd = collections.Counter()
    kb = collections.Counter()
    for m, _ in per_opp.values():
        wd.update(m.weapon_dmg)
        kb.update(m.killed_by)
    if wd:
        print("\n  damage we DEAL by weapon:  " +
              "  ".join(f"{w}={n}" for w, n in wd.most_common()))
    if kb:
        print("  weapon that KILLS us:      " +
              "  ".join(f"{w}={n}" for w, n in kb.most_common()))

    # Med-kit uptake, both sides. The 2026-07-28 attrition read had us losing
    # the heal race badly; this is the free way to keep watching it.
    mh = sum(m.heals for m, _ in per_opp.values())
    th = sum(t.heals for _, t in per_opp.values())
    mhp = sum(m.heal_hp for m, _ in per_opp.values())
    thp = sum(t.heal_hp for _, t in per_opp.values())
    print(f"\n  med kits taken:  us {mh} ({mhp} hp)   them {th} ({thp} hp)")
    if short:
        print(f"\n  ⚠️  {len(short)} episode(s) ran SHORT-HANDED (a seat never "
              "joined) — free losses, not a policy problem:")
        for rnd, opp, n in short[:8]:
            print(f"       r{rnd} vs {opp}: {n} empty seat(s)")
    print()
    version_cadence(versions, player)


def version_cadence(versions, player):
    """Who is SHIPPING. Elo is zero-sum, so a rival iterating faster than us
    takes rating off us even when our own play is unchanged."""
    print(f"  {'entrant':22} {'versions fielded in window':40}")
    for name, ctr in sorted(versions.items(),
                            key=lambda kv: (-len(kv[1]), kv[0])):
        marks = "  ".join(f"{v}({c})" for v, c in ctr.most_common())
        flag = "  <- us" if name == player else ("  <- SHIPPED MID-WINDOW"
                                                if len(ctr) > 1 else "")
        print(f"  {name[:21]:21} {marks[:60]:60}{flag}")
    print()


# ------------------------------------------------------------------ cli


def diff(eps, player=OURS, a_ver=None, b_ver=None):
    """Compare TWO of our own policy versions over the same field.

    This is the cheap gate a hosted A/B used to be. Both versions must appear in
    the window (i.e. we shipped mid-window), and the opponent mix is only
    comparable where BOTH faced the same rival — so restrict to shared
    opponents rather than comparing raw totals.
    """
    by_ver = collections.defaultdict(list)
    for rnd, ep in eps:
        if not matchup(ep, player):
            continue
        by_ver[policy_of(ep, player)].append((rnd, ep))
    if not by_ver:
        print("no episodes for", player)
        return
    have = sorted(by_ver, key=lambda v: -len(by_ver[v]))
    if a_ver is None or b_ver is None:
        if len(have) < 2:
            print(f"only one version in this window: {have[0]} "
                  f"({len(by_ver[have[0]])} eps) — widen --since to span a ship")
            return
        a_ver, b_ver = have[0], have[1]
    for v in (a_ver, b_ver):
        if v not in by_ver:
            print(f"{v} not in window. present: {', '.join(have)}")
            return

    def opp_wins(items):
        # Uses the episode's OWN score, not a re-simulation: win/loss is free
        # from the index, so a version diff works across a GameVersion bump
        # that the extractor can't re-simulate. (Verified: re-simulated winner
        # agreed with the API score on 88/88 episodes.)
        out = collections.defaultdict(lambda: [0, 0])
        for _r, ep in items:
            _m, opp = matchup(ep, player)
            sc = score_of(ep, player)
            if sc is None:
                continue
            out[opp][0] += (sc == 1.0)
            out[opp][1] += 1
        return out

    wa, wb = opp_wins(by_ver[a_ver]), opp_wins(by_ver[b_ver])
    shared = sorted(set(wa) & set(wb))
    print(f"\n{a_ver} vs {b_ver} over {len(shared)} shared opponents\n")
    print(f"  {'opponent':22} {a_ver[:14]:>16} {b_ver[:14]:>16} {'delta':>8}")
    ta = [0, 0]
    tb = [0, 0]
    for opp in shared:
        x, y = wa[opp], wb[opp]
        ta[0] += x[0]
        ta[1] += x[1]
        tb[0] += y[0]
        tb[1] += y[1]
        d = (x[0] / x[1] if x[1] else 0) - (y[0] / y[1] if y[1] else 0)
        print(f"  {opp[:21]:21} {x[0]:>7}/{x[1]:<8} {y[0]:>7}/{y[1]:<8} "
              f"{100*d:>+7.1f}pp")
    ra = ta[0] / ta[1] if ta[1] else 0
    rb = tb[0] / tb[1] if tb[1] else 0
    print(f"\n  {'TOTAL':21} {ta[0]:>7}/{ta[1]:<8} {tb[0]:>7}/{tb[1]:<8} "
          f"{100*(ra-rb):>+7.1f}pp")
    n = min(ta[1], tb[1])
    print(f"\n  {a_ver} {100*ra:.1f}%   {b_ver} {100*rb:.1f}%")
    if n < 40:
        print(f"  ⚠️  only {n} episodes on the thinner arm — directional only; "
              "widen the window before trusting the sign.")
    print()


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("cmd",
                    choices=["index", "fetch", "report", "run", "diff"])
    ap.add_argument("--rounds", type=int, default=6,
                    help="how many recent completed rounds (default 6)")
    ap.add_argument("--since", type=int, help="all rounds >= this number")
    ap.add_argument("--until", type=int,
                    help="highest round to include; with --since this pins an "
                         "EXACT window. Rounds land ~every 9 min, so a bare "
                         "--rounds N slides mid-run and is not reproducible.")
    ap.add_argument("--player", default=OURS)
    ap.add_argument("--vs", help="only episodes against this opponent")
    ap.add_argument("--a", help="diff: first policy, e.g. Picasso:v28")
    ap.add_argument("--b", help="diff: second policy to compare against")
    ap.add_argument("--limit", type=int, help="cap episodes fetched")
    ap.add_argument("--all", action="store_true",
                    help="fetch every episode, not just --player's")
    a = ap.parse_args()

    global OUR_GV
    OUR_GV = our_game_version()

    eps = index(a.rounds, a.since, a.until)
    rnds = sorted({r for r, _ in eps})
    lo, hi = (min(rnds), max(rnds)) if rnds else (0, 0)
    print(f"{len(eps)} completed episodes over {len(rnds)} rounds (r{lo}-r{hi})")
    if a.until is None:
        # Name the pinned re-run so a reported number can be reproduced later.
        print(f"  (sliding window — to reproduce this exact set: "
              f"--since {lo} --until {hi})")
    if a.cmd == "index":
        by = collections.Counter()
        for _r, ep in eps:
            m = matchup(ep, a.player)
            if m:
                by[m[1]] += 1
        print(f"{sum(by.values())} of them involve {a.player}:")
        for opp, n in by.most_common():
            print(f"  {opp:24} {n:>4}")
        return

    want = eps
    if not a.all:
        want = [(r, e) for r, e in eps if matchup(e, a.player)]
        if a.vs:
            want = [(r, e) for r, e in want if matchup(e, a.player)[1] == a.vs]
    if a.limit:
        want = want[:a.limit]

    if a.cmd in ("fetch", "run"):
        print(f"fetching + extracting {len(want)} episodes...")
        ok = fetch_all(want)
        print(f"{ok}/{len(want)} extracted cleanly")
    if a.cmd in ("report", "run"):
        report(want, a.player, a.vs)
    if a.cmd == "diff":
        diff(want, a.player, a.a, a.b)


if __name__ == "__main__":
    main()
