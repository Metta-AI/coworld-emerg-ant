# CTF wire protocol — Sprite v1 plus CTF extensions

Both the player endpoints (`/player`, POV observation streams) and the
global/spectator endpoint speak
[Sprite v1](https://github.com/Metta-AI/bitworld/blob/master/docs/sprite_v1.md).
This document lists everything CTF adds or changes relative to that base
document; anything not mentioned here matches Sprite v1 exactly. Game
semantics — mechanics, sprite labels, tuning defaults — live in
[`RULES.md`](RULES.md).

## Player input: bit 7 is the C button

Sprite v1 reserves player-input bit `7` ("must be sent as 0"). CTF assigns it:

| Bit | Value | Meaning |
| ---: | ---: | --- |
| `7` | `0x80` (128) | C button — hold to charge a grenade throw, release to throw |

Send it in the standard `0x84` Player Input bitmask alongside the Sprite v1
bits (d-pad, Select, A, B). A player that never sets bit 7 can still move,
shoot, and win — but cannot throw a carried grenade. See `RULES.md`, section
*Grenades*, for the charge/release mechanics. (The spray can is not thrown:
carrying one turns the normal trigger into the paint cone; C keeps throwing a
carried grenade.)

## Player Ready (`0x85`) is supported — but do NOT send it in league play

The server understands the Sprite v1 Player Ready packet (`0x85`): after each
rendered frame a player client may send it to signal "done thinking", which
lets the server pace fast-mode games by readiness instead of the wall clock.
Sending it is optional; clients that never send it are paced by timeouts.

**Warning (measured, not theoretical):** on a wall-clock-paced server (league
play runs with `fastMode` off), sending ready every frame corrupts
input-application timing. The reference bot's dead-reckoned aim random-walked
to a median ~15-brad error at the trigger and its gun accuracy collapsed from
44–54% to 13–23%; removing the send flipped an 0W–23L record to 8W–10L vs the
champion (p=0.0039). Send `0x85` only when you know the server is in fast
mode (fixture recording); competitive clients should not send it at all. The
reference implementation gates it behind `CTF_BOT_FAST_READY=1`
(`players/baseline/baseline.nim`, `fastReadyEnabled`).

## Your own aim: read the `own aim` marker; dead-reckon between frames

The player stream carries an absolute readback of your own aim angle: an
invisible 1×1 HUD marker labeled `own aim <brads>` (256 brads per turn,
0 = east, counter-clockwise), stating your turret angle as of the rendered
tick. Match the label by the `own aim ` prefix and parse the tail. (An
earlier build's "aim dot" label was a previous form of this readback; the
engine retired it, and between the two the observation carried none — bots
from that era dead-reckon open-loop.)

The marker is exact only for the rendered tick, so a client still integrates
between frames:

- Spawn (and respawn) aim points toward the enemy side.
- Each held rotate button turns the continuous aim by the server's
  `aimTurnRate` (default 5 brads per tick, about 7 degrees) for **every elapsed
  sim tick** — including ticks you
  never saw a frame for. If you process frames with `frameAdvance > 1`
  (see below), integrate the rotation across all advanced ticks, then let the
  next frame's marker correct the estimate.
- The aim angle **locks at the trigger pull**: the shot releases after
  `fireWindupTicks` with the aim as of the pull, so stop rotating on the tick
  you fire if you want the shot to go where you aimed.

## Frame pacing: drain the backlog, act on the latest frame

The server keeps applying your **last sent input mask** on every sim tick,
whether or not you sent anything — inputs are level-based state, not events.
If your client falls behind the frame stream, acting on a stale frame means
reacting to a world that has already moved on while your held buttons kept
applying. The reference client drains the socket backlog each loop iteration
(up to 128 buffered frames), decides on the **latest** frame only, and tracks
how many sim ticks elapsed since the previous decision (`frameAdvance`) so
dead-reckoned state (like the aim, above) stays consistent. Only *changes* to
the input mask need to be sent.

## Lobby and interstitial detection

There is no explicit "game phase" message on the player stream. The in-game
signal is the **map camera object** (object id `1`, sprite id `1`): while it
is present, a match is running and its `(x, y)` is the camera anchor; the
server deletes it during the lobby and the game-over interstitial. The
reference client treats "map object deleted" as leave-game (reset transient
state) and "map object defined" as enter-game. The walkability mask arrives
as its own labeled sprite (see `RULES.md`) and is only valid in-game.

## Observation render scale

- **Player/POV streams are 1× map resolution.** Object coordinates and sprite
  pixel sizes are map pixels directly: an object's center
  (`object.x + sprite.width / 2`, same for y) IS its map point on the
  1235×659 map. No divisor is needed.
- **Only the global/spectator/replay stream supersamples**, shipping its
  zoomable board layers at 2× (`RenderScale`); its viewport announces the
  scaled size. The sim, the gameHash, and every value quoted in `RULES.md`
  stay in 1× map pixels.
- A 0.6.0-era build shipped observation coordinates at 3×; that is long gone.
  Any advice about dividing player-stream coordinates by 3 is stale.
