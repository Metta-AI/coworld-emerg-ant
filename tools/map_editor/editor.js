// Browser UI for the local CTF map editor (tools/map_editor.nim).
// Demo/curation tooling; NOT part of the server or the replay viewer.
//
// This file never computes geometry. Walls, symmetry images, capture zones and
// validity all come from the Nim service; the browser renders its PNG and draws
// annotations on top. See docs/designs/map-editor.md.

const $ = (id) => document.getElementById(id);

const OVERLAY_ORDER = [
  'protected',
  'pickups',
  'spin',
  'seedRegion',
  'sightlines',
  'reachability',
];

const TEAM_COLORS = {
  red: '#b9473a',
  blue: '#3f6f9f',
  green: '#3f7855',
  yellow: '#a47b25',
};

const MARKER_COLORS = {
  grenade: '#8c552d',
  shield: '#3f6f9f',
  plasmaArc: '#1e8395',
  medKitActive: '#b9473a',
  medKitCandidate: '#74675a',
  spinningDiamond: '#b9782d',
  trench: '#80674f',
};

function cloneJson(value) {
  return JSON.parse(JSON.stringify(value));
}

function formatInteger(value) {
  return new Intl.NumberFormat('en-US', { maximumFractionDigits: 0 }).format(value);
}

function formatPoint(x, y) {
  return `(${formatInteger(x)}, ${formatInteger(y)}) px`;
}

function humanizeToken(value) {
  return String(value || '')
    .replace(/([a-z])([A-Z])/g, '$1 $2')
    .replace(/[_-]+/g, ' ')
    .replace(/^./, (letter) => letter.toUpperCase());
}

function fileSafeName(name) {
  const safe = String(name || 'ctf-map')
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-|-$/g, '');
  return `${safe || 'ctf-map'}.json`;
}

function groupSightlineRows(values) {
  const rows = [...new Set((values || []).filter(Number.isInteger))].sort((a, b) => a - b);
  const groups = [];
  for (const row of rows) {
    const current = groups.at(-1);
    if (current && row === current.at(-1) + 4) current.push(row);
    else groups.push([row]);
  }
  return groups;
}

function isInteractiveTarget(target) {
  return target instanceof Element && Boolean(target.closest(
    'input, textarea, select, button, [contenteditable="true"], [role="tab"]',
  ));
}

class MapEditorApi {
  async requestJson(path, options = {}) {
    const response = await fetch(path, {
      headers: { 'Content-Type': 'application/json' },
      ...options,
    });

    let payload;
    try {
      payload = await response.json();
    } catch (error) {
      throw new Error(`The local service returned non-JSON data (${response.status}).`);
    }

    if (!response.ok) {
      const detail = payload && payload.error ? payload.error : response.statusText;
      throw new Error(`HTTP ${response.status}: ${detail}`);
    }
    return payload;
  }

  getPool() {
    return this.requestJson('/api/pool');
  }

  getPoolMap(index) {
    return this.requestJson(`/api/pool/${index}`);
  }

  generate(request) {
    return this.requestJson('/api/generate', {
      method: 'POST',
      body: JSON.stringify(request),
    });
  }

  render(request) {
    return this.requestJson('/api/map', {
      method: 'POST',
      body: JSON.stringify(request),
    });
  }

  symmetry(request) {
    return this.requestJson('/api/symmetry', {
      method: 'POST',
      body: JSON.stringify(request),
    });
  }
}

// Mock mode is intentionally a separate API implementation. Its bitmap is fixed
// canned artwork, not a JavaScript interpretation of arbitrary map geometry.
const MOCK_SPEC = {
  name: 'mock-pool-00',
  genSeed: 1001,
  width: 1235,
  height: 659,
  flagRing: 70,
  captureClear: 210,
  spawnClearW: 70,
  spawnClearH: 130,
  gunRange: 1050,
  symmetry: 'mirror',
  layout: 'sides',
  endzone: 'square',
  endzoneRadius: 140,
  homeDepth: 700,
  medKitSpawns: [[617, 219], [617, 439]],
  medKitCandidates: [[617, 219], [617, 439], [617, 286], [617, 372]],
  trenches: [[250, 110, 56, 56], [929, 493, 56, 56]],
  leftObstacles: [
    { kind: 'rect', x: 245, y: 70, w: 18, h: 152 },
    { kind: 'diamond', cx: 405, cy: 167, r: 28 },
    { kind: 'disc', cx: 489, cy: 329, r: 28, window: true },
    { kind: 'diagonal', x0: 530, y0: 430, x1: 577, y1: 487, t: 12 },
  ],
};

const MOCK_DERIVED = {
  teamCount: 2,
  seedRegion: { x: 0, y: 0, w: 617, h: 659 },
  anchors: [
    { team: 'red', x: 185, y: 329 },
    { team: 'blue', x: 1049, y: 329 },
  ],
  captureZones: [
    {
      team: 'red', xLo: 45, xHi: 325, yLo: 189, yHi: 469,
      diag: false, cornerX: 0, cornerY: 0, diagLimit: 0,
      disc: false, anchorX: 185, anchorY: 329, radius: 140,
    },
    {
      team: 'blue', xLo: 909, xHi: 1189, yLo: 189, yHi: 469,
      diag: false, cornerX: 0, cornerY: 0, diagLimit: 0,
      disc: false, anchorX: 1049, anchorY: 329, radius: 140,
    },
  ],
  pickups: {
    grenade: [[50, 50], [50, 608], [1184, 50], [1184, 608]],
    shield: [[185, 399], [1049, 259]],
    plasmaArc: [[185, 259], [1049, 399]],
    medKitActive: [[617, 219], [617, 439]],
    medKitCandidate: [[617, 219], [617, 439], [617, 286], [617, 372]],
  },
  spinningDiamonds: [
    { cx: 565, cy: 252, r: 30 },
    { cx: 669, cy: 406, r: 30 },
  ],
  authoredObstacleCount: 34,
  expandedObstacleCount: 68,
};

class MockMapEditorApi {
  async getPool() {
    return { seeds: [1001, 1003, 1007], count: 3 };
  }

  async getPoolMap(index) {
    if (index < 0 || index > 2) {
      return { ok: false, error: `Mock pool index ${index} is out of range.` };
    }
    const spec = cloneJson(MOCK_SPEC);
    spec.name = `mock-pool-${String(index).padStart(2, '0')}`;
    spec.genSeed = [1001, 1003, 1007][index];
    return { ok: true, spec };
  }

  async generate(request) {
    const spec = cloneJson(MOCK_SPEC);
    spec.name = `mock-seed-${request.seed}`;
    spec.genSeed = request.seed;
    return { ok: true, spec };
  }

  async render(request) {
    if (request.spec.width !== MOCK_SPEC.width || request.spec.height !== MOCK_SPEC.height) {
      return {
        ok: false,
        error: 'Mock mode only has canned artwork for a 1235×659 px map.',
      };
    }

    const maxDimension = request.render.maxDimension;
    const scale = maxDimension === 0
      ? 1
      : Math.min(1, maxDimension / Math.max(MOCK_SPEC.width, MOCK_SPEC.height));
    const png = this.createCannedPng(scale, new Set(request.render.overlays));

    return {
      ok: true,
      png,
      renderScale: scale,
      validation: {
        valid: false,
        reason: 'open horizontal sightline at y=412',
        coverPermille: 88,
        minCoverPermille: 74,
        coverPermilleMin: 40,
        coverPermilleMax: 170,
        openSightlineRows: [412, 416, 420, 508],
        sightlineXRange: { xLo: 215, xHi: 1020 },
        redHomeOnOpenFloor: true,
        unreachableTeams: ['blue'],
        centerReachable: true,
        endzoneFlankChecked: false,
        rearGateReachesCenterWithoutEndzone: false,
        endzoneGates: [
          { name: 'above', state: 'open', x: 185, y: 115 },
          { name: 'behind', state: 'sealed', x: 41, y: 329 },
        ],
      },
      derived: { ...cloneJson(MOCK_DERIVED), center: { x: 617, y: 329 } },
    };
  }

  async symmetry(request) {
    // Mock mode proves the client contract and transaction flow only. It does
    // not reproduce Nim's transforms; each supplied seed is a one-member orbit.
    return {
      ok: true,
      trenches: request.trenches.map((rect) => [cloneJson(rect)]),
      medKits: request.medKits.map((point) => [cloneJson(point)]),
    };
  }

  createCannedPng(scale, overlays) {
    const width = Math.ceil(MOCK_SPEC.width * scale);
    const height = Math.ceil(MOCK_SPEC.height * scale);
    const canvas = document.createElement('canvas');
    canvas.width = width;
    canvas.height = height;
    const context = canvas.getContext('2d');
    const px = (value) => value * scale;

    context.fillStyle = '#cdbfa9';
    context.fillRect(0, 0, width, height);
    context.strokeStyle = '#2c2219';
    context.lineWidth = Math.max(2, px(10));
    context.strokeRect(0, 0, width, height);

    if (overlays.has('protected')) {
      context.fillStyle = '#e4d2ad';
      context.beginPath();
      context.arc(px(617), px(329), px(70), 0, Math.PI * 2);
      context.fill();
      context.fillRect(px(45), px(189), px(280), px(280));
      context.fillRect(px(909), px(189), px(280), px(280));
    }

    context.fillStyle = '#493827';
    const rectangles = [
      [245, 70, 18, 152], [245, 437, 18, 152],
      [972, 70, 18, 152], [972, 437, 18, 152],
      [350, 277, 95, 22], [790, 360, 95, 22],
      [530, 430, 58, 14], [647, 215, 58, 14],
    ];
    for (const [x, y, w, h] of rectangles) {
      context.fillRect(px(x), px(y), px(w), px(h));
    }

    context.fillStyle = '#5c4733';
    for (const [x, y] of [[405, 167], [405, 492], [829, 167], [829, 492]]) {
      context.beginPath();
      context.moveTo(px(x), px(y - 28));
      context.lineTo(px(x + 28), px(y));
      context.lineTo(px(x), px(y + 28));
      context.lineTo(px(x - 28), px(y));
      context.closePath();
      context.fill();
    }

    context.fillStyle = '#1e8395';
    context.beginPath();
    context.arc(px(489), px(329), px(28), 0, Math.PI * 2);
    context.fill();
    context.beginPath();
    context.arc(px(745), px(329), px(28), 0, Math.PI * 2);
    context.fill();

    context.fillStyle = '#80674f';
    context.fillRect(px(250), px(110), px(56), px(56));
    context.fillRect(px(929), px(493), px(56), px(56));

    if (overlays.has('sightlines')) {
      context.strokeStyle = '#a33b32';
      context.lineWidth = Math.max(1, px(2));
      for (const y of [412, 416, 420, 508]) {
        context.beginPath();
        context.moveTo(0, px(y));
        context.lineTo(width, px(y));
        context.stroke();
      }
    }

    if (overlays.has('reachability')) {
      context.fillStyle = 'rgba(163, 59, 50, 0.16)';
      context.fillRect(px(820), px(100), px(360), px(459));
    }

    return canvas.toDataURL('image/png').split(',')[1];
  }
}

class EditorStore {
  constructor() {
    this.listeners = new Set();
    this.state = {
      document: {
        spec: null,
        revision: 0,
        loadRevision: 0,
        source: null,
      },
      editing: {
        selection: null,
        previewSpec: null,
        placementPreview: null,
        notice: null,
        undoStack: [],
        redoStack: [],
      },
      controls: {
        overlays: new Set(['protected', 'pickups', 'spin', 'seedRegion']),
        maxDimension: 1600,
        snapToGrid: false,
        gridSize: 8,
      },
      render: {
        pending: false,
        latestRequestedRevision: 0,
        renderedRequestRevision: 0,
        renderedDocumentRevision: 0,
        lastGoodResponse: null,
        lastGoodSpec: null,
        lastGoodOptions: null,
        image: null,
        imageUrl: null,
        error: null,
      },
    };
  }

  subscribe(listener) {
    this.listeners.add(listener);
    listener(this.state);
    return () => this.listeners.delete(listener);
  }

  change(mutator) {
    mutator(this.state);
    for (const listener of this.listeners) {
      listener(this.state);
    }
  }

  setDocument(spec, source) {
    this.change((state) => {
      state.document.spec = cloneJson(spec);
      state.document.source = source;
      state.document.revision += 1;
      state.document.loadRevision += 1;
      state.editing.selection = null;
      state.editing.previewSpec = null;
      state.editing.placementPreview = null;
      state.editing.notice = null;
      state.editing.undoStack = [];
      state.editing.redoStack = [];
      state.render.error = null;
    });
  }

  setSelection(selection) {
    this.change((state) => {
      state.editing.selection = selection ? cloneJson(selection) : null;
      state.editing.placementPreview = null;
      state.editing.notice = null;
    });
  }

  setPreviewSpec(spec) {
    this.change((state) => {
      state.editing.previewSpec = spec ? cloneJson(spec) : null;
    });
  }

  clearPreview() {
    if (!this.state.editing.previewSpec) return;
    this.change((state) => {
      state.editing.previewSpec = null;
    });
  }

  setPlacementPreview(preview) {
    this.change((state) => {
      state.editing.placementPreview = preview ? cloneJson(preview) : null;
    });
  }

  commitSpec(nextSpec, label, nextSelection = this.state.editing.selection) {
    const before = this.state.document.spec;
    if (!before || JSON.stringify(before) === JSON.stringify(nextSpec)) {
      this.clearPreview();
      return false;
    }
    const entry = {
      label,
      before: cloneJson(before),
      after: cloneJson(nextSpec),
      beforeSelection: cloneJson(this.state.editing.selection),
      afterSelection: cloneJson(nextSelection),
    };
    this.change((state) => {
      state.editing.undoStack.push(entry);
      if (state.editing.undoStack.length > 100) state.editing.undoStack.shift();
      state.editing.redoStack = [];
      state.document.spec = cloneJson(nextSpec);
      state.document.revision += 1;
      state.editing.selection = cloneJson(nextSelection);
      state.editing.previewSpec = null;
      state.editing.placementPreview = null;
      state.editing.notice = null;
      state.render.error = null;
    });
    return true;
  }

  undo() {
    if (!this.state.editing.undoStack.length) return false;
    this.change((state) => {
      const entry = state.editing.undoStack.pop();
      state.editing.redoStack.push(entry);
      state.document.spec = cloneJson(entry.before);
      state.document.revision += 1;
      state.editing.selection = this.validSelection(entry.beforeSelection, entry.before);
      state.editing.previewSpec = null;
      state.editing.placementPreview = null;
      state.editing.notice = `Undid ${entry.label}`;
      state.render.error = null;
    });
    return true;
  }

  redo() {
    if (!this.state.editing.redoStack.length) return false;
    this.change((state) => {
      const entry = state.editing.redoStack.pop();
      state.editing.undoStack.push(entry);
      state.document.spec = cloneJson(entry.after);
      state.document.revision += 1;
      state.editing.selection = this.validSelection(entry.afterSelection, entry.after);
      state.editing.previewSpec = null;
      state.editing.placementPreview = null;
      state.editing.notice = `Redid ${entry.label}`;
      state.render.error = null;
    });
    return true;
  }

  validSelection(selection, spec) {
    if (!selection) return null;
    if (selection.type === 'obstacle') {
      return (spec.leftObstacles || [])[selection.index] ? cloneJson(selection) : null;
    }
    if (selection.type === 'trench') {
      return (spec.trenches || []).length ? cloneJson(selection) : null;
    }
    if (selection.type === 'medKit') {
      return (spec.medKitCandidates || []).length ? cloneJson(selection) : null;
    }
    return null;
  }
}

async function decodePng(base64) {
  let bytes;
  try {
    const binary = atob(base64);
    bytes = new Uint8Array(binary.length);
    for (let index = 0; index < binary.length; index += 1) {
      bytes[index] = binary.charCodeAt(index);
    }
  } catch (error) {
    throw new Error('The service returned invalid base64 PNG data.');
  }

  const url = URL.createObjectURL(new Blob([bytes], { type: 'image/png' }));
  const image = new Image();
  image.src = url;
  try {
    await image.decode();
  } catch (error) {
    URL.revokeObjectURL(url);
    throw new Error('The service returned PNG data the browser could not decode.');
  }
  return { image, url };
}

class RenderCoordinator {
  constructor(api, store) {
    this.api = api;
    this.store = store;
    this.timer = null;
    this.pendingRequest = null;
    this.inFlight = false;
    this.requestRevision = 0;
  }

