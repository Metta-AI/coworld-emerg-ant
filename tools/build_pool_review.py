#!/usr/bin/env python3
"""Builds docs/pool-review.html: a self-contained, zoomable review page for
the curated terrain pool. Reads the PNGs + manifest.json produced by
tools/render_map_pool.nim and inlines everything (base64), so the page works
from a file:// open or any static host.

Usage:
  nim c -r tools/gen_map_pool.nim            # (only when re-curating seeds)
  nim c -r tools/render_map_pool.nim pool-preview
  python3 tools/build_pool_review.py [renderDir] [outHtml]

Defaults: renderDir=pool-preview, outHtml=docs/pool-review.html.
"""
import base64
import json
import pathlib
import sys

repo = pathlib.Path(__file__).resolve().parent.parent
render_dir = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else repo / "pool-preview"
out_path = pathlib.Path(sys.argv[2]) if len(sys.argv) > 2 else repo / "docs" / "pool-review.html"

manifest = json.loads((render_dir / "manifest.json").read_text())
SIZE_NAMES = {1050: "small", 1235: "standard", 1606: "large",
              2223: "huge", 3211: "giant"}

cards = []
for m in manifest:
    b64 = base64.b64encode((render_dir / m["file"]).read_bytes()).decode()
    size = SIZE_NAMES[m["width"]]
    kits = ", ".join(f"({x},{y})" for x, y in m["medKitSpawns"])
    endzone = m.get("endzone", "column")
    zone_note = (
        f"{endzone} r{m['endzoneRadius']} home x{m['homeX']}"
        if endzone != "column" else f"column home x{m.get('homeX', '?')}")
    cards.append(f'''
<article class="card" data-size="{size}" data-sym="{m['symmetry']}" data-endzone="{endzone}">
  <header class="card-head">
    <span class="idx">#{m['index']:02d}</span>
    <span class="seed">seed {m['seed']}</span>
    <span class="chip chip-{size}">{size} {m['width']}&times;{m['height']}</span>
    <span class="chip chip-sym">{m['symmetry']}</span>
    <span class="chip chip-sym">{zone_note}</span>
    <span class="meta">{m['obstacles']} left-half shapes &middot; {m.get('trenches', 0)} trenches &middot; kits {kits}</span>
  </header>
  <div class="viewer" tabindex="0">
    <img src="data:image/png;base64,{b64}" alt="pool map {m['index']} seed {m['seed']}" draggable="false">
  </div>
</article>''')

counts = {"small": 0, "standard": 0, "large": 0, "huge": 0, "giant": 0,
          "mirror": 0, "rot180": 0, "column": 0, "disc": 0, "square": 0}
for m in manifest:
    counts[SIZE_NAMES[m["width"]]] += 1
    counts[m["symmetry"]] += 1
    counts[m.get("endzone", "column")] += 1

