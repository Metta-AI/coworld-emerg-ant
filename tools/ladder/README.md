# Ladder assessment tools

Judge a submitted policy on the LIVE Elo ladder. Run everything with the
cogherence player's venv, which holds the working login:

```sh
PY=~/projects/coworld-players/coworld-cogherence-player/.venv/bin/python
cd tools/ladder
```

| script | question it answers |
|---|---|
| `scout.py` | ⭐ **Fast loop.** Measure a policy against the real field from free public replays — per-opponent ground truth, plus who is SHIPPING. Start here; see below. |
| `standing.py` | Where are we right now? Champion state + leaderboard. |
| `tenures.py [first] [last]` | Which of our versions was champion over which round range (+ mean rank, zero-episode/DQ count). Run this FIRST — every comparison needs the boundaries. |
| `rounds.py [since]` | Round-by-round rank/score/episode-count for our champion. |
| `h2h.py <first> <last>` | Per-opponent episode W/L/winrate over a round range. |
| `matched.py <aF> <aL> <bF> <bL> [min_n]` | ⭐ A/B two tenures, matched on opponents present in both. |
| `heals.py <first> <last> <ver> [n] [--cw V]` | Mechanism metrics (heals, K/D, attrition window) by re-simulating real league replays. |

## Three traps this tooling exists to avoid

**The leaderboard `win_rate` is not your policy's winrate.** It is cumulative
over the whole *policy-slot* history, so it blends the current version with
every predecessor. Use `h2h.py` over the version's own tenure instead.

**The field re-arms underneath you, so a raw tenure-vs-tenure delta is
confounded.** Over r1672..r1938, 40% of our schedule turned over and the
churned-in opposition was 27.3 pp harder than what it replaced — a *flat* raw
winrate there is actually a real gain. `matched.py` restricts to opponent
versions present in both tenures. For the same reason, **mean rank can worsen
while the policy improves**: rank is relative to the field's current strength.

**A replay only re-simulates on the engine that recorded it.** The hosted
coworld build churns every few days (0.7.80 → 0.7.102 across two tenures) and a
mismatched build refuses outright ("Replay game version does not match"). Do not
"fix" this by overriding `GameVersion` in `sim.nim` — that gets you a hash
mismatch at tick 1, which is the engine correctly telling you behavior differs.
If two tenures share no build, the cross-version mechanism A/B is *unavailable*;
report it as such rather than comparing incomparable numbers.

## `heals.py` prereq

Needs the tier-2 event sink, which lives on the GV23 lab worktree:

```sh
cd /private/tmp/ctf-gv23-lab
nim c -d:release --hints:off -o:/tmp/medcheck/extract_events tools/extract_events.nim
```

Match the extractor's engine to the replays' `coworld_version` (GV23 accepts
0.7.95+). Pin one build with `--cw 0.7.99` when comparing across tenures.

Caches live in `/tmp/ctfladder/` (rounds + episodes) and `/tmp/medcheck/work/`
(replays + event streams), so re-runs are free. A full 174-round `h2h.py` sweep
takes ~10 min cold — run it with `nohup` in the background.

---

# `scout.py` — the fast diagnosis loop

**Why it exists.** Elo is zero-sum, so *standing still is falling*: a rival who
ships faster takes rating off us even when our own play is unchanged. On
2026-07-28 our episode winrate was flat at ~0.50 across every bucket of 146
rounds while our mean rank drifted 4.23 → 5.38 — we did not decay, the field
moved. Andre fielded six policy-versions in ~120 rounds; we shipped one. A
6-rubric audit plus a hosted single-lever A/B takes ~a day per candidate, which
loses to an opponent shipping 6/day.

**The unlock.** Every completed round already holds 110 head-to-head episodes
whose replays are **public, downloadable without auth, and re-simulable to ground
truth**. The field test is already paid for — we just have to read it. Hosted
A/Bs (which cost xp-requests and a day of latency) become the *final gate*, not
the measurement.

Measured: **411 episodes of full ground-truth attribution in 9 minutes**, 411/411
extracted cleanly.

## Setup, once

`scout.py` needs its own extractor build (it re-simulates in parallel and pins a
known engine, so it does not share `heals.py`'s `/tmp/medcheck` binary):

```sh
git worktree add ~/projects/coworld-ctf-scout -b scout origin/main
cp nim.cfg ~/projects/coworld-ctf-scout/       # UNTRACKED; builds fail without it
cd ~/projects/coworld-ctf-scout
nim c -d:release --hints:off -o:bin/extract_events tools/extract_events.nim
```

Found by default; override with `CTF_SCOUT_BIN`.

## The loop

```sh
PYTHONPATH=. $PY scout.py index                     # who we played, what they fielded
PYTHONPATH=. $PY scout.py run    --rounds 20        # download + re-simulate + report
PYTHONPATH=. $PY scout.py report --vs daveey        # drill into one opponent
PYTHONPATH=. $PY scout.py diff   --since 1837 --until 1856   # our version A vs B
```

Caches under `~/.ctf/scout/` (rounds → replays → events), so re-slicing an
existing corpus is nearly free. ~19MB per 88 episodes.

**Reports** per opponent: episodes, winrate, K/D, our accuracy vs theirs, damage
dealt/taken, shield-blocked hp, med kits, steals, captures, carrier drops — plus
a kill/death split by tick bucket (where in the match the fight is actually
lost), damage by weapon, and a **version-cadence table** flagging any rival who
shipped mid-window. `diff` compares two of our own versions over *shared
opponents only*, since a raw total is not comparable across a different mix.

## Gotchas this encodes — do not relearn them

- **`limit=1000`, always.** `/v2/rounds/{id}/episodes` defaults to `limit=50` but
  a round holds **110** episodes. The default silently truncates and can drop our
  own pairings entirely.
- **Check the `entries` key.** That endpoint returns
  `{entries, limit, offset, total_count}`. Code looking only for
  `episodes`/`data`/`items` got an empty list, which read as "no episodes" rather
  than as an error. (The old note that this endpoint 403s is **stale** — it
  returns 200 and `replay_url` is a public S3 object needing no auth.)
- **`--rounds N` slides.** A round lands every ~9 min (~165/day), so a bare
  `--rounds N` names a different set each run and a long sweep can drift under
  its own report. Pin with `--since A --until B`; `scout.py` prints the flags to
  reproduce any sliding run.
- **`Heal` records the healed player in `source`, not `target`.** Reading
  `target` silently drops every heal — and med-kit uptake is a watched lever.
- **The GameVersion horizon is real** (same trap `heals.py` documents), but
  `scout.py` reads it from the replay *header* and reports it up front
  (`GV22=271 skipped`) instead of as N opaque failures. `diff` deliberately uses
  the episode's **own API score** rather than a re-simulation, so version
  comparisons still work across a bump.
- **Attribution is grounded in the replay, never assumed.** Hosted replays record
  the league player name per seat (`"softmaxwell"`, `"softmaxwell (2)"`…), and
  API `position` == replay join slot. An episode containing a name we can't place
  is skipped rather than guessed at.
- **Empty seats happen.** A blank recorded name means that agent never joined and
  the episode ran short-handed — a free loss, not a policy problem. Reported
  separately.
- **Both seatings come free.** 110 episodes = 55 pairings × both seatings, so the
  Red-favored map is already controlled for; `report` prints the red/blue split
  so a per-opponent number is never just the map talking.

**Trust.** The re-simulated winner agreed with the league's own episode score on
**88/88** episodes — the extraction faithfully mirrors the hosted result, so the
richer attribution built on it can be trusted too.