  schedule({ immediate = false } = {}) {
    const state = this.store.state;
    if (!state.document.spec) return;

    this.requestRevision += 1;
    const request = {
      revision: this.requestRevision,
      documentRevision: state.document.revision,
      spec: cloneJson(state.document.spec),
      render: {
        maxDimension: state.controls.maxDimension,
        overlays: OVERLAY_ORDER.filter((name) => state.controls.overlays.has(name)),
      },
    };
    this.pendingRequest = request;
    this.store.change((current) => {
      current.render.latestRequestedRevision = request.revision;
      current.render.pending = true;
      current.render.error = null;
    });

    window.clearTimeout(this.timer);
    if (immediate) {
      this.drain();
      return;
    }
    this.timer = window.setTimeout(() => this.drain(), 150);
  }

  async drain() {
    window.clearTimeout(this.timer);
    if (this.inFlight || !this.pendingRequest) return;

    const request = this.pendingRequest;
    this.pendingRequest = null;
    this.inFlight = true;

    try {
      const response = await this.api.render({ spec: request.spec, render: request.render });
      if (request.revision !== this.requestRevision) return;

      if (!response || response.ok !== true) {
        const message = response && response.error
          ? response.error
          : 'The map service rejected the spec without an error message.';
        this.store.change((state) => {
          state.render.error = { kind: 'domain', message };
        });
        return;
      }

      const decoded = await decodePng(response.png);
      if (request.revision !== this.requestRevision) {
        URL.revokeObjectURL(decoded.url);
        return;
      }

      this.store.change((state) => {
        const previousUrl = state.render.imageUrl;
        state.render.lastGoodResponse = response;
        state.render.lastGoodSpec = request.spec;
        state.render.lastGoodOptions = request.render;
        state.render.image = decoded.image;
        state.render.imageUrl = decoded.url;
        state.render.renderedRequestRevision = request.revision;
        state.render.renderedDocumentRevision = request.documentRevision;
        state.render.error = null;
        if (previousUrl) URL.revokeObjectURL(previousUrl);
      });
    } catch (error) {
      if (request.revision === this.requestRevision) {
        this.store.change((state) => {
          state.render.error = {
            kind: 'transport',
            message: error instanceof Error ? error.message : String(error),
          };
        });
      }
    } finally {
      this.inFlight = false;
      const hasNewerRequest = Boolean(this.pendingRequest);
      this.store.change((state) => {
        state.render.pending = hasNewerRequest;
      });
      if (hasNewerRequest) this.drain();
    }
  }
}

class MapViewport {
  constructor(store) {
    this.store = store;
    this.viewport = $('map-viewport');
    this.mapCanvas = $('map-canvas');
    this.mapContext = this.mapCanvas.getContext('2d');
    this.overlayCanvas = $('overlay-canvas');
    this.overlayContext = this.overlayCanvas.getContext('2d');
    this.emptyState = $('empty-map');
    this.pointerStatus = $('pointer-position');
    this.zoomStatus = $('zoom-status');
    this.image = null;
    this.response = null;
    this.spec = null;
    this.appliedOverlays = new Set();
    this.zoom = 1;
    this.panX = 0;
    this.panY = 0;
    this.fitted = true;
    this.drag = null;
    this.placementController = null;
    this.lastLoadRevision = 0;
    this.labelBounds = [];
    this.editingController = null;
    this.diagnosticTarget = null;

    this.bindEvents();
    this.resizeObserver = new ResizeObserver(() => this.resize());
    this.resizeObserver.observe(this.viewport);
    this.store.subscribe((state) => this.updateFromState(state));
  }

  bindEvents() {
    this.viewport.addEventListener('pointerdown', (event) => {
      if (!this.image || event.button !== 0) return;
      const point = this.screenToSpec(event.clientX, event.clientY);
      if (point && this.editingController
          && this.editingController.pointerDown(event, point)) {
        this.viewport.setPointerCapture(event.pointerId);
        return;
      }
      this.drag = { pointerId: event.pointerId, x: event.clientX, y: event.clientY };
      this.fitted = false;
      this.viewport.classList.add('panning');
      this.viewport.setPointerCapture(event.pointerId);
    });

    this.viewport.addEventListener('pointermove', (event) => {
      this.updatePointerStatus(event);
      if (this.editingController && this.editingController.pointerMove(event)) return;
      if (!this.drag || this.drag.pointerId !== event.pointerId) return;
      this.panX += event.clientX - this.drag.x;
      this.panY += event.clientY - this.drag.y;
      this.drag.x = event.clientX;
      this.drag.y = event.clientY;
      this.applyTransform();
    });

    const endPan = (event) => {
      if (this.editingController && this.editingController.pointerUp(event)) return;
      if (!this.drag || this.drag.pointerId !== event.pointerId) return;
      this.drag = null;
      this.viewport.classList.remove('panning');
    };
    this.viewport.addEventListener('pointerup', endPan);
    this.viewport.addEventListener('pointercancel', endPan);
    this.viewport.addEventListener('pointerleave', () => {
      if (!this.drag) this.pointerStatus.textContent = 'Pointer outside board';
    });

    this.viewport.addEventListener('wheel', (event) => {
      if (!this.image) return;
      event.preventDefault();
      const bounds = this.viewport.getBoundingClientRect();
      const mouseX = event.clientX - bounds.left;
      const mouseY = event.clientY - bounds.top;
      const factor = Math.exp(-event.deltaY * 0.0015);
      const nextZoom = Math.min(Math.max(this.zoom * factor, 0.05), 16);
      this.panX = mouseX - (mouseX - this.panX) * (nextZoom / this.zoom);
      this.panY = mouseY - (mouseY - this.panY) * (nextZoom / this.zoom);
      this.zoom = nextZoom;
      this.fitted = false;
      this.applyTransform();
    }, { passive: false });

    this.viewport.addEventListener('dblclick', () => this.fit());
    $('fit-map').addEventListener('click', () => this.fit());
  }

  updateFromState(state) {
    const render = state.render;
    if (render.image && render.image !== this.image) {
      this.image = render.image;
      this.response = render.lastGoodResponse;
      this.spec = render.lastGoodSpec;
      this.appliedOverlays = new Set(render.lastGoodOptions.overlays);
      this.mapCanvas.width = this.image.naturalWidth;
      this.mapCanvas.height = this.image.naturalHeight;
      this.mapContext.imageSmoothingEnabled = false;
      this.mapContext.clearRect(0, 0, this.mapCanvas.width, this.mapCanvas.height);
      this.mapContext.drawImage(this.image, 0, 0);
      this.mapCanvas.style.display = 'block';
      this.emptyState.hidden = true;
      $('fit-map').disabled = false;

      if (state.document.loadRevision !== this.lastLoadRevision) {
        this.lastLoadRevision = state.document.loadRevision;
        this.fit();
      } else {
        this.applyTransform();
      }
    } else if (this.image) {
      this.drawOverlay();
    }
  }

  resize() {
    const width = this.viewport.clientWidth;
    const height = this.viewport.clientHeight;
    const ratio = window.devicePixelRatio || 1;
    this.overlayCanvas.width = Math.max(1, Math.round(width * ratio));
    this.overlayCanvas.height = Math.max(1, Math.round(height * ratio));
    this.overlayCanvas.style.width = `${width}px`;
    this.overlayCanvas.style.height = `${height}px`;
    this.overlayContext.setTransform(ratio, 0, 0, ratio, 0, 0);
    if (this.fitted && this.image) this.fit();
    else this.drawOverlay();
  }

  fit() {
    if (!this.image) return;
    const padding = 22;
    const availableWidth = Math.max(1, this.viewport.clientWidth - padding * 2);
    const availableHeight = Math.max(1, this.viewport.clientHeight - padding * 2);
    this.zoom = Math.min(
      availableWidth / this.image.naturalWidth,
      availableHeight / this.image.naturalHeight,
    );
    this.panX = (this.viewport.clientWidth - this.image.naturalWidth * this.zoom) / 2;
    this.panY = (this.viewport.clientHeight - this.image.naturalHeight * this.zoom) / 2;
    this.fitted = true;
    this.applyTransform();
  }

  applyTransform() {
    this.mapCanvas.style.transform = `translate(${this.panX}px, ${this.panY}px) scale(${this.zoom})`;
    this.zoomStatus.textContent = `Zoom ${Math.round(this.zoom * 100)}% of rendered image`;
    this.drawOverlay();
  }

  specToScreen(x, y) {
    const scale = this.response.renderScale;
    return {
      x: this.panX + x * scale * this.zoom,
      y: this.panY + y * scale * this.zoom,
    };
  }

  screenToSpec(clientX, clientY, requireInside = true) {
    if (!this.response || !this.image) return null;
    const bounds = this.viewport.getBoundingClientRect();
    const imageX = (clientX - bounds.left - this.panX) / this.zoom;
    const imageY = (clientY - bounds.top - this.panY) / this.zoom;
    if (requireInside && (imageX < 0 || imageY < 0
        || imageX >= this.image.naturalWidth || imageY >= this.image.naturalHeight)) return null;
    return {
      x: imageX / this.response.renderScale,
      y: imageY / this.response.renderScale,
    };
  }

  setEditingController(controller) {
    this.editingController = controller;
    this.drawOverlay();
  }

  updatePointerStatus(event) {
    if (!this.response || !this.spec) {
      this.pointerStatus.textContent = 'Pointer outside board';
      return;
    }
    const bounds = this.viewport.getBoundingClientRect();
    const imageX = (event.clientX - bounds.left - this.panX) / this.zoom;
    const imageY = (event.clientY - bounds.top - this.panY) / this.zoom;
    const specX = Math.max(0, Math.min(this.spec.width - 1, Math.round(imageX / this.response.renderScale)));
    const specY = Math.max(0, Math.min(this.spec.height - 1, Math.round(imageY / this.response.renderScale)));
    const inside = imageX >= 0 && imageY >= 0
      && imageX < this.image.naturalWidth && imageY < this.image.naturalHeight;
    if (!inside) {
      this.pointerStatus.textContent = 'Pointer outside board';
      return;
    }

    const seed = this.response.derived && this.response.derived.seedRegion;
    const outsideSeed = seed && !(
      specX >= seed.x && specX < seed.x + seed.w
      && specY >= seed.y && specY < seed.y + seed.h
    );
    const suffix = outsideSeed ? ' · outside conventional seed guide' : '';
    this.pointerStatus.textContent = `x ${formatInteger(specX)} px · y ${formatInteger(specY)} px${suffix}`;
  }

  drawOverlay() {
    const context = this.overlayContext;
    const width = this.viewport.clientWidth;
    const height = this.viewport.clientHeight;
    context.clearRect(0, 0, width, height);
    this.labelBounds = [];
    if (!this.response || !this.spec || !this.image) return;

    context.save();
    context.beginPath();
    context.rect(
      this.panX,
      this.panY,
      this.image.naturalWidth * this.zoom,
      this.image.naturalHeight * this.zoom,
    );
    context.clip();

    if (this.appliedOverlays.has('seedRegion')) this.drawSeedRegion(context);
    this.drawCaptureZones(context);
    this.drawAnchors(context);
    if (this.appliedOverlays.has('pickups')) this.drawPickups(context);
    if (this.appliedOverlays.has('spin')) this.drawSpinningDiamonds(context);
    this.drawTrenches(context);
    this.drawDiagnosticHighlight(context);
    if (this.editingController) this.editingController.drawOverlay(context);
    context.restore();
    if (this.diagnosticTarget?.offMap) this.drawOffMapDiagnostic(context);
  }

  setDiagnosticTarget(target) {
    this.diagnosticTarget = target || null;
    this.drawOverlay();
  }

  focusDiagnostic(target) {
    if (!target || !this.response || !this.image) return;
    const padding = target.kind === 'sightline' ? 28 : 90;
    const pointX = target.offMap
      ? Math.max(0, Math.min(this.spec.width - 1, target.x)) : target.x;
    const pointY = target.offMap
      ? Math.max(0, Math.min(this.spec.height - 1, target.y)) : target.y;
    const x0 = target.kind === 'sightline' ? target.xLo : pointX - padding;
    const x1 = target.kind === 'sightline' ? target.xHi : pointX + padding;
    const y0 = target.kind === 'sightline' ? target.rows[0] - padding : pointY - padding;
    const y1 = target.kind === 'sightline' ? target.rows.at(-1) + padding : pointY + padding;
    const scale = this.response.renderScale;
    const imageWidth = Math.max(1, (x1 - x0) * scale);
    const imageHeight = Math.max(1, (y1 - y0) * scale);
    const availableWidth = Math.max(1, this.viewport.clientWidth - 72);
    const availableHeight = Math.max(1, this.viewport.clientHeight - 72);
    this.zoom = Math.min(16, Math.max(0.05, Math.min(
      availableWidth / imageWidth,
      availableHeight / imageHeight,
    )));
    const centerX = ((x0 + x1) / 2) * scale;
    const centerY = ((y0 + y1) / 2) * scale;
    this.panX = this.viewport.clientWidth / 2 - centerX * this.zoom;
    this.panY = this.viewport.clientHeight / 2 - centerY * this.zoom;
    this.fitted = false;
    this.applyTransform();
  }

  drawDiagnosticHighlight(context) {
    const target = this.diagnosticTarget;
    if (!target || target.offMap) return;
    context.save();
    context.strokeStyle = '#a33b32';
    context.fillStyle = 'rgba(163, 59, 50, 0.1)';
    context.lineWidth = 2.5;
    if (target.kind === 'sightline') {
      for (const row of target.rows) {
        const start = this.specToScreen(target.xLo, row);
        const end = this.specToScreen(target.xHi, row);
        context.beginPath();
        context.moveTo(start.x, start.y);
        context.lineTo(end.x, end.y);
        context.stroke();
      }
      const labelPoint = this.specToScreen(target.xLo, target.rows[0]);
      this.drawLabel(context, labelPoint.x, labelPoint.y, target.label, '#762b25', {
        background: 'rgba(243, 237, 226, 0.94)',
      });
    } else {
      const point = this.specToScreen(target.x, target.y);
      context.beginPath();
      context.arc(point.x, point.y, 13, 0, Math.PI * 2);
      context.fill();
      context.stroke();
      this.drawCrosshair(context, point.x, point.y, '#a33b32', 7);
      this.drawLabel(context, point.x, point.y, target.label, '#762b25', {
        background: 'rgba(243, 237, 226, 0.94)',
      });
    }
    context.restore();
  }

  drawOffMapDiagnostic(context) {
    const target = this.diagnosticTarget;
    const x = Math.max(0, Math.min(this.spec.width - 1, target.x));
    const y = Math.max(0, Math.min(this.spec.height - 1, target.y));
    const point = this.specToScreen(x, y);
    const dx = target.x - x;
    const dy = target.y - y;
    const length = Math.max(1, Math.hypot(dx, dy));
    const ux = dx / length;
    const uy = dy / length;
    const endX = point.x + ux * 18;
    const endY = point.y + uy * 18;
    context.save();
    context.strokeStyle = '#a33b32';
    context.lineWidth = 2;
    context.beginPath();
    context.moveTo(point.x, point.y);
    context.lineTo(endX, endY);
    context.moveTo(endX, endY);
    context.lineTo(endX - ux * 6 - uy * 4, endY - uy * 6 + ux * 4);
    context.moveTo(endX, endY);
    context.lineTo(endX - ux * 6 + uy * 4, endY - uy * 6 - ux * 4);
    context.stroke();
    context.font = '600 10px ui-monospace, SFMono-Regular, Menlo, monospace';
    context.fillStyle = '#762b25';
    context.fillText(`${target.label} · off map`, endX + 7, endY - 7);
    context.restore();
  }

  drawSeedRegion(context) {
    const seed = this.response.derived && this.response.derived.seedRegion;
    if (!seed) return;

    const mapX = this.panX;
    const mapY = this.panY;
    const mapWidth = this.image.naturalWidth * this.zoom;
    const mapHeight = this.image.naturalHeight * this.zoom;
    const start = this.specToScreen(seed.x, seed.y);
    const end = this.specToScreen(seed.x + seed.w, seed.y + seed.h);

    context.save();
    context.beginPath();
    context.rect(mapX, mapY, mapWidth, mapHeight);
    context.rect(start.x, start.y, end.x - start.x, end.y - start.y);
    context.fillStyle = 'rgba(36, 28, 22, 0.16)';
    context.fill('evenodd');
    context.setLineDash([6, 4]);
    context.lineWidth = 1.5;
    context.strokeStyle = '#b9782d';
    context.strokeRect(start.x, start.y, end.x - start.x, end.y - start.y);
    context.restore();

    this.drawLabel(context, start.x + 8, start.y + 8, 'CONVENTIONAL SEED REGION', '#6b471c', {
      background: 'rgba(243, 237, 226, 0.92)',
      force: true,
    });
  }

