#!/usr/bin/env node
// Board art batch for the CTF arena replay. ONE locked style sentence across every
// asset (coherence via the STYLE string, per L46 — NOT a shared seed, which would
// over-lock identity). Strict top-down so the art footprint aligns to the collision
// shape (crew are viewed straight down; an isometric object would float off its box).
// Each call is a separate nanobanana generation → distinct drawing, same hand.
//
// Usage: node scripts/art/gen_batch.mjs [only=key,key]
import { spawn } from "node:child_process";
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import path from "node:path";

const OUT = path.join(process.cwd(), "art/gen");
const settings = JSON.parse(readFileSync(path.join(homedir(), ".gemini/settings.json"), "utf8"));
const key = process.env.GEMINI_API_KEY || settings.apiKey;
const SERVER = path.join(homedir(), ".gemini/extensions/nanobanana/mcp-server/dist/index.js");

// The coherence lock: identical suffix on every prompt.
const STYLE =
  "hand-illustrated painterly game art, warm torch-lit dungeon palette of warm charcoal-brown with " +
  "ember-orange rim light, STRICT TOP-DOWN orthographic bird's-eye view seen from directly overhead " +
  "(minimal side face, flat-lay footprint that fills the frame), soft ambient-occlusion contact shadow, " +
  "isolated single object centered on a plain flat dark near-black background, no text, no border, no grid.";

const SEAMLESS =
  "hand-illustrated painterly game art, warm torch-lit dungeon palette of warm charcoal-brown, top-down, " +
  "seamless perfectly tileable, even lighting edge-to-edge, no vignette, no objects, no text, no border.";

const ASSETS = [
  { key: "wall",       prompt: "Seamless tileable rough dungeon stone-block wall surface, chunky masonry blocks with dark mortar seams and torch-warm highlights. " + SEAMLESS },
  { key: "crate",      prompt: "A single sturdy square wooden crate with iron corner brackets and cross-slats, viewed from straight above so the lid fills the frame as a square. " + STYLE },
  { key: "barrel",     prompt: "A single riveted metal fuel drum barrel viewed from straight above so the circular lid fills the frame as a disc, iron hoops at the rim. " + STYLE },
  { key: "barricade",  prompt: "A single low stacked barricade of stone slabs and timber beams forming a short thick wall segment, viewed from straight above as a rectangle. " + STYLE },
  { key: "machinery",  prompt: "A single chunky angled block of iron pipes gears and rivets, industrial machinery cover, viewed from straight above as a compact diagonal block. " + STYLE },
  { key: "ped_red",    prompt: "A circular raised flag pedestal dais of carved stone with a glowing vermillion-red emblem inlay and faint red glow, viewed from straight above as a disc. " + STYLE },
  { key: "ped_blue",   prompt: "A circular raised flag pedestal dais of carved stone with a glowing cerulean-blue emblem inlay and faint blue glow, viewed from straight above as a disc. " + STYLE },
];

function gen(prompt, seed) {
  return new Promise((resolve) => {
    const child = spawn(process.execPath, [SERVER], {
      cwd: OUT,
      env: { ...process.env, NANOBANANA_API_KEY: key, NANOBANANA_MODEL: "gemini-2.5-flash-image" },
      stdio: ["pipe", "pipe", "inherit"],
    });
    let buf = "";
    const send = (o) => child.stdin.write(JSON.stringify(o) + "\n");
    child.stdout.on("data", (d) => {
      buf += d.toString();
      let nl;
      while ((nl = buf.indexOf("\n")) >= 0) {
        const line = buf.slice(0, nl).trim(); buf = buf.slice(nl + 1);
        if (!line) continue;
        let m; try { m = JSON.parse(line); } catch { continue; }
        if (m.id === 1) send({ jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "generate_image", arguments: { prompt, seed } } });
        else if (m.id === 2) { const t = m.result?.content?.map((c) => c.text).join("\n") ?? ""; child.kill(); resolve(t); }
      }
    });
    send({ jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2024-11-05", capabilities: {}, clientInfo: { name: "nb", version: "1" } } });
    send({ jsonrpc: "2.0", method: "notifications/initialized", params: {} });
    setTimeout(() => { child.kill(); resolve("TIMEOUT"); }, 180000);
  });
}

const onlyArg = (process.argv.find((a) => a.startsWith("only=")) || "").slice(5);
const only = onlyArg ? new Set(onlyArg.split(",")) : null;
let seed = 20;
for (const a of ASSETS) {
  if (only && !only.has(a.key)) continue;
  process.stdout.write(`[gen] ${a.key} … `);
  const out = await gen(a.prompt, seed++);
  const file = (out.match(/Image saved to: (.+\.png)/) || [])[1] || out.split("\n").filter(Boolean).pop();
  console.log(file || "(no file)");
}
console.log("done.");
