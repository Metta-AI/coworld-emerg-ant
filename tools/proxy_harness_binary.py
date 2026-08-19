#!/usr/bin/env python3
# Local proxy mirror for the CTF broadcast replay — a BINARY-capable variant of
# ux.replay's assets/proxy_harness.py. Same job (mirror the Observatory k8s proxy:
# sandboxed iframe, base-href rewrite, CDN unreachable) but forwards the WebSocket
# in BOTH directions for BOTH frame kinds. The shared harness bridges text only
# (receive_text/send_text); bitworld's sprite protocol is BINARY (the 0x81 command
# frame + board blobs), and only the JSON chrome channel is text — so a text-only
# bridge drops `hud:on` and every board frame. This variant preserves frame type.
from __future__ import annotations
import asyncio, os, re, urllib.request
from fastapi import FastAPI, Request, WebSocket
from fastapi.responses import Response, HTMLResponse
import uvicorn, websockets

GAME = os.environ.get("GAME_BASE", "http://127.0.0.1:8792").rstrip("/")
GAME_WS = GAME.replace("http://", "ws://").replace("https://", "wss://")
NAME = os.environ.get("PROXY_NAME", "ctf")
PORT = int(os.environ.get("PROXY_PORT", "8890"))
PREFIX = f"/v2/coworlds/{NAME}/proxy"
app = FastAPI()


@app.get("/embed")
def embed(path: str = "client/replay"):
    src = f"{PREFIX}/{path}"
    return HTMLResponse(
        f"""<!doctype html><meta charset=utf-8><title>ux.replay proxy-embed</title>
        <body style="margin:0;background:#000">
        <iframe src="{src}" style="border:0;width:100vw;height:100vh"
                sandbox="allow-scripts allow-same-origin" allowfullscreen
                referrerpolicy="no-referrer"></iframe></body>""")


@app.websocket(PREFIX + "/replay")
async def ws_replay(client_ws: WebSocket):
    await client_ws.accept()
    async with websockets.connect(f"{GAME_WS}/replay", max_size=None) as up:
        async def c2u():
            # client → game: preserve binary vs text (broadcast_core sends binary).
            try:
                while True:
                    msg = await client_ws.receive()
                    if msg.get("type") == "websocket.disconnect":
                        break
                    if msg.get("bytes") is not None:
                        await up.send(msg["bytes"])
                    elif msg.get("text") is not None:
                        await up.send(msg["text"])
            except Exception:
                pass
        async def u2c():
            # game → client: bytes frames stay bytes, str frames stay text.
            try:
                async for msg in up:
                    if isinstance(msg, (bytes, bytearray)):
                        await client_ws.send_bytes(bytes(msg))
                    else:
                        await client_ws.send_text(msg)
            except Exception:
                pass
        await asyncio.gather(c2u(), u2c())


@app.get(PREFIX + "/{path:path}")
def http_proxy(path: str, request: Request):
    qs = request.url.query
    target = f"{GAME}/{path}" + (f"?{qs}" if qs else "")
    with urllib.request.urlopen(urllib.request.Request(target), timeout=30) as r:
        body, ctype = r.read(), r.headers.get("content-type", "application/octet-stream")
    if "text/html" in ctype.lower():
        pb = f"{PREFIX}/".encode()
        body, n = re.subn(rb'(<base\b[^>]*\bhref=")[^"]*(")',
                          lambda m: m.group(1) + pb + m.group(2), body, count=1)
    return Response(content=body, media_type=ctype)


if __name__ == "__main__":
    print(f"[proxy] mirroring {GAME} under {PREFIX}/ (BINARY WS)")
    print(f"[proxy]   bare iframe:  http://127.0.0.1:{PORT}/embed?path=client/replay")
    uvicorn.run(app, host="127.0.0.1", port=PORT, log_level="warning")