  drawCaptureZones(context) {
    const zones = this.response.derived && this.response.derived.captureZones;
    if (!Array.isArray(zones)) return;

    for (const zone of zones) {
      const color = TEAM_COLORS[zone.team] || '#74675a';
      context.save();
      context.strokeStyle = color;
      context.fillStyle = `${color}1f`;
      context.lineWidth = 1.5;
      context.setLineDash([5, 4]);
      context.beginPath();

      if (zone.disc) {
        const center = this.specToScreen(zone.anchorX, zone.anchorY);
        const radius = zone.radius * this.response.renderScale * this.zoom;
        context.arc(center.x, center.y, radius, 0, Math.PI * 2);
      } else if (zone.diag) {
        const corner = this.specToScreen(zone.cornerX, zone.cornerY);
        const xDirection = zone.cornerX <= this.spec.width / 2 ? 1 : -1;
        const yDirection = zone.cornerY <= this.spec.height / 2 ? 1 : -1;
        const xEdge = this.specToScreen(zone.cornerX + xDirection * zone.diagLimit, zone.cornerY);
        const yEdge = this.specToScreen(zone.cornerX, zone.cornerY + yDirection * zone.diagLimit);
        context.moveTo(corner.x, corner.y);
        context.lineTo(xEdge.x, xEdge.y);
        context.lineTo(yEdge.x, yEdge.y);
        context.closePath();
      } else {
        const start = this.specToScreen(zone.xLo, zone.yLo);
        const end = this.specToScreen(zone.xHi + 1, zone.yHi + 1);
        context.rect(start.x, start.y, end.x - start.x, end.y - start.y);
      }
      context.fill();
      context.stroke();
      context.restore();

      const teamAnchor = (this.response.derived.anchors || [])
        .find((anchor) => anchor.team === zone.team);
      const labelX = teamAnchor ? teamAnchor.x : (zone.xLo + zone.xHi) / 2;
      const labelY = teamAnchor ? teamAnchor.y : (zone.yLo + zone.yHi) / 2;
      const labelPoint = this.specToScreen(labelX, labelY);
      this.drawLabel(context, labelPoint.x, labelPoint.y + 13, `${zone.team} capture zone`, color);
    }
  }

  drawAnchors(context) {
    const anchors = this.response.derived && this.response.derived.anchors;
    if (!Array.isArray(anchors)) return;
    for (const anchor of anchors) {
      const point = this.specToScreen(anchor.x, anchor.y);
      const color = TEAM_COLORS[anchor.team] || '#74675a';
      this.drawCrosshair(context, point.x, point.y, color, 5);
      this.drawLabel(context, point.x, point.y, `${anchor.team} pedestal`, color);
    }
  }

  drawPickups(context) {
    const pickups = this.response.derived && this.response.derived.pickups;
    if (!pickups) return;
    const labels = {
      grenade: 'grenade',
      shield: 'shield',
      plasmaArc: 'spray can',
      medKitActive: 'active med kit',
      medKitCandidate: 'med-kit candidate',
    };
    // One label per family, bare markers for the rest. A standard board repeats
    // each family two to four times, so labelling every instance buries the
    // terrain the labels exist to annotate. "Nominal" is stated once in the
    // overlay panel rather than on a dozen markers, and every exact coordinate
    // stays in the marker list below the board.
    for (const [family, points] of Object.entries(pickups)) {
      if (!Array.isArray(points)) continue;
      let labelled = false;
      for (const pointValue of points) {
        if (!Array.isArray(pointValue) || pointValue.length < 2) continue;
        const point = this.specToScreen(pointValue[0], pointValue[1]);
        const color = MARKER_COLORS[family] || '#74675a';
        this.drawMarker(context, point.x, point.y, color, family === 'medKitCandidate');
        if (!labelled) {
          this.drawLabel(
            context, point.x, point.y,
            labels[family] || humanizeToken(family), color
          );
          labelled = true;
        }
      }
    }
  }

  drawSpinningDiamonds(context) {
    const diamonds = this.response.derived && this.response.derived.spinningDiamonds;
    if (!Array.isArray(diamonds)) return;
    // One label for the set, markers for the rest — the same rule drawPickups
    // follows. A small board can put a dozen diamonds in the centre spin band,
    // and labelling each one buries the terrain the marks exist to annotate.
    // Every radius is listed in the marker table below the board.
    const color = MARKER_COLORS.spinningDiamond;
    let labelled = false;
    for (const diamond of diamonds) {
      const point = this.specToScreen(diamond.cx, diamond.cy);
      context.save();
      context.strokeStyle = color;
      context.lineWidth = 1.5;
      context.strokeRect(point.x - 4, point.y - 4, 8, 8);
      context.restore();
      if (!labelled) {
        const suffix = diamonds.length > 1 ? ` ×${diamonds.length}` : '';
        this.drawLabel(
          context, point.x, point.y,
          `spinning diamond · r ${diamond.r} px${suffix}`, color
        );
        labelled = true;
      }
    }
  }

  drawTrenches(context) {
    if (!Array.isArray(this.spec.trenches)) return;
    for (const trench of this.spec.trenches) {
      if (!Array.isArray(trench) || trench.length < 4) continue;
      const [x, y, width, height] = trench;
      const start = this.specToScreen(x, y);
      const end = this.specToScreen(x + width, y + height);
      context.save();
      context.strokeStyle = MARKER_COLORS.trench;
      context.setLineDash([3, 3]);
      context.lineWidth = 1;
      context.strokeRect(start.x, start.y, end.x - start.x, end.y - start.y);
      context.restore();
    }
  }

  drawCrosshair(context, x, y, color, radius) {
    context.save();
    context.strokeStyle = color;
    context.lineWidth = 2;
    context.beginPath();
    context.arc(x, y, radius, 0, Math.PI * 2);
    context.moveTo(x - radius - 3, y);
    context.lineTo(x + radius + 3, y);
    context.moveTo(x, y - radius - 3);
    context.lineTo(x, y + radius + 3);
    context.stroke();
    context.restore();
  }

  drawMarker(context, x, y, color, hollow = false) {
    context.save();
    context.beginPath();
    context.arc(x, y, 4, 0, Math.PI * 2);
    context.fillStyle = hollow ? '#f3ede2' : color;
    context.fill();
    context.strokeStyle = color;
    context.lineWidth = 1.5;
    context.stroke();
    context.restore();
  }

  drawLabel(context, x, y, text, color, options = {}) {
    context.save();
    context.font = '600 10px ui-monospace, SFMono-Regular, Menlo, monospace';
    const paddingX = 4;
    const labelHeight = 17;
    const labelWidth = context.measureText(text).width + paddingX * 2;
    const offsets = options.force
      ? [[0, 0]]
      : [[8, -21], [8, 7], [-labelWidth - 8, -21], [-labelWidth - 8, 7]];
    let chosen = null;
    for (const [offsetX, offsetY] of offsets) {
      const bounds = { x: x + offsetX, y: y + offsetY, w: labelWidth, h: labelHeight };
      const mapLeft = Math.max(0, this.panX);
      const mapTop = Math.max(0, this.panY);
      const mapRight = Math.min(
        this.viewport.clientWidth,
        this.panX + this.image.naturalWidth * this.zoom,
      );
      const mapBottom = Math.min(
        this.viewport.clientHeight,
        this.panY + this.image.naturalHeight * this.zoom,
      );
      const outsideVisibleMap = bounds.x < mapLeft || bounds.y < mapTop
        || bounds.x + bounds.w > mapRight || bounds.y + bounds.h > mapBottom;
      const overlaps = this.labelBounds.some((other) => !(
        bounds.x + bounds.w < other.x || other.x + other.w < bounds.x
        || bounds.y + bounds.h < other.y || other.y + other.h < bounds.y
      ));
      if ((!outsideVisibleMap && !overlaps) || options.force) {
        chosen = bounds;
        break;
      }
    }
    if (!chosen) {
      context.restore();
      return;
    }

    this.labelBounds.push(chosen);
    context.fillStyle = options.background || 'rgba(243, 237, 226, 0.88)';
    context.fillRect(chosen.x, chosen.y, chosen.w, chosen.h);
    context.fillStyle = color;
    context.textBaseline = 'middle';
    context.fillText(text, chosen.x + paddingX, chosen.y + labelHeight / 2 + 0.5);
    context.restore();
  }
}

function obstacleFields(shape) {
  switch (shape.kind) {
    case 'rect': return ['x', 'y', 'w', 'h'];
    case 'disc':
    case 'diamond': return ['cx', 'cy', 'r'];
    case 'diagonal': return ['x0', 'y0', 'x1', 'y1', 't'];
    default: return [];
  }
}

function obstacleSummary(shape) {
  if (shape.kind === 'rect') return `x ${shape.x}, y ${shape.y} · ${shape.w}×${shape.h}`;
  if (shape.kind === 'disc' || shape.kind === 'diamond') {
    return `(${shape.cx}, ${shape.cy}) · r ${shape.r}`;
  }
  if (shape.kind === 'diagonal') {
    return `(${shape.x0}, ${shape.y0})→(${shape.x1}, ${shape.y1}) · t ${shape.t}`;
  }
  return 'Unknown obstacle';
}

function pointSegmentDistance(px, py, x0, y0, x1, y1) {
  const vx = x1 - x0;
  const vy = y1 - y0;
  const lengthSquared = vx * vx + vy * vy;
  if (lengthSquared === 0) return Math.hypot(px - x0, py - y0);
  const projection = Math.max(0, Math.min(1, ((px - x0) * vx + (py - y0) * vy) / lengthSquared));
  return Math.hypot(px - (x0 + projection * vx), py - (y0 + projection * vy));
}

class EditingController {
  constructor(store, coordinator, viewport) {
    this.store = store;
    this.coordinator = coordinator;
    this.viewport = viewport;
    this.drag = null;
    this.lastListKey = '';
    this.lastEditorKey = '';
    this.nudge = null;
    this.heldNudgeKeys = new Set();
    this.bindControls();
    this.store.subscribe((state) => this.render(state));
  }

  bindControls() {
    for (const button of document.querySelectorAll('[data-create-obstacle]')) {
      button.addEventListener('click', () => this.createObstacle(button.dataset.createObstacle));
    }
    $('undo-edit').addEventListener('click', () => this.undo());
    $('redo-edit').addEventListener('click', () => this.redo());
    $('snap-to-grid').addEventListener('change', (event) => {
      this.store.change((state) => {
        state.controls.snapToGrid = event.target.checked;
      });
      $('grid-size').disabled = !event.target.checked;
    });
    $('grid-size').addEventListener('change', (event) => {
      const value = Number(event.target.value);
      if (!Number.isInteger(value) || value < 1) {
        event.target.setCustomValidity('Grid size must be a positive integer.');
        event.target.reportValidity();
        event.target.value = String(this.store.state.controls.gridSize);
        return;
      }
      event.target.setCustomValidity('');
      this.store.change((state) => { state.controls.gridSize = value; });
    });

    $('obstacle-list').addEventListener('click', (event) => {
      const button = event.target.closest('[data-obstacle-index]');
      if (!button) return;
      this.store.setSelection({ type: 'obstacle', index: Number(button.dataset.obstacleIndex) });
      this.viewport.drawOverlay();
    });

    $('obstacle-editor').addEventListener('change', (event) => {
      const field = event.target.closest('[data-obstacle-field]');
      if (field) this.commitNumericField(field);
    });
    $('obstacle-editor').addEventListener('keydown', (event) => {
      if (event.key === 'Enter' && event.target.matches('[data-obstacle-field]')) {
        event.preventDefault();
        event.target.blur();
      } else if (event.key === 'Escape' && event.target.matches('[data-obstacle-field]')) {
        event.preventDefault();
        this.render(this.store.state, true);
        event.target.blur();
      }
    });
    $('obstacle-editor').addEventListener('click', (event) => {
      const action = event.target.closest('[data-obstacle-action]');
      if (!action) return;
      if (action.dataset.obstacleAction === 'delete') this.deleteSelection();
      if (action.dataset.obstacleAction === 'window') this.toggleWindow();
    });

    window.addEventListener('keydown', (event) => {
      const modifier = event.metaKey || event.ctrlKey;
      if (event.defaultPrevented || isInteractiveTarget(event.target)) return;
      if (modifier && event.key.toLowerCase() === 'z') {
        event.preventDefault();
        if (event.shiftKey) this.redo();
        else this.undo();
        return;
      }
      if (event.ctrlKey && event.key.toLowerCase() === 'y') {
        event.preventDefault();
        this.redo();
        return;
      }
      if ((event.key === 'Delete' || event.key === 'Backspace')
          && !isInteractiveTarget(event.target)) {
        event.preventDefault();
        this.deleteSelection();
      }
      if (event.key === 'Escape' && (this.drag || this.nudge)) this.cancelTransientEdit();
      if (['ArrowLeft', 'ArrowRight', 'ArrowUp', 'ArrowDown'].includes(event.key)) {
        this.nudgeSelection(event);
      }
    });
    window.addEventListener('keyup', (event) => {
      if (!this.nudge || !this.heldNudgeKeys.has(event.key)) return;
      this.heldNudgeKeys.delete(event.key);
      if (!this.heldNudgeKeys.size) this.finishNudge();
    });
    window.addEventListener('blur', () => {
      if (this.nudge) this.finishNudge();
    });
  }

  currentSpec() {
    return this.store.state.editing.previewSpec || this.store.state.document.spec;
  }

  setPlacementController(controller) {
    this.placementController = controller;
  }

  selectedObstacle(spec = this.currentSpec()) {
    const selection = this.store.state.editing.selection;
    if (!spec || !selection || selection.type !== 'obstacle') return null;
    return (spec.leftObstacles || [])[selection.index] || null;
  }

  render(state, force = false) {
    const spec = state.editing.previewSpec || state.document.spec;
    const selection = state.editing.selection;
    const selectedIndex = selection && selection.type === 'obstacle' ? selection.index : -1;
    const listKey = `${state.document.revision}:${selectedIndex}`;
    if (force || listKey !== this.lastListKey) {
      this.lastListKey = listKey;
      this.renderObstacleList(spec, selectedIndex);
    }

    const selected = spec && selectedIndex >= 0 ? (spec.leftObstacles || [])[selectedIndex] : null;
    const editorKey = selected ? `${selectedIndex}:${selected.kind}` : 'none';
    if (force || editorKey !== this.lastEditorKey) {
      this.lastEditorKey = editorKey;
      this.renderNumericEditor(selected, selectedIndex);
    }
    if (selected) this.updateNumericValues(selected);

    const hasSpec = Boolean(state.document.spec);
    const placementGroup = selection && selection.type !== 'obstacle'
      ? this.placementController?.selectedGroup() : null;
    $('precision-controls').hidden = !selection
      || (selection.type !== 'obstacle' && (!placementGroup || placementGroup.readOnly));
    for (const button of document.querySelectorAll('[data-create-obstacle]')) button.disabled = !hasSpec;
    $('undo-edit').disabled = !state.editing.undoStack.length;
    $('redo-edit').disabled = !state.editing.redoStack.length;
    $('undo-edit').title = state.editing.undoStack.length
      ? `Undo ${state.editing.undoStack.at(-1).label} (Ctrl/Cmd-Z)` : 'Nothing to undo';
    $('redo-edit').title = state.editing.redoStack.length
      ? `Redo ${state.editing.redoStack.at(-1).label}` : 'Nothing to redo';
    this.renderWarning(spec, selected);
    this.viewport.drawOverlay();
  }

  renderObstacleList(spec, selectedIndex) {
    const root = $('obstacle-list');
    root.replaceChildren();
    const obstacles = spec && Array.isArray(spec.leftObstacles) ? spec.leftObstacles : [];
    if (!spec || !obstacles.length) {
      const empty = document.createElement('p');
      empty.className = 'empty-detail';
      empty.textContent = spec ? 'No authored obstacles. Create one above.' : 'Load a map to edit obstacles.';
      root.append(empty);
      return;
    }
    obstacles.forEach((shape, index) => {
      const button = document.createElement('button');
      button.type = 'button';
      button.className = 'authored-item';
      button.dataset.obstacleIndex = String(index);
      button.setAttribute('aria-pressed', String(index === selectedIndex));
      const number = document.createElement('span');
      number.className = 'authored-index';
      number.textContent = `#${index + 1}`;
      const kind = document.createElement('span');
      kind.className = 'authored-kind';
      kind.textContent = `${humanizeToken(shape.kind)}${shape.window ? ' · glass' : ''}`;
      const detail = document.createElement('span');
      detail.className = 'authored-detail';
      detail.textContent = obstacleSummary(shape);
      button.append(number, kind, detail);
      root.append(button);
    });
  }

