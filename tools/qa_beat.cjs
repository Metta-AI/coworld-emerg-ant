// Focused beat-surface capture: seek to just BEFORE a known beat tick, pause,
// then step forward so the kill-feed row + banner chip are on-screen, and shoot.
// Proves the ranked beat surfaces actually paint (not just have a code hook).
const path = require('path');
const QA = process.env.QA_DIR || path.join(process.cwd(), 'tools/.qa');
process.env.PLAYWRIGHT_BROWSERS_PATH = process.env.PLAYWRIGHT_BROWSERS_PATH || (QA + '/ms-playwright');
const { chromium } = require(QA + '/node_modules/playwright');
const BASE = process.env.PROXY_BASE || 'http://127.0.0.1:8890';
const VIEWER = process.env.VIEWER_PATH || 'client/replay';
const SEEK = parseInt(process.env.SEEK_TICK || '1600', 10); // just before red steal @1646
const CDN = ['cdn.jsdelivr.net', 'unpkg.com', 'esm.sh'];

(async () => {
  const browser = await chromium.launch({
    headless: true,
    args: ['--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader',
           '--ignore-gpu-blocklist', '--no-sandbox'],
  });
  const VW = parseInt(process.env.VW || '1330', 10);
  const VH = parseInt(process.env.VH || '700', 10);
  const page = await browser.newPage({ viewport: { width: VW, height: VH } });
  for (const h of CDN) await page.route(`**${h}**`, r => r.abort());
  const errs = [];
  page.on('pageerror', e => errs.push(e.message.slice(0, 140)));
  await page.goto(`${BASE}/embed?path=${VIEWER}`, { waitUntil: 'domcontentloaded', timeout: 30000 });
  await page.waitForTimeout(6000);
  const fr = page.frames().find(f => f.url().includes('/proxy/'));

  // Seek to just before the beat via the REAL scrubber click UI (frac→tick, s:),
  // then let playback run through the beat at 1x so the feed row + banner appear
  // and dwell (the dwell floor keeps them on-screen). Exercises the genuine path.
  await fr.evaluate((tick) => {
    const scrub = document.getElementById('scrub');
    const mx = (window.__lastMx) || (document.getElementById('tick-clock') || {}).textContent;
    // read max from the "cur / max" clock; fall back to the fixture max 2465
    let max = 2465;
    const m = /\/\s*(\d+)/.exec((document.getElementById('tick-clock') || {}).textContent || '');
    if (m) max = parseInt(m[1], 10);
    const rect = scrub.getBoundingClientRect();
    const frac = Math.min(1, Math.max(0, tick / max));
    const x = rect.left + frac * rect.width;
    const y = rect.top + rect.height / 2;
    scrub.dispatchEvent(new MouseEvent('click', { bubbles: true, clientX: x, clientY: y }));
  }, SEEK);
  // A scrub PAUSES playback (applyReplaySeek sets playing=false), so press play
  // to run forward through the beat and let its surfaces dwell on-screen.
  await page.waitForTimeout(600);
  await fr.evaluate(() => { document.getElementById('btn-play').click(); });
  await page.waitForTimeout(parseInt(process.env.DWELL_MS || '1400', 10)); // land mid-dwell

  const probe = await fr.evaluate(() => {
    const feed = document.getElementById('killfeed');
    const banners = document.getElementById('bannerlane');
    const tick = document.getElementById('tick-clock');
    return {
      tick: tick && tick.textContent,
      feedRows: feed ? feed.children.length : -1,
      feedText: feed ? (feed.textContent || '').replace(/\s+/g, ' ').trim().slice(0, 120) : '',
      bannerText: banners ? (banners.textContent || '').replace(/\s+/g, ' ').trim().slice(0, 80) : '',
    };
  });
  const out = process.env.OUT || '/tmp/qa_ctf_beat.png';
  await page.screenshot({ path: out });
  console.log('probe:', JSON.stringify(probe));
  console.log('errs :', errs.length ? errs.slice(0, 5).join(' | ') : '(none)');
  console.log('shot :', out);
  await browser.close();
})();
