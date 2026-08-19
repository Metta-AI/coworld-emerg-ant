// Captures the endzone glow at three ticks to prove the heart-taken power-down:
// 1100 (both hearts home → both endzones lit), 1400 (Red heart carried → Red
// endzone faded), 2300 (both hearts carried → both endzones dark).
const path = require('path');
const QA = process.env.QA_DIR || path.join(process.cwd(), 'tools/.qa');
process.env.PLAYWRIGHT_BROWSERS_PATH = process.env.PLAYWRIGHT_BROWSERS_PATH || (QA + '/ms-playwright');
const { chromium } = require(QA + '/node_modules/playwright');
const BASE = process.env.PROXY_BASE || 'http://127.0.0.1:8890';
const VIEWER = 'client/replay';
const TICKS = (process.env.TICKS || '1100,1400,2300').split(',').map(s => parseInt(s, 10));
const CDN = ['cdn.jsdelivr.net', 'unpkg.com', 'esm.sh'];

(async () => {
  const browser = await chromium.launch({
    headless: true,
    args: ['--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader',
           '--ignore-gpu-blocklist', '--no-sandbox'],
  });
  const page = await browser.newPage({ viewport: { width: 1330, height: 700 } });
  for (const h of CDN) await page.route(`**${h}**`, r => r.abort());
  const errs = [];
  page.on('pageerror', e => errs.push(e.message.slice(0, 160)));
  await page.goto(`${BASE}/embed?path=${VIEWER}`, { waitUntil: 'domcontentloaded', timeout: 30000 });
  await page.waitForTimeout(6000);
  const fr = page.frames().find(f => f.url().includes('/proxy/'));
  if (!fr) { console.log('NO FRAME'); await browser.close(); return; }

  for (const tick of TICKS) {
    // Seek via the REAL scrubber-click UI (x-fraction → tick → s:<tick>), then
    // let the fade settle (>= GlowFadeStages frames). Pause so the tick holds.
    await fr.evaluate((t) => {
      const scrub = document.getElementById('scrub');
      let max = 2500, st = 0;
      const m = /(\d+)\s*\/\s*(\d+)/.exec((document.getElementById('tick-clock') || {}).textContent || '');
      if (m) max = parseInt(m[2], 10);
      const rect = scrub.getBoundingClientRect();
      const frac = Math.min(1, Math.max(0, (t - st) / (max - st)));
      const x = rect.left + frac * rect.width;
      const y = rect.top + rect.height / 2;
      scrub.dispatchEvent(new MouseEvent('click', { bubbles: true, clientX: x, clientY: y }));
    }, tick);
    await page.waitForTimeout(1600);
    const out = `/tmp/glow_${tick}.png`;
    await page.screenshot({ path: out });
    const info = await fr.evaluate(() => {
      const c = document.getElementById('tick-clock');
      return c ? c.textContent.replace(/\s+/g, ' ').trim() : '(no clock)';
    });
    console.log(`tick ${tick}: clock="${info}" shot=${out}`);
  }
  console.log('errs:', errs.length ? errs.slice(0, 4).join(' | ') : '(none)');
  await browser.close();
})();