  renderNumericEditor(shape, index) {
    const root = $('obstacle-editor');
    root.replaceChildren();
    root.hidden = !shape;
    if (!shape) return;

    const heading = document.createElement('div');
    heading.className = 'numeric-editor-heading';
    const title = document.createElement('strong');
    title.textContent = `Obstacle ${index + 1} · ${humanizeToken(shape.kind)}`;
    const glass = document.createElement('span');
    glass.className = 'quiet-label';
    glass.textContent = shape.window ? 'Glass window' : 'Stone';
    heading.append(title, glass);

    const grid = document.createElement('div');
    grid.className = 'numeric-grid';
    for (const name of obstacleFields(shape)) {
      const label = document.createElement('label');
      label.textContent = `${name} · px`;
      const input = document.createElement('input');
      input.type = 'number';
      input.step = '1';
      input.required = true;
      input.dataset.obstacleField = name;
      input.setAttribute('aria-label', `${humanizeToken(name)} in map pixels`);
      label.append(input);
      grid.append(label);
    }

    const hint = document.createElement('p');
    hint.className = 'section-intro';
    hint.textContent = shape.kind === 'diagonal'
      ? 'Any angle is valid. Hold Shift while dragging an endpoint to snap to 45° increments.'
      : 'Fields are integer map pixels and commit on Enter or when focus leaves the field.';

    const actions = document.createElement('div');
    actions.className = 'selection-actions';
    const windowButton = document.createElement('button');
    windowButton.type = 'button';
    windowButton.dataset.obstacleAction = 'window';
    windowButton.textContent = shape.window ? 'Make stone' : 'Make glass window';
    const deleteButton = document.createElement('button');
    deleteButton.type = 'button';
    deleteButton.className = 'danger-action';
    deleteButton.dataset.obstacleAction = 'delete';
    deleteButton.textContent = 'Delete obstacle';
    actions.append(windowButton, deleteButton);
    root.append(heading, grid, hint, actions);
  }

  updateNumericValues(shape) {
    for (const input of $('obstacle-editor').querySelectorAll('[data-obstacle-field]')) {
      if (document.activeElement !== input) input.value = String(shape[input.dataset.obstacleField]);
    }
  }

  renderWarning(spec, shape) {
    const warning = $('editing-warning');
    if (!spec || !shape) {
      warning.hidden = true;
      return;
    }
    const messages = [
      'The dashed envelope is authoring chrome, not terrain. Nim carves protected floor from it; the server PNG is the playable result.',
    ];
    if (this.shapeOutsideBoard(shape, spec)) {
      messages.push('Part of this authored envelope lies outside the current board.');
    }
    const seed = this.store.state.render.lastGoodResponse?.derived?.seedRegion;
    if (seed && !this.shapeCenterInside(shape, seed)) {
      messages.push('Its authoring center is outside the conventional seed guide; this is allowed.');
    }
    warning.textContent = messages.join(' ');
    warning.hidden = false;
  }

  shapeCenterInside(shape, rect) {
    let x;
    let y;
    if (shape.kind === 'rect') {
      x = shape.x + shape.w / 2;
      y = shape.y + shape.h / 2;
    } else if (shape.kind === 'diagonal') {
      x = (shape.x0 + shape.x1) / 2;
      y = (shape.y0 + shape.y1) / 2;
    } else {
      x = shape.cx;
      y = shape.cy;
    }
    return x >= rect.x && x < rect.x + rect.w && y >= rect.y && y < rect.y + rect.h;
  }

  shapeOutsideBoard(shape, spec) {
    if (shape.kind === 'rect') {
      return shape.x < 0 || shape.y < 0 || shape.x + shape.w > spec.width || shape.y + shape.h > spec.height;
    }
    if (shape.kind === 'disc' || shape.kind === 'diamond') {
      return shape.cx - shape.r < 0 || shape.cy - shape.r < 0
        || shape.cx + shape.r >= spec.width || shape.cy + shape.r >= spec.height;
    }
    const half = shape.t / 2;
    return Math.min(shape.x0, shape.x1) - half < 0 || Math.min(shape.y0, shape.y1) - half < 0
      || Math.max(shape.x0, shape.x1) + half >= spec.width
      || Math.max(shape.y0, shape.y1) + half >= spec.height;
  }

  createObstacle(kind) {
    const spec = this.store.state.document.spec;
    if (!spec) return;
    const next = cloneJson(spec);
    if (!Array.isArray(next.leftObstacles)) next.leftObstacles = [];
    const seed = this.store.state.render.lastGoodResponse?.derived?.seedRegion
      || { x: 0, y: 0, w: spec.width, h: spec.height };
    const cx = this.snapCoordinate(seed.x + seed.w / 2);
    const cy = this.snapCoordinate(seed.y + seed.h / 2);
    const shapes = {
      rect: { kind: 'rect', x: cx - 24, y: cy - 24, w: 48, h: 48 },
      disc: { kind: 'disc', cx, cy, r: 24 },
      diamond: { kind: 'diamond', cx, cy, r: 28 },
      diagonal: { kind: 'diagonal', x0: cx - 24, y0: cy - 24, x1: cx + 24, y1: cy + 24, t: 12 },
    };
    next.leftObstacles.push(shapes[kind]);
    const selection = { type: 'obstacle', index: next.leftObstacles.length - 1 };
    if (this.store.commitSpec(next, `create ${kind}`, selection)) this.coordinator.schedule({ immediate: true });
  }

  deleteSelection() {
    if (this.drag || this.nudge) this.cancelTransientEdit();
    const spec = this.store.state.document.spec;
    const selection = this.store.state.editing.selection;
    if (!spec || !selection || selection.type !== 'obstacle') return;
    const obstacles = spec.leftObstacles || [];
    if (!obstacles[selection.index]) return;
    const next = cloneJson(spec);
    const [removed] = next.leftObstacles.splice(selection.index, 1);
    if (this.store.commitSpec(next, `delete ${removed.kind}`, null)) this.coordinator.schedule({ immediate: true });
  }

  toggleWindow() {
    const spec = this.store.state.document.spec;
    const selection = this.store.state.editing.selection;
    if (!spec || !selection || selection.type !== 'obstacle') return;
    const next = cloneJson(spec);
    const shape = next.leftObstacles[selection.index];
    if (!shape) return;
    if (shape.window) delete shape.window;
    else shape.window = true;
    if (this.store.commitSpec(next, 'toggle glass window')) this.coordinator.schedule({ immediate: true });
  }

  commitNumericField(input) {
    const selection = this.store.state.editing.selection;
    const spec = this.store.state.document.spec;
    if (!spec || !selection || selection.type !== 'obstacle') return;
    const value = input.value === '' ? Number.NaN : Number(input.value);
    if (!Number.isInteger(value)) {
      input.setCustomValidity('Enter an integer number of map pixels.');
      input.reportValidity();
      return;
    }
    const next = cloneJson(spec);
    const shape = next.leftObstacles[selection.index];
    if (!shape) return;
    const field = input.dataset.obstacleField;
    if (['w', 'h', 'r', 't'].includes(field) && value < 1) {
      input.setCustomValidity(`${field} must be at least 1 px.`);
      input.reportValidity();
      return;
    }
    input.setCustomValidity('');
    shape[field] = value;
    if (this.store.commitSpec(next, `edit ${shape.kind} ${field}`)) this.coordinator.schedule({ immediate: true });
  }

  undo() {
    if (this.drag || this.nudge) this.cancelTransientEdit();
    if (this.store.undo()) this.coordinator.schedule({ immediate: true });
  }

  redo() {
    if (this.drag || this.nudge) this.cancelTransientEdit();
    if (this.store.redo()) this.coordinator.schedule({ immediate: true });
  }

  pointerDown(event, point) {
    const spec = this.store.state.document.spec;
    if (!spec) return false;
    const selection = this.store.state.editing.selection;
    if (selection && ['trench', 'medKit'].includes(selection.type) && this.placementController) {
      const group = this.placementController.selectedGroup();
      if (group && !group.readOnly) {
        const seed = group.orbit[0];
        let handle = null;
        if (selection.type === 'trench') {
          const shape = { kind: 'rect', x: seed[0], y: seed[1], w: seed[2], h: seed[3] };
          handle = this.hitHandle(shape, event.clientX, event.clientY);
          if (!handle && this.hitAuthoringProxy(shape, point)) handle = 'move';
        } else {
          const screen = this.viewport.specToScreen(seed[0], seed[1]);
          const bounds = this.viewport.viewport.getBoundingClientRect();
          if (Math.hypot(event.clientX - bounds.left - screen.x, event.clientY - bounds.top - screen.y) <= 10) {
            handle = 'move';
          }
        }
        if (handle) {
          this.drag = {
            pointerId: event.pointerId,
            placement: true,
            type: selection.type,
            index: selection.index,
            handle,
            start: point,
            baseSeed: cloneJson(seed),
            group,
          };
          this.viewport.viewport.classList.add('editing');
          return true;
        }
      }
    }
    if (selection && selection.type === 'obstacle') {
      const shape = (spec.leftObstacles || [])[selection.index];
      if (shape) {
        const handle = this.hitHandle(shape, event.clientX, event.clientY);
        if (handle || this.hitAuthoringProxy(shape, point)) {
          this.drag = {
            pointerId: event.pointerId,
            index: selection.index,
            handle: handle || 'move',
            start: point,
            baseSpec: cloneJson(spec),
            moved: false,
            thicknessHandleOffset: handle === 'thickness' ? this.diagonalHandleOffset() : 0,
          };
          this.viewport.viewport.classList.add('editing');
          return true;
        }
      }
    }
    const hit = this.pickObstacle(spec, point);
    if (hit >= 0) {
      this.store.setSelection({ type: 'obstacle', index: hit });
      return true;
    }
    return false;
  }

  pointerMove(event) {
    if (!this.drag || this.drag.pointerId !== event.pointerId) return false;
    const point = this.viewport.screenToSpec(event.clientX, event.clientY, false);
    if (!point) return true;
    if (this.drag.placement) {
      const seed = this.draggedPlacement(point);
      this.store.setPlacementPreview({
        type: this.drag.type,
        index: this.drag.index,
        seed,
      });
      return true;
    }
    const next = this.draggedSpec(point, event.shiftKey);
    this.drag.moved = JSON.stringify(next) !== JSON.stringify(this.drag.baseSpec);
    this.store.setPreviewSpec(next);
    return true;
  }

  pointerUp(event) {
    if (!this.drag || this.drag.pointerId !== event.pointerId) return false;
    if (event.type === 'pointercancel') {
      this.cancelDrag();
      return true;
    }
    if (this.drag.placement) {
      const drag = this.drag;
      const preview = this.store.state.editing.placementPreview;
      this.drag = null;
      this.viewport.viewport.classList.remove('editing');
      if (preview) {
        this.placementController.replaceOrbit(
          { type: drag.type, index: drag.index },
          drag.group,
          preview.seed,
          `drag ${drag.type === 'trench' ? 'trench' : 'med-kit orbit'}`,
        );
      }
      return true;
    }
    const next = this.store.state.editing.previewSpec;
    const shape = this.drag.baseSpec.leftObstacles[this.drag.index];
    this.viewport.viewport.classList.remove('editing');
    this.drag = null;
    if (next && this.store.commitSpec(next, `drag ${shape.kind}`)) {
      this.coordinator.schedule({ immediate: true });
    } else {
      this.store.clearPreview();
    }
    return true;
  }

  cancelDrag() {
    this.drag = null;
    this.viewport.viewport.classList.remove('editing');
    this.store.clearPreview();
    this.store.setPlacementPreview(null);
  }

  cancelTransientEdit() {
    this.nudge = null;
    this.heldNudgeKeys.clear();
    this.cancelDrag();
  }

  nudgeSelection(event) {
    if (this.drag || event.metaKey || event.ctrlKey || event.altKey) return;
    const selection = this.store.state.editing.selection;
    const spec = this.store.state.document.spec;
    if (!selection || !spec) return;
    if (selection.type !== 'obstacle') {
      const group = this.placementController?.selectedGroup();
      if (!group || group.readOnly || this.placementController.busy) return;
    }
    event.preventDefault();
    const step = event.shiftKey ? 10 : 1;
    const delta = {
      ArrowLeft: [-step, 0],
      ArrowRight: [step, 0],
      ArrowUp: [0, -step],
      ArrowDown: [0, step],
    }[event.key];
    if (!this.nudge) {
      const group = selection.type === 'obstacle' ? null : this.placementController.selectedGroup();
      this.nudge = {
        selection: cloneJson(selection),
        baseSpec: selection.type === 'obstacle' ? cloneJson(spec) : null,
        group,
        baseSeed: group ? cloneJson(group.orbit[0]) : null,
        dx: 0,
        dy: 0,
      };
    }
    if (this.nudge.selection.type !== selection.type
        || this.nudge.selection.index !== selection.index) return;
    this.heldNudgeKeys.add(event.key);
    this.nudge.dx += delta[0];
    this.nudge.dy += delta[1];
    if (selection.type === 'obstacle') {
      const next = cloneJson(this.nudge.baseSpec);
      const shape = next.leftObstacles[selection.index];
      this.translateObstacle(shape, this.nudge.dx, this.nudge.dy);
      this.store.setPreviewSpec(next);
    } else {
      const seed = cloneJson(this.nudge.baseSeed);
      seed[0] += this.nudge.dx;
      seed[1] += this.nudge.dy;
      this.store.setPlacementPreview({
        type: selection.type,
        index: selection.index,
        seed,
      });
    }
  }

  finishNudge() {
    if (!this.nudge) return;
    const nudge = this.nudge;
    this.nudge = null;
    this.heldNudgeKeys.clear();
    const selection = this.store.state.editing.selection;
    if (!selection || selection.type !== nudge.selection.type
        || selection.index !== nudge.selection.index) {
      this.store.clearPreview();
      this.store.setPlacementPreview(null);
      return;
    }
    const name = nudge.selection.type === 'medKit' ? 'med-kit orbit' : nudge.selection.type;
    if (nudge.selection.type === 'obstacle') {
      const next = this.store.state.editing.previewSpec;
      const shape = nudge.baseSpec.leftObstacles[nudge.selection.index];
      if (next && this.store.commitSpec(next, `nudge ${shape.kind}`)) {
        this.coordinator.schedule({ immediate: true });
      } else {
        this.store.clearPreview();
      }
      return;
    }
    const preview = this.store.state.editing.placementPreview;
    if (!preview) return;
    this.placementController.replaceOrbit(
      nudge.selection,
      nudge.group,
      preview.seed,
      `nudge ${name}`,
    );
  }

  translateObstacle(shape, dx, dy) {
    if (shape.kind === 'rect') {
      shape.x += dx;
      shape.y += dy;
    } else if (shape.kind === 'disc' || shape.kind === 'diamond') {
      shape.cx += dx;
      shape.cy += dy;
    } else {
      shape.x0 += dx;
      shape.y0 += dy;
      shape.x1 += dx;
      shape.y1 += dy;
    }
  }

  snapCoordinate(value) {
    const rounded = Math.round(value);
    const controls = this.store.state.controls;
    if (!controls.snapToGrid) return rounded;
    return Math.round(rounded / controls.gridSize) * controls.gridSize;
  }

  snapSize(value) {
    return Math.max(1, this.snapCoordinate(value));
  }

  draggedPlacement(point) {
    const base = this.drag.baseSeed;
    const dx = Math.round(point.x - this.drag.start.x);
    const dy = Math.round(point.y - this.drag.start.y);
    if (this.drag.type === 'medKit') {
      return [this.snapCoordinate(base[0] + dx), this.snapCoordinate(base[1] + dy)];
    }
    if (this.drag.handle === 'move') {
      return [this.snapCoordinate(base[0] + dx), this.snapCoordinate(base[1] + dy), base[2], base[3]];
    }
    let x0 = base[0];
    let y0 = base[1];
    let x1 = base[0] + base[2];
    let y1 = base[1] + base[3];
    if (this.drag.handle.includes('w')) x0 = this.snapCoordinate(point.x);
    if (this.drag.handle.includes('e')) x1 = this.snapCoordinate(point.x);
    if (this.drag.handle.includes('n')) y0 = this.snapCoordinate(point.y);
    if (this.drag.handle.includes('s')) y1 = this.snapCoordinate(point.y);
    return [Math.min(x0, x1), Math.min(y0, y1), Math.max(1, Math.abs(x1 - x0)), Math.max(1, Math.abs(y1 - y0))];
  }

