#!/usr/bin/env node
// nanobanana EDIT (img2img) — relight/vary an EXISTING image while keeping its composition.
// Used to make a true NIGHT twin of the day plaza (baked moon + real cast shadows), and to spin
// compositionally-identical variants with small intentional differences.
// Usage: node nb_edit.mjs <outDir> <inputImagePath> <prompt>
import { spawn } from "node:child_process";
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import path from "node:path";

const [, , outDir, inputImage, prompt] = process.argv;
if (!outDir || !inputImage || !prompt) { console.error("usage: nb_edit.mjs <outDir> <inputImage> <prompt>"); process.exit(2); }

const settings = JSON.parse(readFileSync(path.join(homedir(), ".gemini/settings.json"), "utf8"));
const key = process.env.GEMINI_API_KEY || settings.apiKey;
if (!key) { console.error("no api key"); process.exit(2); }

const SERVER = path.join(homedir(), ".gemini/extensions/nanobanana/mcp-server/dist/index.js");
const child = spawn(process.execPath, [SERVER], {
  cwd: outDir,
  env: { ...process.env, NANOBANANA_API_KEY: key, NANOBANANA_MODEL: process.env.NANOBANANA_MODEL || "gemini-2.5-flash-image" },
  stdio: ["pipe", "pipe", "inherit"],
});

let buf = "", done = false;
const send = (obj) => child.stdin.write(JSON.stringify(obj) + "\n");
child.stdout.on("data", (d) => {
  buf += d.toString(); let nl;
  while ((nl = buf.indexOf("\n")) >= 0) {
    const line = buf.slice(0, nl).trim(); buf = buf.slice(nl + 1);
    if (!line) continue; let msg; try { msg = JSON.parse(line); } catch { continue; }
    if (msg.id === 1) {
      send({ jsonrpc: "2.0", id: 2, method: "tools/call",
        params: { name: "edit_image", arguments: { prompt, file: inputImage } } });
    } else if (msg.id === 2) {
      done = true;
      console.log(msg.result?.content?.map((c) => c.text).join("\n") ?? JSON.stringify(msg.result ?? msg.error));
      child.kill(); process.exit(msg.error ? 1 : 0);
    }
  }
});
send({ jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2024-11-05", capabilities: {}, clientInfo: { name: "nbedit", version: "1" } } });
send({ jsonrpc: "2.0", method: "notifications/initialized", params: {} });
setTimeout(() => { if (!done) { console.error("TIMEOUT"); child.kill(); process.exit(3); } }, 180000);
