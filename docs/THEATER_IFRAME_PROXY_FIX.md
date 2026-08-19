# Theater mode: allow the same-origin board iframe (proxy header fix)

**For:** whoever owns the Observatory session-proxy / CDN in front of CTF replay sessions.
**Symptom:** In **theater mode** the walled-pit chrome renders, but the center shows
Chrome's grey **"This content is blocked. Contact the site owner to fix the issue."**
box. Regular replay, full-screen, and David's standalone viewer are all unaffected.

## Why only theater mode

Theater mode is the **only** replay surface that embeds the board in an `<iframe>`:

- The shell (`/client/league`) renders the stone-pit chrome and embeds the board at
  `<prefix>/client/replay?embed=1` in an iframe.
  - `client/league_replayer.html:228` — `<iframe id="game">`
  - `client/league_replayer.html:308,329` — iframe `src` = `ROUTE_BASE + '/client/replay?embed=1'`
    (`ROUTE_BASE` keeps it inside the session-proxy prefix).
- The regular board, full-screen, and the standalone viewer all load `/client/replay`
  as a **top-level document** with their own WebSocket — nothing is framed, so nothing
  can be refused.

Frames flow from the child iframe up to the shell via `postMessage`. When the iframe
load is refused, no frame ever arrives and the viewer used to hang on "waiting for
replay frames…" forever. (That silent hang is now a visible error card + "Open the
board directly →" link — shipped in PR #112 — but that is a graceful-degradation
band-aid, **not** the fix. The board still won't render *inside* the theater until the
header below is changed.)

## Root cause: a framing header injected by the proxy, not by us

- The shell and the board are served from the **same origin** (same server, same handler
  block): `src/ctf/server.nim:602-631` responds to both `/client/league` and
  `/client/replay` from one place.
- **Our origin server sends no framing header** — verified: no `X-Frame-Options`,
  `Content-Security-Policy`, or `frame-ancestors` anywhere in `src/`. The only response
  headers we set on these routes are `Content-Type` and `Cache-Control`
  (`src/ctf/server.nim:625-627`).

Therefore the `X-Frame-Options` / CSP `frame-ancestors` that denies the iframe is being
**added by the Observatory session-proxy (or CDN/WAF) in front of us.**

## The fix (Option A)

On the session-proxy responses for `/client/replay` (ideally all `/client/*` under the
per-session proxy prefix), **either**:

- **Drop** any `X-Frame-Options` header, **or**
- **Set** `Content-Security-Policy: frame-ancestors 'self'`

Because the shell and board are the **same origin**, `frame-ancestors 'self'` is
sufficient and safe — no need for `*` or an allow-list. (If a CSP already exists on
these responses, merge `frame-ancestors 'self'` into it rather than adding a second
CSP header.)

Theater mode keeps working exactly as it does today — board embedded in the walled pit,
one WebSocket, postMessage transport bridge — because the iframe is same-origin; the
header is the only thing refusing it.

## How to confirm before/after

1. Open the theater (`.../proxy/client/league?...`) with DevTools → **Network**.
2. Click the `.../client/replay?embed=1` request → **Response Headers**. Look for
   `x-frame-options` or a `content-security-policy` with `frame-ancestors`.
   - The **Console** will also show the exact refusal, e.g.
     *"Refused to display '…/client/replay' in a frame because it set 'X-Frame-Options'
     to 'deny'"* or a CSP `frame-ancestors` violation.
3. After the proxy change: that header is gone / permits `'self'`, the iframe loads,
   and the arena renders inside the pit (the "waiting for replay frames…" / error card
   never appears).

## Durable fallback (Option B) — only if the proxy header cannot be changed

Rework the theater shell to render the board **in the same document/context** instead of
a nested iframe (one page, one WebSocket, no child frame). Visually identical, but
immune to any framing policy. More work; tracked separately if Option A is blocked.