  draggedSpec(point, snapDiagonal) {
    const next = cloneJson(this.drag.baseSpec);
    const shape = next.leftObstacles[this.drag.index];
    const base = this.drag.baseSpec.leftObstacles[this.drag.index];
    const dx = Math.round(point.x - this.drag.start.x);
    const dy = Math.round(point.y - this.drag.start.y);
    const handle = this.drag.handle;
    if (handle === 'move' || handle === 'midpoint') {
      if (shape.kind === 'rect') {
        shape.x = this.snapCoordinate(base.x + dx);
        shape.y = this.snapCoordinate(base.y + dy);
      } else if (shape.kind === 'disc' || shape.kind === 'diamond') {
        shape.cx = this.snapCoordinate(base.cx + dx);
        shape.cy = this.snapCoordinate(base.cy + dy);
      } else {
        const x0 = this.snapCoordinate(base.x0 + dx);
        const y0 = this.snapCoordinate(base.y0 + dy);
        shape.x0 = x0;
        shape.y0 = y0;
        shape.x1 = base.x1 + (x0 - base.x0);
        shape.y1 = base.y1 + (y0 - base.y0);
      }
      return next;
    }

    if (shape.kind === 'rect') {
      let x0 = base.x;
      let x1 = base.x + base.w;
      let y0 = base.y;
      let y1 = base.y + base.h;
      if (handle.includes('w')) x0 = this.snapCoordinate(point.x);
      if (handle.includes('e')) x1 = this.snapCoordinate(point.x);
      if (handle.includes('n')) y0 = this.snapCoordinate(point.y);
      if (handle.includes('s')) y1 = this.snapCoordinate(point.y);
      shape.x = Math.min(x0, x1);
      shape.y = Math.min(y0, y1);
      shape.w = Math.max(1, Math.abs(x1 - x0));
      shape.h = Math.max(1, Math.abs(y1 - y0));
    } else if (shape.kind === 'disc') {
      shape.r = this.snapSize(Math.hypot(point.x - base.cx, point.y - base.cy));
    } else if (shape.kind === 'diamond') {
      shape.r = this.snapSize(Math.abs(point.x - base.cx) + Math.abs(point.y - base.cy));
    } else if (handle === 'start' || handle === 'end') {
      const fixedX = handle === 'start' ? base.x1 : base.x0;
      const fixedY = handle === 'start' ? base.y1 : base.y0;
      let x = this.snapCoordinate(point.x);
      let y = this.snapCoordinate(point.y);
      if (snapDiagonal) {
        const vx = point.x - fixedX;
        const vy = point.y - fixedY;
        const length = Math.hypot(vx, vy);
        const angle = Math.round(Math.atan2(vy, vx) / (Math.PI / 4)) * (Math.PI / 4);
        x = Math.round(fixedX + Math.cos(angle) * length);
        y = Math.round(fixedY + Math.sin(angle) * length);
      }
      if (handle === 'start') {
        shape.x0 = x;
        shape.y0 = y;
      } else {
        shape.x1 = x;
        shape.y1 = y;
      }
    } else if (handle === 'thickness') {
      const vx = base.x1 - base.x0;
      const vy = base.y1 - base.y0;
      const length = Math.hypot(vx, vy);
      const nx = length ? -vy / length : 0;
      const ny = length ? vx / length : -1;
      const mx = (base.x0 + base.x1) / 2;
      const my = (base.y0 + base.y1) / 2;
      const distance = Math.abs((point.x - mx) * nx + (point.y - my) * ny)
        - this.drag.thicknessHandleOffset;
      shape.t = this.snapSize(2 * Math.max(0, distance));
    }
    return next;
  }

  pickObstacle(spec, point) {
    const obstacles = spec.leftObstacles || [];
    for (let index = obstacles.length - 1; index >= 0; index -= 1) {
      if (this.hitAuthoringProxy(obstacles[index], point)) return index;
    }
    return -1;
  }

  hitAuthoringProxy(shape, point) {
    const scale = this.viewport.response.renderScale * this.viewport.zoom;
    const tolerance = 7 / Math.max(scale, 0.001);
    // Selection deliberately uses parameter envelopes, not Nim's wall
    // predicates. In particular, discs and diamonds share the same square
    // proxy and diagonals use only their centerline; carving and thickness do
    // not decide selection. The authored list remains the canonical fallback.
    if (shape.kind === 'rect') {
      return point.x >= shape.x - tolerance && point.x <= shape.x + shape.w + tolerance
        && point.y >= shape.y - tolerance && point.y <= shape.y + shape.h + tolerance;
    }
    if (shape.kind === 'disc' || shape.kind === 'diamond') {
      return point.x >= shape.cx - shape.r - tolerance && point.x <= shape.cx + shape.r + tolerance
        && point.y >= shape.cy - shape.r - tolerance && point.y <= shape.cy + shape.r + tolerance;
    }
    return pointSegmentDistance(point.x, point.y, shape.x0, shape.y0, shape.x1, shape.y1)
      <= tolerance;
  }

  handlePoints(shape) {
    if (shape.kind === 'rect') {
      const x0 = shape.x;
      const x1 = shape.x + shape.w;
      const y0 = shape.y;
      const y1 = shape.y + shape.h;
      const cx = (x0 + x1) / 2;
      const cy = (y0 + y1) / 2;
      return { nw: [x0, y0], n: [cx, y0], ne: [x1, y0], e: [x1, cy], se: [x1, y1], s: [cx, y1], sw: [x0, y1], w: [x0, cy], move: [cx, cy] };
    }
    if (shape.kind === 'disc' || shape.kind === 'diamond') {
      return { n: [shape.cx, shape.cy - shape.r], e: [shape.cx + shape.r, shape.cy], s: [shape.cx, shape.cy + shape.r], w: [shape.cx - shape.r, shape.cy], move: [shape.cx, shape.cy] };
    }
    const mx = (shape.x0 + shape.x1) / 2;
    const my = (shape.y0 + shape.y1) / 2;
    const vx = shape.x1 - shape.x0;
    const vy = shape.y1 - shape.y0;
    const length = Math.hypot(vx, vy);
    const nx = length ? -vy / length : 0;
    const ny = length ? vx / length : -1;
    const thicknessDistance = shape.t / 2 + this.diagonalHandleOffset();
    return {
      start: [shape.x0, shape.y0],
      end: [shape.x1, shape.y1],
      midpoint: [mx, my],
      thickness: [mx + nx * thicknessDistance, my + ny * thicknessDistance],
    };
  }

  diagonalHandleOffset() {
    if (!this.viewport.response) return 0;
    // Keep the thickness handle clear of the midpoint at every zoom. This is
    // screen-space editing chrome; the authored `t` remains the exact full
    // perpendicular thickness sent to Nim.
    return 14 / Math.max(this.viewport.response.renderScale * this.viewport.zoom, 0.001);
  }

  hitHandle(shape, clientX, clientY) {
    const bounds = this.viewport.viewport.getBoundingClientRect();
    const x = clientX - bounds.left;
    const y = clientY - bounds.top;
    const handles = this.handlePoints(shape);
    let closest = null;
    let closestDistance = 10;
    for (const [name, value] of Object.entries(handles)) {
      const point = this.viewport.specToScreen(value[0], value[1]);
      const distance = Math.hypot(x - point.x, y - point.y);
      if (distance <= 9 && distance < closestDistance) {
        closest = name;
        closestDistance = distance;
      }
    }
    return closest;
  }

  drawOverlay(context) {
    const selection = this.store.state.editing.selection;
    if (selection && ['trench', 'medKit'].includes(selection.type) && this.placementController) {
      this.drawPlacementOverlay(context, selection);
      return;
    }
    const shape = this.selectedObstacle();
    if (!shape || !this.viewport.response) return;
    const toScreen = (x, y) => this.viewport.specToScreen(x, y);
    context.save();
    context.strokeStyle = '#f0a64b';
    context.lineWidth = 1.5;
    context.setLineDash([5, 4]);
    context.beginPath();
    if (shape.kind === 'rect') {
      const start = toScreen(shape.x, shape.y);
      const end = toScreen(shape.x + shape.w, shape.y + shape.h);
      context.rect(start.x, start.y, end.x - start.x, end.y - start.y);
    } else if (shape.kind === 'disc') {
      const center = toScreen(shape.cx, shape.cy);
      const radius = shape.r * this.viewport.response.renderScale * this.viewport.zoom;
      context.arc(center.x, center.y, radius, 0, Math.PI * 2);
    } else if (shape.kind === 'diamond') {
      const north = toScreen(shape.cx, shape.cy - shape.r);
      const east = toScreen(shape.cx + shape.r, shape.cy);
      const south = toScreen(shape.cx, shape.cy + shape.r);
      const west = toScreen(shape.cx - shape.r, shape.cy);
      context.moveTo(north.x, north.y);
      context.lineTo(east.x, east.y);
      context.lineTo(south.x, south.y);
      context.lineTo(west.x, west.y);
      context.closePath();
    } else {
      const start = toScreen(shape.x0, shape.y0);
      const end = toScreen(shape.x1, shape.y1);
      context.moveTo(start.x, start.y);
      context.lineTo(end.x, end.y);
      const handles = this.handlePoints(shape);
      const midpoint = toScreen(...handles.midpoint);
      const thickness = toScreen(...handles.thickness);
      context.moveTo(midpoint.x, midpoint.y);
      context.lineTo(thickness.x, thickness.y);
    }
    context.stroke();
    context.setLineDash([]);

    const handles = this.handlePoints(shape);
    for (const [name, value] of Object.entries(handles)) {
      const point = toScreen(value[0], value[1]);
      context.beginPath();
      if (name === 'move' || name === 'midpoint') {
        context.arc(point.x, point.y, 5, 0, Math.PI * 2);
      } else {
        context.rect(point.x - 4, point.y - 4, 8, 8);
      }
      context.fillStyle = '#f3ede2';
      context.fill();
      context.strokeStyle = '#8b531b';
      context.lineWidth = 1.5;
      context.stroke();
    }
    context.restore();
  }

  drawPlacementOverlay(context, selection) {
    const group = this.placementController.selectedGroup();
    if (!group) return;
    const preview = this.store.state.editing.placementPreview;
    const seed = preview && preview.type === selection.type && preview.index === selection.index
      ? preview.seed : group.orbit[0];
    context.save();
    context.strokeStyle = '#f0a64b';
    context.fillStyle = '#f3ede2';
    context.lineWidth = 1.5;
    context.setLineDash([5, 4]);
    if (selection.type === 'trench') {
      const shape = { kind: 'rect', x: seed[0], y: seed[1], w: seed[2], h: seed[3] };
      const start = this.viewport.specToScreen(shape.x, shape.y);
      const end = this.viewport.specToScreen(shape.x + shape.w, shape.y + shape.h);
      context.strokeRect(start.x, start.y, end.x - start.x, end.y - start.y);
      if (group.readOnly) {
        context.restore();
        return;
      }
      context.setLineDash([]);
      for (const [name, value] of Object.entries(this.handlePoints(shape))) {
        const point = this.viewport.specToScreen(value[0], value[1]);
        context.beginPath();
        if (name === 'move') context.arc(point.x, point.y, 5, 0, Math.PI * 2);
        else context.rect(point.x - 4, point.y - 4, 8, 8);
        context.fill();
        context.strokeStyle = '#8b531b';
        context.stroke();
      }
    } else {
      const point = this.viewport.specToScreen(seed[0], seed[1]);
      context.setLineDash([]);
      context.beginPath();
      context.arc(point.x, point.y, 6, 0, Math.PI * 2);
      context.fill();
      context.strokeStyle = '#8b531b';
      context.stroke();
      if (group.readOnly) {
        context.restore();
        return;
      }
      context.beginPath();
      context.moveTo(point.x - 10, point.y);
      context.lineTo(point.x + 10, point.y);
      context.moveTo(point.x, point.y - 10);
      context.lineTo(point.x, point.y + 10);
      context.stroke();
    }
    context.restore();
  }
}

function memberKey(member) {
  return JSON.stringify(member);
}

function uniqueMembers(members) {
  const seen = new Set();
  const result = [];
  for (const member of members) {
    const key = memberKey(member);
    if (seen.has(key)) continue;
    seen.add(key);
    result.push(cloneJson(member));
  }
  return result;
}

function orbitKey(orbit) {
  return uniqueMembers(orbit).map(memberKey).sort().join('|');
}

function replaceMembers(values, removedKeys, replacements) {
  const result = [];
  let inserted = false;
  for (const value of values || []) {
    if (removedKeys.has(memberKey(value))) {
      if (!inserted) {
        result.push(...replacements);
        inserted = true;
      }
    } else {
      result.push(value);
    }
  }
  if (!inserted) result.push(...replacements);
  return uniqueMembers(result);
}

class SymmetryPlacementController {
  constructor(api, store, coordinator) {
    this.api = api;
    this.store = store;
    this.coordinator = coordinator;
    this.trenchGroups = [];
    this.medKitGroups = [];
    this.sourceKey = '';
    this.operationRevision = 0;
    this.busy = false;
    this.ready = false;
    this.error = null;
    this.lastEditorKey = '';
    this.bindControls();
    this.store.subscribe((state) => this.update(state));
  }

  bindControls() {
    $('new-trench').addEventListener('click', () => this.addPlacement('trench'));
    $('new-med-kit').addEventListener('click', () => this.addPlacement('medKit'));
    for (const id of ['trench-list', 'med-kit-list']) {
      $(id).addEventListener('click', (event) => {
        const item = event.target.closest('[data-placement-type]');
        if (!item) return;
        this.store.setSelection({
          type: item.dataset.placementType,
          index: Number(item.dataset.placementIndex),
        });
      });
    }
    $('placement-editor').addEventListener('change', (event) => {
      const field = event.target.closest('[data-placement-field]');
      if (field) this.commitNumericField(field);
    });
    $('placement-editor').addEventListener('keydown', (event) => {
      if (event.key === 'Enter' && event.target.matches('[data-placement-field]')) {
        event.preventDefault();
        event.target.blur();
      }
    });
    $('placement-editor').addEventListener('click', (event) => {
      const action = event.target.closest('[data-placement-action]');
      if (!action) return;
      if (action.dataset.placementAction === 'delete') this.deleteSelection();
      if (action.dataset.placementAction === 'active') this.toggleActive();
    });
  }

  structuralKey(spec) {
    if (!spec) return '';
    return JSON.stringify({
      width: spec.width,
      height: spec.height,
      symmetry: spec.symmetry,
      layout: spec.layout,
      trenches: spec.trenches || [],
      medKitCandidates: spec.medKitCandidates || [],
      medKitSpawns: spec.medKitSpawns || [],
    });
  }

  update(state) {
    const spec = state.document.spec;
    const key = this.structuralKey(spec);
    if (key !== this.sourceKey) {
      this.sourceKey = key;
      this.reconstruct(spec);
    }
    this.render(state);
  }

  async reconstruct(spec) {
    const revision = ++this.operationRevision;
    this.ready = false;
    this.error = null;
    if (!spec) {
      this.trenchGroups = [];
      this.medKitGroups = [];
      this.render(this.store.state);
      return;
    }
    this.busy = true;
    this.render(this.store.state);
    try {
      const trenches = spec.symmetry === 'rot90' ? [] : (spec.trenches || []);
      const response = await this.api.symmetry({
        spec: cloneJson(spec),
        trenches: cloneJson(trenches),
        medKits: cloneJson(spec.medKitCandidates || []),
      });
      if (revision !== this.operationRevision) return;
      if (!response || response.ok !== true) {
        throw new Error(response?.error || 'The symmetry service rejected the placements.');
      }
      this.trenchGroups = spec.symmetry === 'rot90'
        ? (spec.trenches || []).map((rect) => ({ orbit: [cloneJson(rect)], readOnly: true }))
        : this.groupOrbits(response.trenches || []);
      const active = new Set((spec.medKitSpawns || []).map(memberKey));
      this.medKitGroups = this.groupOrbits(response.medKits || []).map((group) => ({
        ...group,
        active: group.orbit.every((member) => active.has(memberKey(member))),
        partiallyActive: group.orbit.some((member) => active.has(memberKey(member)))
          && !group.orbit.every((member) => active.has(memberKey(member))),
      }));
      this.ready = true;
      this.reconcileSelection();
    } catch (error) {
      if (revision !== this.operationRevision) return;
      this.error = error instanceof Error ? error.message : String(error);
      this.trenchGroups = (spec.trenches || []).map((rect) => ({ orbit: [cloneJson(rect)], readOnly: true }));
      this.medKitGroups = (spec.medKitCandidates || []).map((point) => ({
        orbit: [cloneJson(point)], readOnly: true,
      }));
    } finally {
      if (revision === this.operationRevision) {
        this.busy = false;
        this.store.setPlacementPreview(null);
        this.render(this.store.state);
      }
    }
  }

