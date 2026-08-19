#!/usr/bin/env node
// Direct nanobanana MCP client — speaks stdio JSON-RPC straight to the nanobanana
// MCP server (the path the onboarding doc intends: "you call the MCP tools
// directly"), bypassing the `gemini` agent loop whose routing classifier was the
// thing 503'ing. Reads GEMINI_API_KEY from ~/.gemini/settings.json (never echoes).
//
// Usage: node nb.mjs <outDir> <prompt> [seed]
import { spawn } from "node:child_process";
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import path from "node:path";

const [, , outDir, prompt, seedArg] = process.argv;
if (!outDir || !prompt) { console.error("usage: nb.mjs <outDir> <prompt> [seed]"); process.exit(2); }

// API key from gemini settings.json (env var isn't set in this shell)
const settings = JSON.parse(readFileSync(path.join(homedir(), ".gemini/settings.json"), "utf8"));
const key = process.env.GEMINI_API_KEY || settings.apiKey;
if (!key) { console.error("no api key"); process.exit(2); }

const SERVER = path.join(homedir(), ".gemini/extensions/nanobanana/mcp-server/dist/index.js");

const child = spawn(process.execPath, [SERVER], {
  cwd: outDir,
  env: { ...process.env, NANOBANANA_API_KEY: key, NANOBANANA_MODEL: process.env.NANOBANANA_MODEL || "gemini-2.5-flash-image" },
  stdio: ["pipe", "pipe", "inherit"],
});

let buf = "";
let done = false;
const send = (obj) => child.stdin.write(JSON.stringify(obj) + "\n");

child.stdout.on("data", (d) => {
  buf += d.toString();
  let nl;
  while ((nl = buf.indexOf("\n")) >= 0) {
    const line = buf.slice(0, nl).trim();
    buf = buf.slice(nl + 1);
    if (!line) continue;
    let msg;
    try { msg = JSON.parse(line); } catch { continue; }
    if (msg.id === 1) {
      // initialized → call generate_image
      send({
        jsonrpc: "2.0", id: 2, method: "tools/call",
        params: { name: "generate_image", arguments: { prompt, ...(seedArg ? { seed: Number(seedArg) } : {}) } },
      });
    } else if (msg.id === 2) {
      done = true;
      const text = msg.result?.content?.map((c) => c.text).join("\n") ?? JSON.stringify(msg.result ?? msg.error);
      console.log(text);
      child.kill();
      process.exit(msg.error ? 1 : 0);
    }
  }
});

// MCP handshake
send({ jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2024-11-05", capabilities: {}, clientInfo: { name: "nb", version: "1" } } });
send({ jsonrpc: "2.0", method: "notifications/initialized", params: {} });

setTimeout(() => { if (!done) { console.error("TIMEOUT"); child.kill(); process.exit(3); } }, 180000);
