// Rebuild: node scripts/website/render-waitlist-og.cjs
// Requires Playwright and Chromium (available in the Codex bundled workspace runtime).
const fs = require('node:fs');
const path = require('node:path');
const { pathToFileURL } = require('node:url');
const { chromium } = require('playwright');
const root = path.resolve(__dirname, '../..');

(async () => {
  const browser = await chromium.launch({ headless: true });
  try {
    const page = await browser.newPage({ viewport: { width: 1200, height: 630 }, deviceScaleFactor: 1 });
    await page.goto(pathToFileURL(path.join(__dirname, 'waitlist-og.html')).href);
    await page.evaluate(async () => {
      await document.fonts.ready;
      await Promise.all([...document.images].map(image => image.decode()));
    });
    const output = path.join(root, 'Website/assets/og/waitlist-v5.png');
    fs.mkdirSync(path.dirname(output), { recursive: true });
    await page.screenshot({ path: output });
    console.log('Rendered 1200 × 630 waitlist card: ' + output);
  } finally {
    await browser.close();
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