  groupOrbits(orbits) {
    const groups = [];
    const seen = new Set();
    for (const orbit of orbits) {
      const members = uniqueMembers(orbit || []);
      const key = orbitKey(members);
      if (!members.length || seen.has(key)) continue;
      seen.add(key);
      groups.push({ orbit: members, readOnly: false });
    }
    return groups;
  }

  reconcileSelection() {
    const selection = this.store.state.editing.selection;
    if (!selection || !['trench', 'medKit'].includes(selection.type)) return;
    const groups = selection.type === 'trench' ? this.trenchGroups : this.medKitGroups;
    if (!groups[selection.index]) this.store.setSelection(null);
  }

  render(state) {
    const spec = state.document.spec;
    const selection = state.editing.selection;
    $('new-trench').disabled = !spec || this.busy || !this.ready || spec.symmetry === 'rot90';
    $('new-med-kit').disabled = !spec || this.busy || !this.ready;
    const status = $('placement-status');
    if (!spec) status.textContent = 'Load a map to author placements.';
    else if (this.busy) status.textContent = 'Resolving symmetry orbits with Nim…';
    else if (this.error) status.textContent = `Symmetry authoring unavailable: ${this.error}`;
    else status.textContent = 'Symmetry orbits resolved by Nim.';
    this.renderGroupList('trench-list', 'Trenches', 'trench', this.trenchGroups, selection);
    this.renderGroupList('med-kit-list', 'Med-kit candidates', 'medKit', this.medKitGroups, selection);
    this.renderEditor(selection);
    this.updatePreviewValues(selection, state.editing.placementPreview);
    this.renderWarning(spec);
  }

  updatePreviewValues(selection, preview) {
    if (!selection || !preview || selection.type !== preview.type || selection.index !== preview.index) return;
    const fieldIndexes = selection.type === 'trench'
      ? { x: 0, y: 1, w: 2, h: 3 }
      : { x: 0, y: 1 };
    for (const input of $('placement-editor').querySelectorAll('[data-placement-field]')) {
      if (document.activeElement !== input) input.value = String(preview.seed[fieldIndexes[input.dataset.placementField]]);
    }
  }

  renderGroupList(rootId, heading, type, groups, selection) {
    const root = $(rootId);
    root.replaceChildren();
    const title = document.createElement('h3');
    title.textContent = `${heading} · ${groups.length} orbit${groups.length === 1 ? '' : 's'}`;
    root.append(title);
    const list = document.createElement('div');
    list.className = 'authored-list';
    if (!groups.length) {
      const empty = document.createElement('p');
      empty.className = 'empty-detail';
      empty.textContent = `No ${heading.toLowerCase()}.`;
      list.append(empty);
    }
    groups.forEach((group, index) => {
      const seed = group.orbit[0];
      const button = document.createElement('button');
      button.type = 'button';
      button.className = 'authored-item';
      button.dataset.placementType = type;
      button.dataset.placementIndex = String(index);
      button.setAttribute('aria-pressed', String(selection?.type === type && selection.index === index));
      const number = document.createElement('span');
      number.className = 'authored-index';
      number.textContent = `#${index + 1}`;
      const kind = document.createElement('span');
      kind.className = 'authored-kind';
      kind.textContent = type === 'trench' ? 'Trench' : 'Med kit';
      if (type === 'medKit' && group.active) kind.classList.add('active-state');
      const detail = document.createElement('span');
      detail.className = 'authored-detail';
      detail.textContent = type === 'trench'
        ? `${seed[0]}, ${seed[1]} · ${seed[2]}×${seed[3]} · ${group.orbit.length} image${group.orbit.length === 1 ? '' : 's'}`
        : `${seed[0]}, ${seed[1]} · ${group.active ? 'active' : group.partiallyActive ? 'mixed active state' : 'candidate'} · ${group.orbit.length} image${group.orbit.length === 1 ? '' : 's'}`;
      button.append(number, kind, detail);
      list.append(button);
    });
    root.append(list);
  }

  selectedGroup() {
    const selection = this.store.state.editing.selection;
    if (!selection) return null;
    if (selection.type === 'trench') return this.trenchGroups[selection.index] || null;
    if (selection.type === 'medKit') return this.medKitGroups[selection.index] || null;
    return null;
  }

  renderEditor(selection) {
    const root = $('placement-editor');
    const group = this.selectedGroup();
    const key = group ? `${selection.type}:${selection.index}:${orbitKey(group.orbit)}:${group.active}` : 'none';
    if (key === this.lastEditorKey) return;
    this.lastEditorKey = key;
    root.replaceChildren();
    root.hidden = !group;
    if (!group) return;
    const isTrench = selection.type === 'trench';
    const seed = group.orbit[0];
    const heading = document.createElement('div');
    heading.className = 'numeric-editor-heading';
    const title = document.createElement('strong');
    title.textContent = `${isTrench ? 'Trench' : 'Med-kit'} orbit ${selection.index + 1}`;
    const count = document.createElement('span');
    count.className = 'quiet-label';
    count.textContent = `${group.orbit.length} deduplicated image${group.orbit.length === 1 ? '' : 's'}`;
    heading.append(title, count);
    const grid = document.createElement('div');
    grid.className = 'numeric-grid';
    const fields = isTrench ? ['x', 'y', 'w', 'h'] : ['x', 'y'];
    fields.forEach((name, index) => {
      const label = document.createElement('label');
      label.textContent = `${name} · px`;
      const input = document.createElement('input');
      input.type = 'number';
      input.step = '1';
      input.required = true;
      input.value = String(seed[index]);
      input.dataset.placementField = name;
      input.disabled = this.busy || group.readOnly;
      label.append(input);
      grid.append(label);
    });
    const actions = document.createElement('div');
    actions.className = 'selection-actions';
    if (!isTrench) {
      const active = document.createElement('button');
      active.type = 'button';
      active.dataset.placementAction = 'active';
      active.disabled = this.busy || group.readOnly;
      active.textContent = group.active ? 'Make candidate only' : 'Make active';
      actions.append(active);
    }
    const remove = document.createElement('button');
    remove.type = 'button';
    remove.className = 'danger-action';
    remove.dataset.placementAction = 'delete';
    remove.disabled = this.busy;
    remove.textContent = isTrench && group.readOnly ? 'Remove this stored trench' : 'Delete orbit';
    actions.append(remove);
    root.append(heading, grid, actions);
  }

  renderWarning(spec) {
    const warning = $('placement-warning');
    if (!spec) {
      warning.hidden = true;
      return;
    }
    const messages = [];
    if (spec.symmetry === 'rot90') messages.push('Trench authoring is unavailable on rot90 maps; the generator does not support 4-team trenches.');
    if ((spec.medKitSpawns || []).length < 2) messages.push('Fewer than two active med-kit points triggers the runtime hardcoded centre-thirds fallback.');
    const active = new Set((spec.medKitSpawns || []).map(memberKey));
    const candidates = new Set((spec.medKitCandidates || []).map(memberKey));
    if ([...active].some((key) => !candidates.has(key))) messages.push('Active med-kit spawns must be a subset of candidates.');
    warning.textContent = messages.join(' ');
    warning.hidden = !messages.length;
  }

  seedCenter(spec) {
    const seed = this.store.state.render.lastGoodResponse?.derived?.seedRegion
      || { x: 0, y: 0, w: spec.width, h: spec.height };
    return [Math.round(seed.x + seed.w / 2), Math.round(seed.y + seed.h / 2)];
  }

  async expand(spec, trenches, medKits) {
    const response = await this.api.symmetry({
      spec: cloneJson(spec),
      trenches: cloneJson(trenches),
      medKits: cloneJson(medKits),
    });
    if (!response || response.ok !== true) throw new Error(response?.error || 'Symmetry expansion failed.');
    return response;
  }

  async runMutation(label, operation) {
    if (this.busy || !this.ready) return;
    const revision = ++this.operationRevision;
    const documentRevision = this.store.state.document.revision;
    this.busy = true;
    this.error = null;
    this.render(this.store.state);
    try {
      const result = await operation(cloneJson(this.store.state.document.spec));
      if (revision !== this.operationRevision || !result
          || documentRevision !== this.store.state.document.revision) return;
      if (this.store.commitSpec(result.spec, label, result.selection)) {
        this.coordinator.schedule({ immediate: true });
      }
    } catch (error) {
      if (revision === this.operationRevision) this.error = error instanceof Error ? error.message : String(error);
    } finally {
      if (revision === this.operationRevision) {
        this.busy = false;
        this.render(this.store.state);
      }
    }
  }

  addPlacement(type) {
    const spec = this.store.state.document.spec;
    if (!spec || (type === 'trench' && spec.symmetry === 'rot90')) return;
    let [cx, cy] = this.seedCenter(spec);
    if (this.store.state.controls.snapToGrid) {
      const size = this.store.state.controls.gridSize;
      cx = Math.round(cx / size) * size;
      cy = Math.round(cy / size) * size;
    }
    const seed = type === 'trench' ? [cx - 28, cy - 28, 56, 56] : [cx, cy];
    this.runMutation(`create ${type === 'trench' ? 'trench' : 'med-kit orbit'}`, async (next) => {
      const response = await this.expand(next, type === 'trench' ? [seed] : [], type === 'medKit' ? [seed] : []);
      if (type === 'trench') {
        const orbit = uniqueMembers(response.trenches[0] || []);
        next.trenches = uniqueMembers([...(next.trenches || []), ...orbit]);
        return { spec: next, selection: { type: 'trench', index: this.trenchGroups.length } };
      }
      const orbit = uniqueMembers(response.medKits[0] || []);
      next.medKitCandidates = uniqueMembers([...(next.medKitCandidates || []), ...orbit]);
      return { spec: next, selection: { type: 'medKit', index: this.medKitGroups.length } };
    });
  }

  commitNumericField(input) {
    if (this.busy) return;
    const selection = this.store.state.editing.selection;
    const group = this.selectedGroup();
    if (!selection || !group || group.readOnly) return;
    const value = input.value === '' ? Number.NaN : Number(input.value);
    if (!Number.isInteger(value)) {
      input.setCustomValidity('Enter an integer number of map pixels.');
      input.reportValidity();
      return;
    }
    const indexByField = selection.type === 'trench'
      ? { x: 0, y: 1, w: 2, h: 3 }
      : { x: 0, y: 1 };
    const field = input.dataset.placementField;
    if ((field === 'w' || field === 'h') && value < 1) {
      input.setCustomValidity(`${field} must be at least 1 px.`);
      input.reportValidity();
      return;
    }
    const seed = cloneJson(group.orbit[0]);
    seed[indexByField[field]] = value;
    this.replaceOrbit(selection, group, seed, `edit ${selection.type} ${field}`);
  }

  replaceOrbit(selection, group, seed, label) {
    this.runMutation(label, async (next) => {
      const response = await this.expand(next, selection.type === 'trench' ? [seed] : [], selection.type === 'medKit' ? [seed] : []);
      const replacement = uniqueMembers(selection.type === 'trench' ? response.trenches[0] : response.medKits[0]);
      const old = new Set(group.orbit.map(memberKey));
      if (selection.type === 'trench') {
        next.trenches = replaceMembers(next.trenches, old, replacement);
      } else {
        next.medKitCandidates = replaceMembers(next.medKitCandidates, old, replacement);
        const active = new Set((next.medKitSpawns || []).map(memberKey));
        next.medKitSpawns = replaceMembers(next.medKitSpawns, old, []);
        if (group.active || group.orbit.some((member) => active.has(memberKey(member)))) {
          next.medKitSpawns = replaceMembers(next.medKitSpawns, new Set(), replacement);
        }
      }
      return { spec: next, selection: cloneJson(selection) };
    });
  }

  deleteSelection() {
    if (this.busy) return;
    const selection = this.store.state.editing.selection;
    const group = this.selectedGroup();
    const spec = this.store.state.document.spec;
    if (!selection || !group || !spec) return;
    const old = new Set(group.orbit.map(memberKey));
    const next = cloneJson(spec);
    if (selection.type === 'trench') next.trenches = (next.trenches || []).filter((member) => !old.has(memberKey(member)));
    else {
      next.medKitCandidates = (next.medKitCandidates || []).filter((member) => !old.has(memberKey(member)));
      next.medKitSpawns = (next.medKitSpawns || []).filter((member) => !old.has(memberKey(member)));
    }
    if (this.store.commitSpec(next, `delete ${selection.type} orbit`, null)) this.coordinator.schedule({ immediate: true });
  }

  toggleActive() {
    if (this.busy) return;
    const selection = this.store.state.editing.selection;
    const group = this.selectedGroup();
    const spec = this.store.state.document.spec;
    if (!selection || selection.type !== 'medKit' || !group || group.readOnly || !spec) return;
    const next = cloneJson(spec);
    const members = new Set(group.orbit.map(memberKey));
    next.medKitSpawns = (next.medKitSpawns || []).filter((point) => !members.has(memberKey(point)));
    if (!group.active) next.medKitSpawns = uniqueMembers(next.medKitSpawns.concat(group.orbit));
    if (this.store.commitSpec(next, group.active ? 'deactivate med-kit orbit' : 'activate med-kit orbit')) {
      this.coordinator.schedule({ immediate: true });
    }
  }

  async reexpandForSpec(candidateSpec) {
    if (!this.ready || this.busy) throw new Error('Wait for the current symmetry orbits to resolve.');
    if (candidateSpec.symmetry === 'rot90' && (candidateSpec.trenches || []).length) {
      throw new Error('Remove all trenches before switching to rot90 symmetry.');
    }
    const trenchSeeds = this.trenchGroups.map((group) => group.orbit[0]);
    const medSeeds = this.medKitGroups.map((group) => group.orbit[0]);
    const response = await this.expand(candidateSpec, trenchSeeds, medSeeds);
    candidateSpec.trenches = uniqueMembers((response.trenches || []).flat());
    candidateSpec.medKitCandidates = uniqueMembers((response.medKits || []).flat());
    candidateSpec.medKitSpawns = uniqueMembers((response.medKits || [])
      .filter((orbit, index) => this.medKitGroups[index]?.active)
      .flat());
    return candidateSpec;
  }
}

const TIER_ONE_FIELDS = [
  { name: 'width', label: 'Width · px', type: 'number', minimum: 1 },
  { name: 'height', label: 'Height · px', type: 'number', minimum: 1 },
  { name: 'symmetry', label: 'Symmetry', options: ['mirror', 'rot180', 'rot90'] },
  { name: 'layout', label: 'Layout', options: ['sides', 'corners', 'plus'] },
  { name: 'endzone', label: 'Endzone', options: ['column', 'disc', 'square'] },
  { name: 'endzoneRadius', label: 'Endzone radius · px', type: 'number', minimum: 0 },
  { name: 'homeDepth', label: 'Home depth · ‰', type: 'number', minimum: 0 },
  { name: 'flagRing', label: 'Flag ring · px', type: 'number', minimum: 0 },
  { name: 'captureClear', label: 'Capture clear · px', type: 'number', minimum: 0 },
  { name: 'spawnClearW', label: 'Spawn clear width · px', type: 'number', minimum: 0 },
  { name: 'spawnClearH', label: 'Spawn clear height · px', type: 'number', minimum: 0 },
];

class TierOneController {
  constructor(store, coordinator, placements) {
    this.store = store;
    this.coordinator = coordinator;
    this.placements = placements;
    this.busy = false;
    this.buildFields();
    this.store.subscribe((state) => this.render(state));
  }

  buildFields() {
    const root = $('tier-one-editor');
    for (const config of TIER_ONE_FIELDS) {
      const label = document.createElement('label');
      label.textContent = config.label;
      let field;
      if (config.options) {
        field = document.createElement('select');
        for (const value of config.options) {
          const option = document.createElement('option');
          option.value = value;
          option.textContent = humanizeToken(value);
          field.append(option);
        }
      } else {
        field = document.createElement('input');
        field.type = 'number';
        field.step = '1';
        field.min = String(config.minimum);
        field.required = true;
      }
      field.dataset.tierField = config.name;
      field.addEventListener('change', () => this.commitField(field, config));
      field.addEventListener('keydown', (event) => {
        if (event.key === 'Enter') {
          event.preventDefault();
          field.blur();
        }
      });
      label.append(field);
      root.append(label);
    }
  }

