#!/usr/bin/env node
// Regression test for the sprite-protocol client's handling of failed snappy
// sprite decodes (client/broadcast_core.js), driving the REAL client core
// under Node with minimal DOM stubs. Two contracts:
//
// 1. NO PARSER DESYNC: a sprite message whose snappy payload fails to decode
//    is skipped by its length header and every later message in the same
//    packet still applies. The pre-fix client fell back to the legacy raw
//    advance (width*height bytes), desyncing the parser and silently
//    discarding the rest of the packet — on the map layer that meant
//    permanent black stripes, because map bands are sent exactly once per
//    viewer (the 2026-08-01 paintbot league stripe reports).
//
// 2. SELF-HEAL: the failed sprite's compressed payload is retained and
//    re-decoded on a later composite, so a transiently-lost band repairs
//    itself instead of staying black forever.
//
// Usage: node tools/qa_band_desync.cjs
'use strict';
const fs = require('fs');
const path = require('path');

let failures = 0;
function check(name, cond) {
  console.log((cond ? 'PASS' : 'FAIL') + ': ' + name);
  if (!cond) failures = 1;
}

// ---- minimal DOM for broadcast_core.js ----
const rafQueue = [];
const createdCanvases = [];
function makeCanvas() {
  const canvas = {
    width: 64, height: 64, clientWidth: 64, clientHeight: 64,
    lastImage: null,
  };
  canvas.getContext = () => ({
    canvas,
    imageSmoothingEnabled: false,
    fillStyle: '#000',
    createImageData: (w, h) =>
      ({ width: w, height: h, data: new Uint8ClampedArray(w * h * 4) }),
    putImageData: (img) => { canvas.lastImage = img; },
    clearRect() {}, fillRect() {}, drawImage() {},
    save() {}, restore() {}, scale() {}, translate() {},
  });
  createdCanvases.push(canvas);
  return canvas;
}
const windowStub = {
  devicePixelRatio: 1,
  location: { href: 'http://localhost/replay' },
  requestAnimationFrame: (cb) => { rafQueue.push(cb); return rafQueue.length; },
  cancelAnimationFrame: () => {},
  addEventListener() {},
};
const documentStub = { createElement: () => makeCanvas() };

const src = fs.readFileSync(
  path.join(__dirname, '..', 'client', 'broadcast_core.js'), 'utf8');
new Function(
  'window', 'document', 'requestAnimationFrame', 'cancelAnimationFrame',
  'WebSocket', src
)(windowStub, documentStub, windowStub.requestAnimationFrame,
  windowStub.cancelAnimationFrame, function () {});

function flushRaf() {
  while (rafQueue.length) rafQueue.shift()(performance.now());
}

// The composited layer image is whatever the core last putImageData'd into a
// canvas it created via document.createElement.
function layerImage() {
  for (const c of createdCanvases) {
    if (c.lastImage && c.lastImage.width === LAYER_W) return c.lastImage;
  }
  return null;
}
function rowRgba(y) {
  const img = layerImage();
  if (!img) return [0, 0, 0, 0];
  const o = y * img.width * 4;
  return [img.data[o], img.data[o + 1], img.data[o + 2], img.data[o + 3]];
}
function isColor(rgba, r, g, b) {
  return rgba[0] === r && rgba[1] === g && rgba[2] === b && rgba[3] === 255;
}
function isBlank(rgba) { return rgba[3] === 0; }

// ---- packet building (bitworld sprite protocol v1) ----
function u16(v) { return [v & 255, (v >> 8) & 255]; }
function i16(v) { return u16(v & 0xffff); }
function u32(v) { return [v & 255, (v >> 8) & 255, (v >> 16) & 255, (v >>> 24) & 255]; }
function spriteMsg(id, w, h, compressed, label) {
  const labelBytes = [...label].map((c) => c.charCodeAt(0));
  return [1, ...u16(id), ...u16(w), ...u16(h),
    ...u32(compressed.length), ...compressed,
    ...u16(labelBytes.length), ...labelBytes];
}
function objectMsg(id, x, y, z, layer, spriteId) {
  return [2, ...u16(id), ...i16(x), ...i16(y), ...i16(z), layer, ...u16(spriteId)];
}

