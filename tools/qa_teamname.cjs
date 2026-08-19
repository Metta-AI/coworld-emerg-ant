// Verify the scorebug team-name uses the FULL plate width before ellipsizing
// (the old `max-width: calc(150*var(--u))` cap clipped it far too early), and
// that the center clock stays centered even with a long name in each plate.
//
// Loads the REAL client/replay_broadcast.html over file:// (font is inlined) and
// drives the app's own relayout() with a WIDE viewport (aspect < board 1235:659)
// so the board fits by WIDTH — reproducing the Featured-Match geometry where the
// stage is wide and --hudscale clamps to 1.6, exactly as in the screenshot.
const path = require('path');
const fs = require('fs');
const QA = path.join(process.cwd(), 'tools/.qa');
process.env.PLAYWRIGHT_BROWSERS_PATH =
  process.env.PLAYWRIGHT_BROWSERS_PATH || (QA + '/ms-playwright');
const { chromium } = require(QA + '/node_modules/playwright');

const FILE = 'file://' + path.join(process.cwd(), 'client/replay_broadcast.html');
const OUT = path.join(QA, 'teamname');
fs.mkdirSync(OUT, { recursive: true });

const NAMES = {
  real: 'RICHARD HIGGINS',                 // the name from the bug screenshot
  long: 'BARTHOLOMEW WINTERBOTTOM III',     // pathological — must still clip gracefully
};

// Featured-Match-ish widths. Height chosen so viewport aspect < 1.874 → board
// fits by width (wide stage), matching the live panel.
const CASES = [
  { label: 'featured', w: 1640, h: 940 },
  { label: 'laptop',   w: 1280, h: 820 },
  { label: 'narrow',   w: 900,  h: 620 },
];

async function apply(page, name, oldCap) {
  await page.evaluate(({ name, oldCap }) => {
    for (const id of ['name-red', 'name-blue']) document.getElementById(id).textContent = name;
    document.getElementById('lives-red').textContent = '32';
    document.getElementById('lives-blue').textContent = '32';
    document.getElementById('clock-time').textContent = '6:44';
    document.querySelectorAll('.team-name').forEach((el) => {
      // Reproduce the OLD hard cap to contrast against the fixed (no-cap) build.
      el.style.maxWidth = oldCap ? 'calc(150 * var(--u))' : '';
    });
    // Re-run the app's own layout so bands re-measure with the populated names.
    window.dispatchEvent(new Event('resize'));
  }, { name, oldCap });
  await page.waitForTimeout(60);
}

async function measure(page) {
  return await page.evaluate(() => {
    const nr = document.getElementById('name-red');
    const clk = document.getElementById('clock');
    const sb = document.getElementById('scorebug');
    const sbr = sb.getBoundingClientRect();
    const clkr = clk.getBoundingClientRect();
    return {
      redClipped: nr.scrollWidth > nr.clientWidth + 1,
      redText: nr.textContent,
      redRenderW: Math.round(nr.getBoundingClientRect().width),
      redScrollW: nr.scrollWidth,
      clockOffCenterPx: Math.round((clkr.left + clkr.right) / 2 - (sbr.left + sbr.right) / 2),
      hudscale: getComputedStyle(document.documentElement).getPropertyValue('--hudscale').trim(),
    };
  });
}

(async () => {
  const browser = await chromium.launch();
  const results = [];
  for (const c of CASES) {
    const page = await browser.newPage({ viewport: { width: c.w, height: c.h }, deviceScaleFactor: 2 });
    await page.goto(FILE, { waitUntil: 'load' });
    await page.evaluate(() => document.fonts.ready);
    for (const [key, name] of Object.entries(NAMES)) {
      for (const oldCap of [true, false]) {
        await apply(page, name, oldCap);
        const m = await measure(page);
        const tag = `${c.label}_${key}_${oldCap ? 'OLDcap' : 'NEWfull'}`;
        await page.locator('#scorebug').screenshot({ path: path.join(OUT, tag + '.png') });
        results.push({ tag, ...m });
      }
    }
    await page.close();
  }
  await browser.close();
  console.log(JSON.stringify(results, null, 2));
})().catch((e) => { console.error(e); process.exit(1); });