  render(state) {
    const spec = state.document.spec;
    for (const field of $('tier-one-editor').querySelectorAll('[data-tier-field]')) {
      field.disabled = !spec || this.busy;
      if (spec && document.activeElement !== field) field.value = String(spec[field.dataset.tierField]);
    }
    this.renderWarnings(spec);
  }

  renderWarnings(spec) {
    const root = $('parameter-warning');
    if (!spec) {
      root.hidden = true;
      return;
    }
    const messages = [];
    if (spec.symmetry === 'rot90' && spec.width !== spec.height) messages.push('rot90 symmetry requires a square board; the service will reject this spec.');
    if (spec.layout === 'sides' && spec.symmetry === 'rot90') messages.push('Sides layout cannot use rot90 symmetry.');
    if (spec.layout !== 'sides' && spec.symmetry !== 'rot90') messages.push('Corners and plus layouts require rot90 symmetry.');
    if (spec.layout !== 'sides' && spec.endzone !== 'column') messages.push('Compact endzones require a 2-team sides layout.');
    if (spec.endzone === 'column' && spec.endzoneRadius !== 0) messages.push('Column endzones carry no radius; set endzone radius to 0.');
    if (this.authoredGeometryOutside(spec)) messages.push('Some authored geometry or pickup coordinates lie outside the current dimensions.');
    root.textContent = messages.join(' ');
    root.hidden = !messages.length;
  }

  authoredGeometryOutside(spec) {
    const pointOutside = (point) => point[0] < 0 || point[1] < 0
      || point[0] >= spec.width || point[1] >= spec.height;
    if ((spec.medKitCandidates || []).some(pointOutside) || (spec.medKitSpawns || []).some(pointOutside)) return true;
    if ((spec.trenches || []).some((rect) => rect[0] < 0 || rect[1] < 0
        || rect[0] + rect[2] > spec.width || rect[1] + rect[3] > spec.height)) return true;
    for (const shape of spec.leftObstacles || []) {
      if (shape.kind === 'rect' && (shape.x < 0 || shape.y < 0
          || shape.x + shape.w > spec.width || shape.y + shape.h > spec.height)) return true;
      if ((shape.kind === 'disc' || shape.kind === 'diamond') && (shape.cx - shape.r < 0
          || shape.cy - shape.r < 0 || shape.cx + shape.r >= spec.width || shape.cy + shape.r >= spec.height)) return true;
      if (shape.kind === 'diagonal') {
        const half = shape.t / 2;
        if (Math.min(shape.x0, shape.x1) - half < 0 || Math.min(shape.y0, shape.y1) - half < 0
            || Math.max(shape.x0, shape.x1) + half >= spec.width
            || Math.max(shape.y0, shape.y1) + half >= spec.height) return true;
      }
    }
    return false;
  }

  async commitField(field, config) {
    const spec = this.store.state.document.spec;
    if (!spec || this.busy) return;
    let value = field.value;
    if (!config.options) {
      value = value === '' ? Number.NaN : Number(value);
      if (!Number.isInteger(value) || value < config.minimum) {
        field.setCustomValidity(`Enter an integer of at least ${config.minimum}.`);
        field.reportValidity();
        return;
      }
    }
    field.setCustomValidity('');
    if (spec[config.name] === value) return;
    if (config.name === 'symmetry' && value === 'rot90' && (spec.trenches || []).length) {
      field.setCustomValidity('Remove all trenches before switching to rot90 symmetry.');
      field.reportValidity();
      field.value = spec.symmetry;
      return;
    }
    this.busy = true;
    const documentRevision = this.store.state.document.revision;
    this.render(this.store.state);
    try {
      let next = cloneJson(spec);
      next[config.name] = value;
      // Layout and symmetry are one compatibility choice in the map format.
      // Commit their required counterpart together so the user is not trapped
      // between two service-rejected intermediate states.
      if (config.name === 'layout') {
        if (value === 'sides' && next.symmetry === 'rot90') next.symmetry = 'mirror';
        if (value !== 'sides') {
          next.symmetry = 'rot90';
          next.endzone = 'column';
          next.endzoneRadius = 0;
        }
      }
      if (config.name === 'symmetry') {
        if (value === 'rot90') {
          if (next.layout === 'sides') next.layout = 'corners';
          next.endzone = 'column';
          next.endzoneRadius = 0;
        } else if (next.layout !== 'sides') {
          next.layout = 'sides';
        }
      }
      if (['width', 'height', 'symmetry', 'layout'].includes(config.name)) {
        const intentionallyInvalidRot90 = next.symmetry === 'rot90' && next.width !== next.height;
        if (!intentionallyInvalidRot90) {
          try {
            next = await this.placements.reexpandForSpec(next);
          } catch (error) {
            // Dimension edits are allowed to strand authored geometry. Preserve
            // it verbatim so the map render can report the authoritative error.
            if (!['width', 'height'].includes(config.name)) throw error;
          }
        }
      }
      if (documentRevision !== this.store.state.document.revision) {
        throw new Error('The map changed while this parameter was being derived. Try again.');
      }
      if (this.store.commitSpec(next, `edit map ${config.name}`)) {
        this.coordinator.schedule({ immediate: true });
      }
    } catch (error) {
      field.setCustomValidity(error instanceof Error ? error.message : String(error));
      field.reportValidity();
      field.value = String(spec[config.name]);
    } finally {
      this.busy = false;
      this.render(this.store.state);
    }
  }
}

class DiagnosticController {
  constructor(store, viewport) {
    this.store = store;
    this.viewport = viewport;
    this.root = $('validation-failures');
    this.targets = new Map();
    this.selectedId = null;
    this.previewId = null;
    this.lastResponse = null;
    this.lastError = '';
    this.lastLoadRevision = 0;
    this.bindEvents();
    this.store.subscribe((state) => this.update(state));
  }

  bindEvents() {
    this.root.addEventListener('click', (event) => {
      const button = event.target.closest('[data-diagnostic-id]');
      if (!button) return;
      const id = button.dataset.diagnosticId;
      const target = this.targets.get(id);
      if (!target) return;
      this.selectedId = this.selectedId === id ? null : id;
      this.previewId = null;
      this.renderSelection();
      this.viewport.setDiagnosticTarget(this.selectedId ? target : null);
      if (this.selectedId) {
        this.viewport.focusDiagnostic(target);
        this.announce(`Located ${target.announcement}.`);
      } else {
        this.announce('Failure highlight cleared.');
      }
    });

    const preview = (event) => {
      const button = event.target.closest('[data-diagnostic-id]');
      if (!button) return;
      this.previewId = button.dataset.diagnosticId;
      this.viewport.setDiagnosticTarget(this.targets.get(this.previewId));
    };
    this.root.addEventListener('pointerover', preview);
    this.root.addEventListener('focusin', preview);
    const clearPreview = (event) => {
      if (event.relatedTarget && this.root.contains(event.relatedTarget)) return;
      this.previewId = null;
      this.viewport.setDiagnosticTarget(this.targets.get(this.selectedId) || null);
    };
    this.root.addEventListener('pointerleave', clearPreview);
    this.root.addEventListener('focusout', clearPreview);
  }

  update(state) {
    const response = state.render.lastGoodResponse;
    const error = state.render.error ? `${state.render.error.kind}:${state.render.error.message}` : '';
    const loadedNewDocument = state.document.loadRevision !== this.lastLoadRevision;
    if (response === this.lastResponse && error === this.lastError && !loadedNewDocument) return;
    this.lastResponse = response;
    this.lastError = error;
    this.lastLoadRevision = state.document.loadRevision;
    if (loadedNewDocument) {
      this.selectedId = null;
      this.previewId = null;
      this.viewport.setDiagnosticTarget(null);
    }
    if (error) {
      this.root.hidden = true;
      return;
    }
    const previousSelection = this.selectedId;
    const targetList = this.buildTargets(error ? null : response);
    const previousTarget = this.targets.get(this.selectedId);
    this.targets = new Map(targetList.filter((target) => target.actionable)
      .map((target) => [target.id, target]));
    if (this.selectedId && !this.targets.has(this.selectedId)
        && previousTarget?.kind === 'sightline') {
      const continued = targetList.find((target) => (
        target.kind === 'sightline' && target.rows.includes(previousTarget.rows[0])
      ));
      if (continued) this.selectedId = continued.id;
    }
    if (this.selectedId && !this.targets.has(this.selectedId)) {
      this.selectedId = null;
      this.previewId = null;
      this.viewport.setDiagnosticTarget(null);
      this.announce('The selected failure is resolved in the latest render.');
    } else if (this.selectedId) {
      this.viewport.setDiagnosticTarget(this.targets.get(this.selectedId));
    }
    this.renderTargets(targetList);
    if (previousSelection === this.selectedId) this.renderSelection();
  }

  buildTargets(response) {
    if (!response?.validation || response.validation.valid) return [];
    const validation = response.validation;
    const derived = response.derived || {};
    const result = [];
    const minimum = validation.coverPermilleMin;
    const maximum = validation.coverPermilleMax;
    if (Number.isFinite(minimum) && validation.minCoverPermille < minimum) {
      result.push({
        id: 'cover:open', actionable: false,
        label: 'Too little always-solid cover',
        detail: `${formatInteger(validation.minCoverPermille)}‰ · minimum ${formatInteger(minimum)}‰ · global`,
      });
    }
    if (Number.isFinite(maximum) && validation.coverPermille > maximum) {
      result.push({
        id: 'cover:clogged', actionable: false,
        label: 'Too much swept cover',
        detail: `${formatInteger(validation.coverPermille)}‰ · maximum ${formatInteger(maximum)}‰ · global`,
      });
    }

    const sightlineRange = validation.sightlineXRange;
    if (sightlineRange) {
      for (const rows of groupSightlineRows(validation.openSightlineRows)) {
        const range = rows.length === 1
          ? `y ${formatInteger(rows[0])} px`
          : `y ${formatInteger(rows[0])}–${formatInteger(rows.at(-1))} px`;
        result.push({
          id: `sightline:${rows.join(',')}`,
          actionable: true,
          kind: 'sightline',
          rows,
          xLo: sightlineRange.xLo,
          xHi: sightlineRange.xHi,
          label: `Open sightline · ${range}`,
          detail: `${formatInteger(rows.length)} sampled row${rows.length === 1 ? '' : 's'}`,
          announcement: `open sightline ${range}, x ${formatInteger(sightlineRange.xLo)} to ${formatInteger(sightlineRange.xHi)} pixels`,
        });
      }
    }

    const anchors = derived.anchors || [];
    const anchorFor = (team) => anchors.find((anchor) => anchor.team === team);
    if (validation.redHomeOnOpenFloor === false) {
      const anchor = anchorFor('red');
      if (anchor) result.push(this.pointTarget(
        'red-home', anchor, 'Red flag home is not on open floor',
        'Red pedestal', 'Red flag home',
      ));
    }
    for (const team of validation.unreachableTeams || []) {
      const anchor = anchorFor(team);
      if (anchor) result.push(this.pointTarget(
        `team:${team}`, anchor, `${humanizeToken(team)} route is unreachable`,
        `${humanizeToken(team)} pedestal`, `${humanizeToken(team)} unreachable route`,
      ));
    }
    if (validation.centerReachable === false && derived.center) {
      result.push(this.pointTarget(
        'center', derived.center, 'Map center is unreachable',
        formatPoint(derived.center.x, derived.center.y), 'unreachable map center',
      ));
    }
    for (const gate of validation.endzoneGates || []) {
      if (!['sealed', 'offMap'].includes(gate.state)) continue;
      result.push({
        id: `gate:${gate.name}`,
        actionable: true,
        kind: 'point',
        x: gate.x,
        y: gate.y,
        offMap: gate.state === 'offMap',
        label: `${humanizeToken(gate.name)} gate · ${humanizeToken(gate.state)}`,
        detail: formatPoint(gate.x, gate.y),
        announcement: `${gate.name} endzone gate, ${humanizeToken(gate.state)}, at ${formatPoint(gate.x, gate.y)}`,
      });
    }
    if (validation.endzoneFlankChecked
        && validation.rearGateReachesCenterWithoutEndzone === false) {
      const behind = (validation.endzoneGates || []).find((gate) => gate.name === 'behind');
      const anchor = behind || anchorFor('red');
      if (anchor) result.push(this.pointTarget(
        'rear-flank', anchor, 'No route around the endzone',
        behind ? 'Behind gate to center' : 'Behind the Red base', 'rear-flank route failure',
      ));
    }
    return result;
  }

  pointTarget(id, point, label, detail, announcement) {
    return {
      id,
      actionable: true,
      kind: 'point',
      x: point.x,
      y: point.y,
      label,
      detail,
      announcement: `${announcement} at ${formatPoint(point.x, point.y)}`,
    };
  }

  renderTargets(targets) {
    this.root.replaceChildren();
    this.root.hidden = targets.length === 0;
    if (!targets.length) return;
    const heading = document.createElement('h3');
    heading.textContent = 'Failures';
    const list = document.createElement('div');
    list.className = 'diagnostic-list';
    for (const target of targets) {
      const item = document.createElement(target.actionable ? 'button' : 'div');
      item.className = target.actionable ? 'diagnostic-item' : 'diagnostic-global';
      if (target.actionable) {
        item.type = 'button';
        item.dataset.diagnosticId = target.id;
        item.setAttribute('aria-pressed', String(target.id === this.selectedId));
      }
      const label = document.createElement('strong');
      label.textContent = target.label;
      const detail = document.createElement('span');
      detail.textContent = target.actionable ? `${target.detail} · Locate` : target.detail;
      item.append(label, detail);
      list.append(item);
    }
    this.root.append(heading, list);
  }

  renderSelection() {
    for (const button of this.root.querySelectorAll('[data-diagnostic-id]')) {
      button.setAttribute('aria-pressed', String(button.dataset.diagnosticId === this.selectedId));
    }
  }

  announce(message) {
    $('diagnostic-status').textContent = '';
    window.requestAnimationFrame(() => { $('diagnostic-status').textContent = message; });
  }
}

class InspectorView {
  constructor(store) {
    this.store = store;
    this.lastRenderedRequestRevision = -1;
    this.lastError = null;
    this.store.subscribe((state) => this.render(state));
  }

  render(state) {
    const render = state.render;
    this.renderStatus(state);
    this.renderDocumentActions(state);

    const errorKey = render.error ? `${render.error.kind}:${render.error.message}` : '';
    if (
      render.renderedRequestRevision === this.lastRenderedRequestRevision
      && errorKey === this.lastError
    ) return;

    this.lastRenderedRequestRevision = render.renderedRequestRevision;
    this.lastError = errorKey;
    this.renderValidation(state);
    this.renderSummary(state);
    this.renderDerived(state);
  }

  renderStatus(state) {
    const render = state.render;
    const status = $('render-status');
    status.classList.toggle('rendering', render.pending);
    status.classList.toggle('error', Boolean(render.error));

    if (render.error) {
      const prefix = render.error.kind === 'domain' ? 'Spec rejected' : 'Service error';
      const retained = render.lastGoodResponse ? ' · last good board retained' : '';
      status.textContent = `${prefix}: ${render.error.message}${retained}`;
      return;
    }
    if (render.pending) {
      if (render.lastGoodResponse) {
        status.textContent = `Rendering request ${render.latestRequestedRevision} · showing request ${render.renderedRequestRevision}`;
      } else {
        status.textContent = `Rendering request ${render.latestRequestedRevision}`;
      }
      return;
    }
    if (render.lastGoodResponse) {
      status.textContent = `Rendered request ${render.renderedRequestRevision} · Nim geometry`;
    } else {
      status.textContent = 'Waiting for a map';
    }
  }

  renderDocumentActions(state) {
    const hasSpec = Boolean(state.document.spec);
    $('copy-spec').disabled = !hasSpec;
    $('download-spec').disabled = !hasSpec;
  }