html = f'''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>CTF Terrain Pool</title>
<style>
:root {{
  --ground:#1a1410; --panel:#241c15; --line:#3a2e21;
  --ink:#e8dcc8; --muted:#9a8a70;
  --glass:#50dcff; --red:#d24238; --blue:#4a78dc;
}}
* {{ box-sizing:border-box; }}
body {{ background:var(--ground); color:var(--ink);
  font:15px/1.5 system-ui,-apple-system,sans-serif; margin:0; padding:0 0 4rem; }}
.wrap {{ max-width:1500px; margin:0 auto; padding:0 1.25rem; }}
header.top {{ position:sticky; top:0; z-index:5; background:color-mix(in srgb,var(--ground) 92%,transparent);
  backdrop-filter:blur(6px); border-bottom:1px solid var(--line); padding:.7rem 0 .6rem; margin-bottom:1.2rem; }}
h1 {{ font-size:1.05rem; margin:0; letter-spacing:.02em; display:inline; }}
h1 .gv {{ color:var(--glass); }}
.sub {{ color:var(--muted); font:12px ui-monospace,Menlo,monospace; margin-left:.8rem; }}
.filters {{ float:right; display:flex; gap:.4rem; }}
.filters button {{ background:var(--panel); color:var(--ink); border:1px solid var(--line);
  border-radius:3px; font:12px ui-monospace,Menlo,monospace; padding:.25rem .6rem; cursor:pointer; }}
.filters button[aria-pressed="true"] {{ border-color:var(--glass); color:var(--glass); }}
.legend {{ display:flex; flex-wrap:wrap; gap:1rem; font:12px ui-monospace,Menlo,monospace;
  color:var(--muted); margin:0 0 1.2rem; }}
.legend b {{ display:inline-block; width:11px; height:11px; margin-right:.35rem; vertical-align:-1px; }}
.grid {{ display:grid; grid-template-columns:repeat(auto-fill,minmax(620px,1fr)); gap:1.2rem; }}
.card {{ background:var(--panel); border:1px solid var(--line); border-radius:4px; overflow:hidden; }}
.card.hidden {{ display:none; }}
.card-head {{ display:flex; align-items:baseline; gap:.65rem; padding:.5rem .75rem;
  font:12px ui-monospace,Menlo,monospace; border-bottom:1px solid var(--line); flex-wrap:wrap; }}
.idx {{ color:var(--glass); font-weight:700; }}
.seed {{ font-weight:700; }}
.chip {{ border:1px solid var(--line); border-radius:2px; padding:0 .4rem; color:var(--muted); }}
.chip-sym {{ color:var(--ink); }}
.meta {{ color:var(--muted); margin-left:auto; }}
.viewer {{ position:relative; height:420px; overflow:hidden; cursor:grab; background:#0f0b08; }}
.viewer:active {{ cursor:grabbing; }}
.viewer img {{ position:absolute; transform-origin:0 0; image-rendering:pixelated;
  user-select:none; -webkit-user-drag:none; }}
.hint {{ text-align:center; color:var(--muted); font:12px ui-monospace,Menlo,monospace; margin:.9rem 0 1.1rem; }}
</style>
</head>
<body>
<div class="wrap">
<header class="top"><div>
  <h1>CTF terrain pool <span class="gv">config-gated (mapPath "pool")</span></h1>
  <span class="sub">{len(manifest)} maps &middot; {counts['small']} small / {counts['standard']} standard / {counts['large']} large / {counts['huge']} huge / {counts['giant']} giant &middot; {counts['mirror']} mirror / {counts['rot180']} rot180 &middot; {counts['column']} column / {counts['disc']} disc / {counts['square']} square endzones</span>
  <span class="filters">
    <button data-f="size:small" aria-pressed="false">small</button>
    <button data-f="size:standard" aria-pressed="false">standard</button>
    <button data-f="size:large" aria-pressed="false">large</button>
    <button data-f="size:huge" aria-pressed="false">huge</button>
    <button data-f="size:giant" aria-pressed="false">giant</button>
    <button data-f="sym:mirror" aria-pressed="false">mirror</button>
    <button data-f="sym:rot180" aria-pressed="false">rot180</button>
    <button data-f="endzone:column" aria-pressed="false">column</button>
    <button data-f="endzone:disc" aria-pressed="false">disc</button>
    <button data-f="endzone:square" aria-pressed="false">square</button>
  </span>
</div></header>
<p class="hint">scroll to zoom &middot; drag to pan &middot; double-click to reset &middot; filters narrow the grid &middot; regenerate: tools/render_map_pool.nim + tools/build_pool_review.py</p>
<div class="legend">
  <span><b style="background:#40301f"></b>stone</span>
  <span><b style="background:#50dcff"></b>glass window (blocks movement/fire, fog sees through)</span>
  <span><b style="background:#e2cdac"></b>protected floor (never carved: center ring + each team's endzone — a home column, or a disc/square around a base set back from the edge)</span>
  <span><b style="background:#d24238"></b>active med-kit pair / red pedestal</span>
  <span><b style="background:#78644e"></b>idle med-kit candidates</span>
  <span><b style="background:#4a78dc"></b>blue pedestal</span>
</div>
<div class="grid">
{''.join(cards)}
</div>
</div>
<script>
document.querySelectorAll('.viewer').forEach(v => {{
  const img = v.querySelector('img');
  let s, tx, ty, dragging = false, lx = 0, ly = 0;
  function fit() {{
    const iw = img.naturalWidth, ih = img.naturalHeight;
    s = Math.min(v.clientWidth / iw, v.clientHeight / ih);
    tx = (v.clientWidth - iw * s) / 2; ty = (v.clientHeight - ih * s) / 2;
    apply();
  }}
  function apply() {{
    img.style.transform = `translate(${{tx}}px,${{ty}}px) scale(${{s}})`;
  }}
  if (img.complete) fit(); else img.onload = fit;
  window.addEventListener('resize', fit);
  v.addEventListener('dblclick', fit);
  v.addEventListener('wheel', e => {{
    e.preventDefault();
    const r = v.getBoundingClientRect();
    const mx = e.clientX - r.left, my = e.clientY - r.top;
    const k = Math.exp(-e.deltaY * 0.0015);
    const ns = Math.min(Math.max(s * k, 0.1), 12);
    tx = mx - (mx - tx) * (ns / s); ty = my - (my - ty) * (ns / s);
    s = ns; apply();
  }}, {{ passive: false }});
  v.addEventListener('pointerdown', e => {{
    dragging = true; lx = e.clientX; ly = e.clientY; v.setPointerCapture(e.pointerId);
  }});
  v.addEventListener('pointermove', e => {{
    if (!dragging) return;
    tx += e.clientX - lx; ty += e.clientY - ly; lx = e.clientX; ly = e.clientY; apply();
  }});
  v.addEventListener('pointerup', () => dragging = false);
}});
const active = {{ size: null, sym: null, endzone: null }};
document.querySelectorAll('.filters button').forEach(b => {{
  b.addEventListener('click', () => {{
    const [k, val] = b.dataset.f.split(':');
    active[k] = active[k] === val ? null : val;
    document.querySelectorAll('.filters button').forEach(o => {{
      const [ok, ov] = o.dataset.f.split(':');
      o.setAttribute('aria-pressed', String(active[ok] === ov));
    }});
    document.querySelectorAll('.card').forEach(c => {{
      const okSize = !active.size || c.dataset.size === active.size;
      const okSym = !active.sym || c.dataset.sym === active.sym;
      const okZone = !active.endzone || c.dataset.endzone === active.endzone;
      c.classList.toggle('hidden', !(okSize && okSym && okZone));
    }});
  }});
}});
</script>
</body>
</html>
'''
out_path.parent.mkdir(parents=True, exist_ok=True)
out_path.write_text(html)
print(f"wrote {out_path} ({len(html)} bytes, {len(manifest)} maps)")
