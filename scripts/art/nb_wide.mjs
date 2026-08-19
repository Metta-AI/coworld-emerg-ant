#!/usr/bin/env node
// NATIVE-WIDE image generation — the fix for the "square backdrop in a wide frame" bug. The nanobanana
// MCP wrapper only exposes {prompt, seed} and always returns 1024², but the underlying Gemini image model
// (gemini-2.5-flash-image) accepts an aspect ratio via generationConfig.imageConfig.aspectRatio. Call it
// DIRECTLY so the backdrop is painted WIDE (matching the real Observatory frame, ~1.2–2.6 aspect) instead
// of a square cropped/zoomed into a wide viewport.
//
// Usage: node nb_wide.mjs <outFile.png> <aspect e.g. 21:9> <prompt...>
import { readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import path from "node:path";

const [, , outFile, aspect, ...pw] = process.argv;
if (!outFile || !aspect || !pw.length) { console.error("usage: nb_wide.mjs <outFile.png> <aspect> <prompt...>"); process.exit(2); }
const prompt = pw.join(" ");

const settings = JSON.parse(readFileSync(path.join(homedir(), ".gemini/settings.json"), "utf8"));
const key = process.env.GEMINI_API_KEY || settings.apiKey;
if (!key) { console.error("no api key"); process.exit(2); }

const model = process.env.NANOBANANA_MODEL || "gemini-2.5-flash-image";
const url = `https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=${key}`;
const body = {
  contents: [{ parts: [{ text: prompt }] }],
  generationConfig: { responseModalities: ["IMAGE"], imageConfig: { aspectRatio: aspect } },
};

const r = await fetch(url, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });
const j = await r.json();
if (!r.ok) { console.error("HTTP", r.status, JSON.stringify(j).slice(0, 800)); process.exit(1); }
const img = (j.candidates?.[0]?.content?.parts || []).find((p) => p.inlineData)?.inlineData;
if (!img) { console.error("no image in response:", JSON.stringify(j).slice(0, 800)); process.exit(1); }
writeFileSync(outFile, Buffer.from(img.data, "base64"));
console.log("WROTE", outFile, "mime", img.mimeType);