  renderValidation(state) {
    const error = state.render.error;
    const badge = $('validation-state');
    const reason = $('validation-reason');
    const details = $('validation-details');
    details.replaceChildren();

    if (error) {
      badge.className = 'validation-state invalid';
      badge.textContent = error.kind === 'domain' ? 'Spec error' : 'Unavailable';
      reason.textContent = error.message;
      if (state.render.lastGoodResponse) {
        appendDetail(details, 'Board shown', 'Last successful render; it does not represent the rejected spec');
      }
      return;
    }

    const validation = state.render.lastGoodResponse && state.render.lastGoodResponse.validation;
    if (!validation) {
      badge.className = 'validation-state neutral';
      badge.textContent = 'Not run';
      reason.textContent = 'Load a map to run the Nim validators.';
      return;
    }

    badge.className = `validation-state ${validation.valid ? 'valid' : 'invalid'}`;
    badge.textContent = validation.valid ? 'Play-valid' : 'Needs review';
    reason.textContent = validation.reason || (validation.valid
      ? 'The map passes all play-quality checks.'
      : 'The map did not pass validation.');

    const minimum = validation.coverPermilleMin;
    const maximum = validation.coverPermilleMax;
    appendDetail(
      details,
      'Always-solid cover',
      `${formatInteger(validation.minCoverPermille)}‰${Number.isFinite(minimum) ? ` · minimum ${formatInteger(minimum)}‰` : ''}`,
    );
    appendDetail(
      details,
      'Swept cover',
      `${formatInteger(validation.coverPermille)}‰${Number.isFinite(maximum) ? ` · maximum ${formatInteger(maximum)}‰` : ''}`,
    );

    const rows = validation.openSightlineRows || [];
    const runs = groupSightlineRows(rows);
    appendDetail(
      details,
      'Sightlines',
      rows.length
        ? `${rows.length} open sampled rows · ${runs.length} run${runs.length === 1 ? '' : 's'}`
        : 'No open cross-field rows',
    );

    const unreachable = validation.unreachableTeams || [];
    appendDetail(
      details,
      'Team routes',
      unreachable.length ? `${unreachable.join(', ')} cannot reach required space` : 'All teams reachable',
    );
    appendDetail(details, 'Map center', validation.centerReachable ? 'Reachable' : 'Unreachable');

    const gates = validation.endzoneGates || [];
    appendDetail(
      details,
      'Endzone gates',
      gates.length
        ? gates.map((gate) => `${gate.name}: ${gate.state}`).join(' · ')
        : 'No compact-endzone gate results',
    );
  }

  renderSummary(state) {
    const response = state.render.lastGoodResponse;
    const spec = state.render.lastGoodSpec;
    const summary = $('map-summary');
    const source = $('document-source');
    const seedNote = $('seed-region-note');
    summary.replaceChildren();
    source.textContent = state.document.source || 'No source';

    if (!response || !spec) {
      seedNote.hidden = true;
      $('map-caption').textContent = 'Load a map to inspect the server-rendered terrain.';
      return;
    }

    const stale = state.render.renderedDocumentRevision !== state.document.revision;
    $('map-caption').textContent = stale
      ? `${spec.name || 'Unnamed map'} · showing the last accepted document revision`
      : `${spec.name || 'Unnamed map'} · full expanded board`;
    const derived = response.derived || {};
    appendDetail(summary, 'Dimensions', `${formatInteger(spec.width)} × ${formatInteger(spec.height)} map px`);
    appendDetail(summary, 'Teams', `${formatInteger(derived.teamCount)} teams · ${humanizeToken(spec.layout)} layout`);
    appendDetail(summary, 'Symmetry', humanizeToken(spec.symmetry));
    appendDetail(summary, 'Endzone', formatEndzone(spec));
    appendDetail(summary, 'Obstacles', `${formatInteger(derived.authoredObstacleCount)} authored · ${formatInteger(derived.expandedObstacleCount)} expanded`);
    appendDetail(summary, 'Trenches', `${formatInteger((spec.trenches || []).length)} full-map rectangles`);
    appendDetail(summary, 'Render scale', `${response.renderScale.toFixed(4)} image px per map px`);

    const seed = derived.seedRegion;
    if (seed) {
      seedNote.hidden = false;
      seedNote.textContent = `Conventional seed guide: x ${formatInteger(seed.x)}–${formatInteger(seed.x + seed.w - 1)} px, y ${formatInteger(seed.y)}–${formatInteger(seed.y + seed.h - 1)} px. Advisory only; authored generator shapes may cross it.`;
    } else {
      seedNote.hidden = true;
    }
  }

  renderDerived(state) {
    const response = state.render.lastGoodResponse;
    const spec = state.render.lastGoodSpec;
    const root = $('derived-markers');
    root.replaceChildren();
    if (!response || !spec || !response.derived) {
      const empty = document.createElement('p');
      empty.className = 'empty-detail';
      empty.textContent = 'No derived data yet.';
      root.append(empty);
      return;
    }

    const derived = response.derived;
    addMarkerGroup(root, 'Pedestals', (derived.anchors || []).map((anchor) => (
      `${humanizeToken(anchor.team)} pedestal · ${formatPoint(anchor.x, anchor.y)}`
    )));

    addMarkerGroup(root, 'Capture zones', (derived.captureZones || []).map((zone) => {
      const shape = zone.diag ? `diagonal · L1 limit ${zone.diagLimit} px`
        : zone.disc ? `disc · radius ${zone.radius} px`
          : `box · x ${zone.xLo}–${zone.xHi} px · y ${zone.yLo}–${zone.yHi} px`;
      return `${humanizeToken(zone.team)} · ${shape}`;
    }));

    const pickupItems = [];
    for (const [family, points] of Object.entries(derived.pickups || {})) {
      for (const point of points || []) {
        pickupItems.push(`${humanizeToken(family)} ${formatPoint(point[0], point[1])}`);
      }
    }
    addMarkerGroup(root, 'Nominal pickups', pickupItems);

    addMarkerGroup(root, 'Spinning diamonds', (derived.spinningDiamonds || []).map((diamond) => (
      `${formatPoint(diamond.cx, diamond.cy)} · L1 radius ${formatInteger(diamond.r)} px`
    )));

    addMarkerGroup(root, 'Trenches', (spec.trenches || []).map((trench) => (
      `x ${formatInteger(trench[0])} px · y ${formatInteger(trench[1])} px · ${formatInteger(trench[2])} × ${formatInteger(trench[3])} px`
    )));
  }
}

function appendDetail(list, term, description) {
  const dt = document.createElement('dt');
  dt.textContent = term;
  const dd = document.createElement('dd');
  dd.textContent = description;
  list.append(dt, dd);
}

function addMarkerGroup(root, heading, items) {
  if (!items.length) return;
  const group = document.createElement('section');
  group.className = 'marker-group';
  const title = document.createElement('h3');
  title.textContent = heading;
  const list = document.createElement('ul');
  for (const item of items) {
    const listItem = document.createElement('li');
    listItem.textContent = item;
    list.append(listItem);
  }
  group.append(title, list);
  root.append(group);
}

function formatEndzone(spec) {
  if (spec.endzone === 'column') {
    return `Column · base depth ${formatInteger(spec.homeDepth)}‰ of half-field`;
  }
  return `${humanizeToken(spec.endzone)} · radius ${formatInteger(spec.endzoneRadius)} px · base depth ${formatInteger(spec.homeDepth)}‰ of half-field`;
}

class Application {
  constructor() {
    const params = new URLSearchParams(window.location.search);
    this.mockMode = params.get('mock') === '1';
    this.api = this.mockMode ? new MockMapEditorApi() : new MapEditorApi();
    this.store = new EditorStore();
    this.coordinator = new RenderCoordinator(this.api, this.store);
    this.viewport = new MapViewport(this.store);
    this.editing = new EditingController(this.store, this.coordinator, this.viewport);
    this.viewport.setEditingController(this.editing);
    this.placements = new SymmetryPlacementController(this.api, this.store, this.coordinator);
    this.editing.setPlacementController(this.placements);
    this.parameters = new TierOneController(this.store, this.coordinator, this.placements);
    this.diagnostics = new DiagnosticController(this.store, this.viewport);
    this.inspector = new InspectorView(this.store);
  }

  async start() {
    this.bindSourceTabs();
    this.bindSourceControls();
    this.bindOverlayControls();
    this.bindExportControls();

    if (this.mockMode) {
      $('mock-badge').hidden = false;
      this.setConnectionStatus('Mock API active', 'connected');
    }

    try {
      const pool = await this.api.getPool();
      this.populatePool(pool);
      if (!this.mockMode) this.setConnectionStatus('Local Nim service connected', 'connected');
      await this.loadPoolMap(0);
    } catch (error) {
      this.setConnectionStatus('Local service unavailable', 'failed');
      this.showSourceError(error instanceof Error ? error.message : String(error));
    }
  }

  bindSourceTabs() {
    const tabs = Array.from(document.querySelectorAll('[data-source-tab]'));
    const selectTab = (tab, moveFocus = false) => {
      const selected = tab.dataset.sourceTab;
      for (const candidate of tabs) {
        const active = candidate === tab;
        candidate.setAttribute('aria-selected', String(active));
        candidate.tabIndex = active ? 0 : -1;
        const panel = $(`panel-${candidate.dataset.sourceTab}`)
          || (candidate.dataset.sourceTab === 'generator' ? $('generator-form') : null);
        if (panel) panel.hidden = !active;
      }
      if (moveFocus) tab.focus();
      if (selected === 'generator' && !moveFocus) $('generator-seed').focus();
      if (selected === 'json' && !moveFocus) $('spec-json').focus();
    };

    for (const tab of tabs) {
      tab.addEventListener('click', () => selectTab(tab));
      tab.addEventListener('keydown', (event) => {
        if (!['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(event.key)) return;
        event.preventDefault();
        const currentIndex = tabs.indexOf(tab);
        let nextIndex;
        if (event.key === 'Home') nextIndex = 0;
        else if (event.key === 'End') nextIndex = tabs.length - 1;
        else if (event.key === 'ArrowRight') nextIndex = (currentIndex + 1) % tabs.length;
        else nextIndex = (currentIndex - 1 + tabs.length) % tabs.length;
        selectTab(tabs[nextIndex], true);
      });
    }
  }

  bindSourceControls() {
    $('load-pool').addEventListener('click', () => {
      this.loadPoolMap(Number.parseInt($('pool-index').value, 10));
    });

    $('generator-form').addEventListener('submit', (event) => {
      event.preventDefault();
      this.generateMap();
    });

    $('load-json').addEventListener('click', () => this.loadJsonText($('spec-json').value, 'pasted JSON'));
    $('spec-file').addEventListener('change', async (event) => {
      const [file] = event.target.files;
      if (!file) return;
      try {
        const text = await file.text();
        $('spec-json').value = text;
        this.loadJsonText(text, file.name);
      } catch (error) {
        this.showSourceError(`Could not read ${file.name}: ${error.message}`);
      }
    });

    $('render-resolution').addEventListener('change', (event) => {
      this.store.change((state) => {
        state.controls.maxDimension = Number.parseInt(event.target.value, 10);
      });
      this.coordinator.schedule({ immediate: true });
    });
  }

  bindOverlayControls() {
    for (const checkbox of document.querySelectorAll('[data-overlay]')) {
      checkbox.addEventListener('change', () => {
        this.store.change((state) => {
          if (checkbox.checked) state.controls.overlays.add(checkbox.dataset.overlay);
          else state.controls.overlays.delete(checkbox.dataset.overlay);
        });
        this.coordinator.schedule({ immediate: true });
      });
    }
  }

  bindExportControls() {
    $('copy-spec').addEventListener('click', async () => {
      const spec = this.store.state.document.spec;
      if (!spec || !this.mayExportSpec()) return;
      const text = JSON.stringify(spec, null, 2);
      try {
        await navigator.clipboard.writeText(text);
        $('copy-spec').textContent = 'Copied';
        window.setTimeout(() => { $('copy-spec').textContent = 'Copy JSON'; }, 1200);
      } catch (error) {
        this.showSourceError(`Could not copy JSON: ${error.message}`);
      }
    });

    $('download-spec').addEventListener('click', () => {
      const spec = this.store.state.document.spec;
      if (!spec || !this.mayExportSpec()) return;
      const url = URL.createObjectURL(new Blob(
        [`${JSON.stringify(spec, null, 2)}\n`],
        { type: 'application/json' },
      ));
      const link = document.createElement('a');
      link.href = url;
      link.download = fileSafeName(spec.name);
      document.body.append(link);
      link.click();
      link.remove();
      URL.revokeObjectURL(url);
    });
  }

  mayExportSpec() {
    const state = this.store.state;
    const render = state.render;
    const currentDocumentIsRendered = render.lastGoodResponse
      && render.renderedDocumentRevision === state.document.revision
      && !render.error;
    if (!currentDocumentIsRendered) {
      return window.confirm(
        'The current spec was not accepted by the Nim service. Export it verbatim anyway?',
      );
    }

    const validation = render.lastGoodResponse.validation;
    if (validation && !validation.valid) {
      const reason = validation.reason || 'The map does not pass play validation.';
      return window.confirm(`${reason}\n\nExport this play-invalid spec anyway?`);
    }
    return true;
  }

  populatePool(payload) {
    if (!payload || !Array.isArray(payload.seeds)) {
      throw new Error('The pool endpoint returned no seed list.');
    }
    const select = $('pool-index');
    select.replaceChildren();
    payload.seeds.forEach((seed, index) => {
      const option = document.createElement('option');
      option.value = String(index);
      option.textContent = `#${String(index).padStart(2, '0')} · seed ${seed}`;
      select.append(option);
    });
    select.disabled = payload.seeds.length === 0;
    $('load-pool').disabled = payload.seeds.length === 0;
  }

  async loadPoolMap(index) {
    this.clearSourceError();
    this.setSourceBusy(true);
    try {
      const response = await this.api.getPoolMap(index);
      if (!response || response.ok !== true) {
        throw new Error(response && response.error ? response.error : 'Pool map request failed.');
      }
      this.acceptSpec(response.spec, `pool #${String(index).padStart(2, '0')}`);
      $('pool-index').value = String(index);
    } catch (error) {
      this.showSourceError(error instanceof Error ? error.message : String(error));
    } finally {
      this.setSourceBusy(false);
    }
  }

  async generateMap() {
    this.clearSourceError();
    const form = $('generator-form');
    if (!form.reportValidity()) return;

    let request;
    try {
      request = {
        seed: readRequiredInteger('generator-seed'),
        teams: readRequiredInteger('generator-teams'),
        validated: $('generator-validated').checked,
        overrides: readGeneratorOverrides(),
      };
    } catch (error) {
      this.showSourceError(error.message);
      return;
    }

    this.setSourceBusy(true);
    try {
      const response = await this.api.generate(request);
      if (!response || response.ok !== true) {
        throw new Error(response && response.error ? response.error : 'Generator request failed.');
      }
      this.acceptSpec(response.spec, `generator seed ${request.seed}`);
    } catch (error) {
      this.showSourceError(error instanceof Error ? error.message : String(error));
    } finally {
      this.setSourceBusy(false);
    }
  }

  loadJsonText(text, source) {
    this.clearSourceError();
    let spec;
    try {
      spec = JSON.parse(text);
    } catch (error) {
      this.showSourceError(`Could not parse map spec JSON: ${error.message}`);
      return;
    }
    if (!spec || typeof spec !== 'object' || Array.isArray(spec)) {
      this.showSourceError('The pasted JSON must be one mapSpec object.');
      return;
    }
    this.acceptSpec(spec, source);
  }

  acceptSpec(spec, source) {
    this.clearSourceError();
    this.store.setDocument(spec, source);
    this.coordinator.schedule({ immediate: true });
  }

  setConnectionStatus(text, className) {
    const status = $('connection-status');
    status.textContent = text;
    status.className = `connection-status ${className || ''}`.trim();
  }

  setSourceBusy(busy) {
    $('load-pool').disabled = busy || $('pool-index').disabled;
    $('generator-form').querySelector('[type="submit"]').disabled = busy;
    $('load-json').disabled = busy;
    $('spec-file').disabled = busy;
  }

  showSourceError(message) {
    const error = $('source-error');
    error.textContent = message;
    error.hidden = false;
  }

  clearSourceError() {
    const error = $('source-error');
    error.textContent = '';
    error.hidden = true;
  }
}

function readRequiredInteger(id) {
  const field = $(id);
  const value = Number(field.value);
  if (!Number.isInteger(value)) {
    throw new Error(`${field.labels[0].textContent} must be an integer.`);
  }
  return value;
}

function readGeneratorOverrides() {
  const overrides = {};
  const stringFields = ['size', 'symmetry', 'centerFeature', 'layout', 'endzone'];
  const numberFields = ['columns', 'windows', 'pits', 'pitDensity', 'endzoneRadius', 'baseDepth'];

  for (const name of stringFields) {
    const value = document.querySelector(`[name="${name}"]`).value;
    if (value !== '') overrides[name] = value;
  }
  for (const name of numberFields) {
    const field = document.querySelector(`[name="${name}"]`);
    if (field.value === '') continue;
    const value = Number(field.value);
    if (!Number.isInteger(value)) {
      throw new Error(`${field.labels[0].textContent} must be an integer.`);
    }
    overrides[name] = value;
  }
  return overrides;
}

const application = new Application();
application.start();