const W = 16, H = 8, LAYER_W = 16, LAYER_H = 24;
const BAND_Z = -32768;
function solidRgba(r, g, b) {
  const px = new Uint8Array(W * H * 4);
  for (let i = 0; i < W * H; i++) {
    px[i * 4] = r; px[i * 4 + 1] = g; px[i * 4 + 2] = b; px[i * 4 + 3] = 255;
  }
  return px;
}
const compress = (rgba) => Array.from(windowStub.SnappyJS.compress(rgba));

// Three full-width bands A/B/C at y = 0/8/16, ids from the server's
// MapBandSpriteBase/MapBandObjectBase pools, band z so they read as static.
const bandA = compress(solidRgba(255, 0, 0));
const bandB = compress(solidRgba(0, 255, 0));
const bandC = compress(solidRgba(0, 0, 255));
function initPacket(bandBPayload) {
  return Uint8Array.from([
    6, 0, 0, 1,                             // layer 0: map type, zoomable
    5, 0, ...u16(LAYER_W), ...u16(LAYER_H), // viewport 16x24
    ...spriteMsg(30, W, H, bandA, 'map band 0'),
    ...objectMsg(40, 0, 0, BAND_Z, 0, 30),
    ...spriteMsg(31, W, H, bandBPayload, 'map band 1'),
    ...objectMsg(41, 0, 8, BAND_Z, 0, 31),
    ...spriteMsg(32, W, H, bandC, 'map band 2'),
    ...objectMsg(42, 0, 16, BAND_Z, 0, 32),
  ]);
}

// ================= scenario 1: permanently corrupt band B =================
// An absurd uncompressed-length varint makes SnappyJS throw deterministically
// while the MESSAGE structure (length header, label) stays valid.
const bandBCorrupt = bandB.slice();
bandBCorrupt.splice(0, 1, 0xff);
bandBCorrupt.splice(1, 0, 0xff, 0xff, 0xff, 0x0f);

{
  const core = windowStub.BroadcastCore.create({
    canvas: makeCanvas(), websocket: false, playoutBuffer: false,
  });
  core.ingest(initPacket(bandBCorrupt));
  flushRaf();
  check('corrupt band skipped: band A still drawn', isColor(rowRgba(0), 255, 0, 0));
  check('corrupt band skipped: its own rows blank', isBlank(rowRgba(8)));
  check('NO DESYNC: band C after the corrupt one is drawn', isColor(rowRgba(16), 0, 0, 255));
  core.stop();
  createdCanvases.length = 0;
}

// ================= scenario 2: transient decode failure heals =============
// Fail band B's first decode only (an allocation-failure stand-in), then let
// the retained compressed payload decode on a later composite.
{
  // Two injected failures: the arrival decode AND the first composite's
  // retry sweep (which runs before any assertion can see a blank band).
  const realUncompress = windowStub.SnappyJS.uncompress;
  let bFailures = 2;
  windowStub.SnappyJS.uncompress = (compressed, expected) => {
    if (bFailures > 0 && compressed.length === bandB.length &&
        compressed[compressed.length - 1] === bandB[bandB.length - 1] &&
        realUncompress(compressed, expected)[1] === 255) {
      bFailures--;
      throw new Error('injected transient allocation failure');
    }
    return realUncompress(compressed, expected);
  };

  const core = windowStub.BroadcastCore.create({
    canvas: makeCanvas(), websocket: false, playoutBuffer: false,
  });
  core.ingest(initPacket(bandB));
  flushRaf();
  check('transient failure: band B blank on first composite', isBlank(rowRgba(8)));
  check('transient failure: bands A and C drawn', isColor(rowRgba(0), 255, 0, 0) && isColor(rowRgba(16), 0, 0, 255));

  // Any later packet dirties the frame; the composite's retry sweep must
  // recover band B from its retained compressed payload.
  core.ingest(Uint8Array.from(objectMsg(42, 0, 16, BAND_Z, 0, 32)));
  flushRaf();
  check('SELF-HEAL: band B drawn after retry', isColor(rowRgba(8), 0, 255, 0));
  core.stop();
  windowStub.SnappyJS.uncompress = realUncompress;
}

process.exit(failures);
