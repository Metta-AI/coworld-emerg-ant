#!/usr/bin/env python3
# Playout-buffer test harness for client/broadcast_core.js.
#
# Serves a minimal instrumented client page at /client/replay (which
# broadcast_core maps to the /replay websocket on the same host) and replays a
# synthetic 24fps sprite stream through the delivery-jitter profile measured
# against production (api.observatory.softmax-research.net, July 2026): clean
# source cadence, ~2 stalls/s of 100-150ms, each followed by a catch-up burst.
#
# Usage:
#   python3 tools/jitter_harness.py [--port 8899] [--fps 24] [--profile measured|extreme|clean]
#                                   [--timings FILE]   # one arrival-delta (ms) per line
#
# Then open:
#   http://127.0.0.1:8899/client/replay            buffered (the fix)
#   http://127.0.0.1:8899/client/replay?buffer=0   baseline (draw on arrival)
#   http://127.0.0.1:8899/client/replay?depth=2    override cushion depth
# and read window.__stats() — presentation inter-frame deltas (p50/p90/p99/max)
# plus the send-side deltas the server actually produced.
from __future__ import annotations
import argparse, asyncio, math, os, random, struct, time
from fastapi import FastAPI, Request, WebSocket, WebSocketDisconnect
from fastapi.responses import HTMLResponse
import uvicorn

HERE = os.path.dirname(os.path.abspath(__file__))
CORE_PATH = os.path.join(HERE, "..", "client", "broadcast_core.js")

VIEW_W, VIEW_H = 320, 180
SPRITE_SIZE = 12


def snappy_literal(data: bytes) -> bytes:
    """Minimal valid snappy stream: preamble varint + all-literal chunks."""
    out = bytearray()
    n = len(data)
    while True:
        b = n & 0x7F
        n >>= 7
        out.append(b | (0x80 if n else 0))
        if not n:
            break
    i = 0
    while i < len(data):
        chunk = data[i : i + 60]
        out.append((len(chunk) - 1) << 2)
        out += chunk
        i += len(chunk)
    return bytes(out)


def sprite_msg(sprite_id: int, rgba: tuple[int, int, int, int]) -> bytes:
    pixels = bytes(rgba) * (SPRITE_SIZE * SPRITE_SIZE)
    blob = snappy_literal(pixels)
    label = b"jh"
    return (
        struct.pack("<BHHH", 0x01, sprite_id, SPRITE_SIZE, SPRITE_SIZE)
        + struct.pack("<I", len(blob))
        + blob
        + struct.pack("<H", len(label))
        + label
    )


def init_msg() -> bytes:
    # layer def (id 0, type map, zoomable) + viewport + three sprites
    msg = struct.pack("<BBBB", 0x06, 0, 0, 1)
    msg += struct.pack("<BBHH", 0x05, 0, VIEW_W, VIEW_H)
    for sid, color in enumerate(
        [(230, 60, 60, 255), (60, 200, 90, 255), (240, 240, 240, 255)]
    ):
        msg += sprite_msg(sid, color)
    return msg


def frame_msg(k: int) -> bytes:
    # 12 objects orbiting at different radii/phases — smooth motion makes
    # freeze-then-jump artifacts obvious to the eye.
    msg = bytearray()
    for i in range(12):
        phase = k * 0.035 + i * (math.pi / 6)
        r = 30 + 5 * i
        x = int(VIEW_W / 2 + r * math.cos(phase)) - SPRITE_SIZE // 2
        y = int(VIEW_H / 2 + r * math.sin(phase) * 0.5) - SPRITE_SIZE // 2
        msg += struct.pack("<BHhhhBH", 0x02, i, x, y, i, 0, i % 3)
    return bytes(msg)


def delivery_times(fps: float, seconds: float, profile: str, seed: int = 7):
    """Ideal source timestamps pushed through the stall model: a frame due
    during a stall is delivered (in order) when the stall ends — a burst."""
    rng = random.Random(seed)
    n = int(seconds * fps)
    ideal = [k / fps for k in range(n)]
    stalls = []  # (start, end)
    if profile != "clean":
        t = 0.0
        while t < seconds:
            t += rng.expovariate(2.0)  # ~2 stalls/s (measured)
            stalls.append((t, t + rng.uniform(0.100, 0.150)))
        if profile == "extreme":
            for big in range(5, int(seconds), 10):
                stalls.append((float(big), big + 2.0))  # 2s outage every 10s
    out, prev = [], 0.0
    for ts in ideal:
        d = ts
        for s, e in stalls:
            if s <= d < e:
                d = e
        prev = max(prev, d)
        out.append(prev)
    return out


