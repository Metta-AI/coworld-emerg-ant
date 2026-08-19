// Multi-aspect QA render of the CTF broadcast replay THROUGH the proxy harness,
// CDN blocked. Screenshots the /embed iframe at the four container targets from
// REPLAY_DESIGN §2: wide ~1.9, featured ~1.5, the 640x360 floor, and portrait
// ~390x780. Writes /tmp/qa_ctf_<label>.png per size and logs 4xx + errors.
const path = require('path');
const QA = process.env.QA_DIR || path.join(process.cwd(), 'tools/.qa');
process.env.PLAYWRIGHT_BROWSERS_PATH = process.env.PLAYWRIGHT_BROWSERS_PATH || (QA + '/ms-playwright');
const { chromium } = require(QA + '/node_modules/playwright');
const BASE = process.env.PROXY_BASE || 'http://127.0.0.1:8890';
const VIEWER = process.env.VIEWER_PATH || 'client/replay';
const CDN_HOSTS = (process.env.CDN_HOSTS || 'cdn.jsdelivr.net,unpkg.com,esm.sh').split(',');
const WAIT = parseInt(process.env.WAIT_MS || '9000', 10);

// The proxy /embed frame is a full-viewport iframe, so the browser viewport IS
// the container box. These are the four §2 targets (plus the exact size ratio).
const SIZES = [
  { label: 'wide_1p9',      w: 1330, h: 700 },   // ~1.90 — standalone / wide column
  { label: 'featured_1p5',  w: 1040, h: 694 },   // ~1.50 — League Featured Match aspect-video-ish
  { label: 'floor_640x360', w: 640,  h: 360 },   // the hard floor
  { label: 'portrait_390',  w: 390,  h: 780 },   // phone / narrow middle column → portrait reflow
];

async function shoot(browser, size) {
  const page = await browser.newPage({ viewport: { width: size.w, height: size.h } });
  for (const h of CDN_HOSTS) await page.route(`**${h}**`, r => r.abort());
  const fourxx = [], errs = [];
  page.on('response', r => { if (r.status() >= 400) fourxx.push(r.status() + ' ' + r.url().replace(BASE, '')); });
  page.on('pageerror', e => errs.push(e.message.slice(0, 140)));
  page.on('console', m => { if (m.type() === 'error') errs.push(m.text().slice(0, 140)); });
  await page.goto(`${BASE}/embed?path=${VIEWER}`, { waitUntil: 'domcontentloaded', timeout: 30000 });
  await page.waitForTimeout(WAIT);

  // Probe the viewer frame: did a JSON state frame arrive + did the board size?
  const fr = page.frames().find(f => f.url().includes('/proxy/'));
  let probe = null;
  if (fr) {
    try {
      probe = await fr.evaluate(() => {
        const g = document.getElementById('scorebug');
        const lr = document.getElementById('lives-red');
        const lb = document.getElementById('lives-blue');
        const clk = document.getElementById('clock-time');
        const tick = document.getElementById('tick-clock');
        const bd = document.getElementById('board');
        const feed = document.getElementById('killfeed');
        const st = document.getElementById('stage');
        return {
          livesRed: lr && lr.textContent,
          livesBlue: lb && lb.textContent,
          clock: clk && clk.textContent,
          tick: tick && tick.textContent,
          boardW: bd && bd.width, boardH: bd && bd.height,
          feedRows: feed ? feed.children.length : -1,
          portrait: st && st.classList.contains('portrait'),
          tiny: st && st.classList.contains('tiny'),
          status: (document.getElementById('status') || {}).textContent,
        };
      });
    } catch (e) { probe = { err: String(e).slice(0, 100) }; }
  }

  const out = `/tmp/qa_ctf_${size.label}.png`;
  await page.screenshot({ path: out });
  console.log(`\n=== ${size.label}  ${size.w}x${size.h} (ratio ${(size.w / size.h).toFixed(2)}) → ${out} ===`);
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
  for (const s of SIZES) await shoot(browser, s);
  await browser.close();
})();
