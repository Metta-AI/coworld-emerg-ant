"""Shared CTF league API helper.

Run with the cogherence player's venv, which holds the working login:
  ~/projects/coworld-players/coworld-cogherence-player/.venv/bin/python

Set COWORLD_COGHERENCE_PLAYER if that checkout lives elsewhere.
The CLI schema drifts; we speak raw JSON against /v2.
"""
import os
import sys
import time

sys.path.insert(0, os.environ.get(
    "COWORLD_COGHERENCE_PLAYER",
    os.path.expanduser("~/projects/coworld-players/coworld-cogherence-player")))

from coworld.api_client import CoworldApiClient  # noqa: E402
from coworld.config import DEFAULT_SUBMIT_SERVER  # noqa: E402

LEAGUE = "league_3243d905-d32d-4ec6-978b-fa94751d4a37"
COMPETITION_DIV = "div_37361341-2970-4dac-9528-55398bab0d1a"
OUR_PLAYER = "softmaxwell"

_client = None
_headers = None


def gid(o):
    """Membership records nest league/division/policy_version as objects."""
    return (o or {}).get("id") if isinstance(o, dict) else o


def client():
    global _client, _headers
    if _client is None:
        _client = CoworldApiClient.from_login(server_url=DEFAULT_SUBMIT_SERVER)
        _headers = _client._headers()
    return _client, _headers


def get(path, tries=5):
    """A long sweep over hundreds of rounds reliably hits a read timeout;
    retry with backoff rather than losing the whole run."""
    c, h = client()
    for i in range(tries):
        try:
            r = c._http_client.get(path, headers=h, timeout=60.0)
            r.raise_for_status()
            return r.json()
        except Exception as e:  # noqa: BLE001 — transient transport/5xx
            if i == tries - 1:
                raise
            print(f"  [retry {i+1}/{tries}] {type(e).__name__} on {path}",
                  file=sys.stderr)
            time.sleep(2 * (i + 1))


def leaderboard(include_recent_rounds=32, div=COMPETITION_DIV):
    r = get(f"/v2/divisions/{div}/leaderboard?include_recent_rounds={include_recent_rounds}")
    return r if isinstance(r, list) else (r.get("entries") or r.get("rows") or [])


def episodes(round_id, limit=1000):
    """⚠️ default limit is 50 but a round holds ~110 episodes — the default
    silently truncates and can drop our own pairings entirely."""
    r = get(f"/v2/rounds/{round_id}/episodes?limit={limit}")
    if isinstance(r, list):
        return r
    return (r.get("entries") or r.get("episodes") or r.get("data")
            or r.get("items") or [])


def round_detail(round_id):
    return get(f"/v2/rounds/{round_id}")


def my_memberships(league=LEAGUE):
    m = get("/v2/league-policy-memberships?mine=true")
    ms = m if isinstance(m, list) else (m.get("memberships") or m.get("data") or m.get("items") or [])
    return [x for x in ms if gid(x.get("league")) == league]
