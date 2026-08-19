// Mock-Observatory embed QA: renders the replay iframe INSIDE a realistic
// product page (tools/mock_observatory.html) at several Observatory window
// sizes, so we can see the fixed-aspect composition sit correctly in the REAL
// containers (Featured Match aspect-video + Episode column) with warm letterbox
// context around it — not a bare full-viewport iframe. Also does a direct
// container-shape sweep to prove the board + overlays scale as ONE unit and
// stay pinned (no drift) at every aspect. CDN blocked; logs 4xx + JS errors.
const path = require('path');
const fs = require('fs');
const QA = process.env.QA_DIR || path.join(process.cwd(), 'tools/.qa');
process.env.PLAYWRIGHT_BROWSERS_PATH = process.env.PLAYWRIGHT_BROWSERS_PATH || (QA + '/ms-playwright');
const { chromium } = require(QA + '/node_modules/playwright');
const BASE = process.env.PROXY_BASE || 'http://127.0.0.1:8890';
const VIEWER = process.env.VIEWER_PATH || 'client/replay';
const EMBED_URL = `${BASE}/embed?path=${VIEWER}`;
const CDN_HOSTS = (process.env.CDN_HOSTS || 'cdn.jsdelivr.net,unpkg.com,esm.sh').split(',');
const WAIT = parseInt(process.env.WAIT_MS || '9000', 10);
const MOCK_HTML = fs.readFileSync(path.join(process.cwd(), 'tools/mock_observatory.html'), 'utf8');

// Observatory browser-window sizes (the page reflows its own grid; the embeds
// are the interesting part — the replay must fit each container as one unit).
const PAGE_SIZES = [
  { label: 'obs_desktop', w: 1440, h: 900 },
  { label: 'obs_laptop',  w: 1180, h: 820 },
  { label: 'obs_narrow',  w: 760,  h: 1100 }, // single-column stack (aside wraps under)
];

// Direct container-shape sweep (iframe fills the browser box): proves the
// composition centers + scales at extreme aspects without overlap/drift.
const SHAPES = [
  { label: 'shape_wide_2p4',  w: 1400, h: 580 },  // wider than board → pillarbox sides
  { label: 'shape_video_1p78',w: 1024, h: 576 },  // exact 16:9 aspect-video
  { label: 'shape_square',    w: 700,  h: 700 },  // square → letterbox top/bottom
  { label: 'shape_portrait',  w: 420,  h: 820 },  // tall column → big warm letterbox
  { label: 'shape_floor',     w: 640,  h: 360 },  // the hard floor
];

function attach(page) {
  const fourxx = [], errs = [];
  page.on('response', r => { if (r.status() >= 400) fourxx.push(r.status() + ' ' + r.url().replace(BASE, '')); });
  page.on('pageerror', e => errs.push(e.message.slice(0, 140)));
  page.on('console', m => { if (m.type() === 'error') errs.push(m.text().slice(0, 140)); });
  return { fourxx, errs };
}

async function blockCdn(page) { for (const h of CDN_HOSTS) await page.route(`**${h}**`, r => r.abort()); }

// Probe one replay frame's geometry: is the board filling the stage with NO
// internal letterbox (offsets ~0), and does --hudscale track the stage width?
async function probeFrame(fr) {
  try {
    return await fr.evaluate(() => {
      const st = document.getElementById('stage');
      const bd = document.getElementById('board');
      const sb = document.getElementById('scorebug');
      const tp = document.getElementById('transport');
      const cs = getComputedStyle(document.documentElement).getPropertyValue('--hudscale').trim();
      const sr = st.getBoundingClientRect(), br = bd.getBoundingClientRect();
      const sbr = sb.getBoundingClientRect(), tpr = tp.getBoundingClientRect();
      return {
        hudscale: cs,
        stage: [Math.round(sr.width), Math.round(sr.height)],
        stageAspect: +(sr.width / sr.height).toFixed(3),
        // scorebug should span the stage top; transport the stage bottom — both
        // inside the stage box (pinned to the graphics, not the viewport).
        scorebugTopInStage: Math.round(sbr.top - sr.top),
        transportBottomGap: Math.round(sr.bottom - tpr.bottom),
        scorebugFullWidth: Math.abs(sbr.width - sr.width) < 2,
        clock: (document.getElementById('clock-time') || {}).textContent,
        tick: (document.getElementById('tick-clock') || {}).textContent,
        status: (document.getElementById('status') || {}).textContent,
      };
    });
  } catch (e) { return { err: String(e).slice(0, 120) }; }
}

async function shootPage(browser, size) {
  const page = await browser.newPage({ viewport: { width: size.w, height: size.h } });
  const { fourxx, errs } = attach(page);
  await blockCdn(page);
  // Serve the mock by setting content, then point both iframes at the proxy embed.
  await page.setContent(MOCK_HTML, { waitUntil: 'domcontentloaded' });
  await page.evaluate((url) => {
    document.getElementById('featured-frame').src = url;
    document.getElementById('episode-frame').src = url;
  }, EMBED_URL);
  await page.waitForTimeout(WAIT);
  const frames = page.frames().filter(f => f.url().includes('/proxy/'));
  const probes = [];
  for (const fr of frames) probes.push(await probeFrame(fr));
  const out = `/tmp/qa_mock_${size.label}.png`;
  await page.screenshot({ path: out, fullPage: false });
  console.log(`\n=== MOCK ${size.label}  ${size.w}x${size.h} → ${out} ===`);
  probes.forEach((p, i) => console.log(`  frame${i}:`, JSON.stringify(p)));
  console.log('  4xx  :', fourxx.length ? fourxx.slice(0, 6).join(' | ') : '(none)');
  console.log('  errs :', errs.length ? errs.slice(0, 5).join(' | ') : '(none)');
  await page.close();
}

async function shootShape(browser, size) {
  const page = await browser.newPage({ viewport: { width: size.w, height: size.h } });
  const { fourxx, errs } = attach(page);
  await blockCdn(page);
  await page.goto(EMBED_URL, { waitUntil: 'domcontentloaded', timeout: 30000 });
  await page.waitForTimeout(WAIT);
  const fr = page.frames().find(f => f.url().includes('/proxy/'));
  const probe = fr ? await probeFrame(fr) : null;
  const out = `/tmp/qa_mock_${size.label}.png`;
  await page.screenshot({ path: out });
  console.log(`\n=== SHAPE ${size.label}  ${size.w}x${size.h} (ratio ${(size.w / size.h).toFixed(2)}) → ${out} ===`);
  console.log('  probe:', JSON.stringify(probe));
  console.log('  4xx  :', fourxx.length ? fourxx.slice(0, 6).join(' | ') : '(none)');
  console.log('  errs :', errs.length ? errs.slice(0, 5).join(' | ') : '(none)');
  await page.close();
}

(async () => {
  const browser = await chromium.launch({
    headless: true,
    args: ['--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader',
           '--ignore-gpu-blocklist', '--no-sandbox'],
  });
  for (const s of PAGE_SIZES) await shootPage(browser, s);
  for (const s of SHAPES) await shootShape(browser, s);
  await browser.close();
})();