PAGE = """<!doctype html><meta charset=utf-8><title>jitter harness</title>
<body style="margin:0;background:#111;color:#ddd;font:12px monospace">
<div id=hud style="padding:6px;white-space:pre"></div>
<canvas id=c style="width:640px;height:360px;image-rendering:pixelated"></canvas>
<script>__CORE__</script>
<script>
const q = new URLSearchParams(location.search);
const buffered = q.get('buffer') !== '0';
if (q.get('shim') === '1') {
  // Emulate a visible 60Hz tab: headless/occluded panes suspend rAF and clamp
  // timers to 1s, but MessageChannel tasks are exempt from throttling.
  const chan = new MessageChannel();
  let cbs = [], next = performance.now() + 16.7, id = 0;
  chan.port1.onmessage = () => {
    const now = performance.now();
    if (now >= next) {
      next = now + 16.7;
      const run = cbs; cbs = [];
      for (const [, cb] of run) { try { cb(now); } catch (e) { console.error(e); } }
    }
    chan.port2.postMessage(0);
  };
  window.requestAnimationFrame = cb => { cbs.push([++id, cb]); return id; };
  window.cancelAnimationFrame = i => { cbs = cbs.filter(([j]) => j !== i); };
  chan.port2.postMessage(0);
}
const present = [];
const cfg = {
  canvas: document.getElementById('c'),
  playoutBuffer: buffered,
  onFrame: () => present.push(performance.now()),
  onText: () => {},
  onStatus: () => {},
};
if (q.get('depth')) cfg.paceTargetDepth = parseInt(q.get('depth'), 10);
const core = BroadcastCore.create(cfg);
core.start();
window.__stats = () => {
  const d = [];
  for (let i = 1; i < present.length; i++) d.push(present[i] - present[i - 1]);
  d.sort((a, b) => a - b);
  const pct = p => d.length ? d[Math.min(d.length - 1, Math.floor(p * d.length))] : 0;
  return { mode: buffered ? 'buffered' : 'baseline', frames: present.length,
           p50: pct(0.5), p90: pct(0.9), p99: pct(0.99),
           max: d.length ? d[d.length - 1] : 0, pace: core.getPaceStats() };
};
setInterval(() => {
  const s = window.__stats();
  document.getElementById('hud').textContent =
    `${s.mode}  frames=${s.frames}  p50=${s.p50.toFixed(1)}  p90=${s.p90.toFixed(1)}` +
    `  p99=${s.p99.toFixed(1)}  max=${s.max.toFixed(1)}ms` +
    `  queue=${s.pace.queued}  interval=${s.pace.interval.toFixed(1)}ms`;
}, 500);
</script>
"""

app = FastAPI()
ARGS = None


@app.get("/client/replay")
def page(request: Request):
    core = open(CORE_PATH).read()
    return HTMLResponse(PAGE.replace("__CORE__", core))


@app.websocket("/replay")
async def ws_replay(ws: WebSocket):
    await ws.accept()
    if ARGS.timings:
        deltas = [float(x) / 1000 for x in open(ARGS.timings) if x.strip()]
        times, acc = [], 0.0
        for d in deltas:
            times.append(acc)
            acc += d
    else:
        times = delivery_times(ARGS.fps, ARGS.seconds, ARGS.profile)
    sent_deltas = []
    try:
        await ws.send_bytes(init_msg())
        t0 = time.monotonic()
        prev = None
        for k, due in enumerate(times):
            delay = t0 + due - time.monotonic()
            if delay > 0:
                await asyncio.sleep(delay)
            now = time.monotonic()
            if prev is not None:
                sent_deltas.append((now - prev) * 1000)
            prev = now
            await ws.send_bytes(frame_msg(k))
        sent_deltas.sort()
        p = lambda f: sent_deltas[min(len(sent_deltas) - 1, int(f * len(sent_deltas)))]
        print(f"[harness] sent {len(times)} frames: send-side deltas "
              f"p50={p(0.5):.1f} p90={p(0.9):.1f} p99={p(0.99):.1f} "
              f"max={sent_deltas[-1]:.1f}ms")
        await asyncio.sleep(3600)  # hold the socket open so the client keeps stats
    except (WebSocketDisconnect, Exception):
        pass


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8899)
    ap.add_argument("--fps", type=float, default=24.0)
    ap.add_argument("--seconds", type=float, default=60.0)
    ap.add_argument("--profile", choices=["measured", "extreme", "clean"],
                    default="measured")
    ap.add_argument("--timings", help="file of arrival deltas in ms, one per line")
    ARGS = ap.parse_args()
    print(f"[harness] http://127.0.0.1:{ARGS.port}/client/replay   (buffered)")
    print(f"[harness] http://127.0.0.1:{ARGS.port}/client/replay?buffer=0   (baseline)")
    uvicorn.run(app, host="127.0.0.1", port=ARGS.port, log_level="warning")
