/* Screenshot harness for THE PIT design polish (dev tool, not shipped).
   Captures every route at every width, reports horizontal overflow + console errors. */
const { chromium } = require(
  "C:/Users/skadd/AppData/Local/Temp/claude/C--Users-skadd/e9e3dca6-f95e-4dcc-8929-d0b3d3f30c0c/scratchpad/node_modules/playwright",
);
const fs = require("fs");
const path = require("path");

const BASE = process.env.BASE || "http://localhost:3177";
const MARKET = "0x08b35b68abcdef0123abcdef0123abcdef0123ab";
const ROUTES = [
  ["home", "/"],
  ["about", "/about"],
  ["market", `/market/${MARKET}`],
  ["vault", "/vault"],
  ["portfolio", "/portfolio"],
  ["pitboss", "/pit-boss"],
  ["jackpot", "/jackpot"],
  ["token", "/token"],
  ["fairness", "/fairness"],
  ["blocked", "/blocked"],
];
const WIDTHS = process.env.WIDTHS
  ? process.env.WIDTHS.split(",").map(Number)
  : [360, 390, 414, 768, 1024, 1280, 1440, 1920, 2560];
const OUT =
  process.env.OUT ||
  "C:/Users/skadd/AppData/Local/Temp/claude/C--Users-skadd/e9e3dca6-f95e-4dcc-8929-d0b3d3f30c0c/scratchpad/shots";
const ONLY = process.env.ONLY ? process.env.ONLY.split(",") : null;

(async () => {
  fs.mkdirSync(OUT, { recursive: true });
  const browser = await chromium.launch();
  const report = [];
  for (const width of WIDTHS) {
    const height = width < 500 ? 844 : width < 900 ? 1024 : 900;
    const ctx = await browser.newContext({
      viewport: { width, height },
      deviceScaleFactor: 1,
      hasTouch: width < 900,
      reducedMotion: "reduce",
    });
    const page = await ctx.newPage();
    const errors = [];
    page.on("console", (m) => {
      if (m.type() === "error") errors.push(m.text().slice(0, 300));
    });
    page.on("pageerror", (e) => errors.push("PAGEERROR: " + String(e).slice(0, 300)));
    for (const [name, route] of ROUTES) {
      if (ONLY && !ONLY.includes(name)) continue;
      errors.length = 0;
      try {
        await page.goto(BASE + route, { waitUntil: "networkidle", timeout: 45000 });
      } catch (e) {
        report.push({ name, width, error: "NAV FAIL " + String(e).slice(0, 120) });
        continue;
      }
      await page.waitForTimeout(1200);
      // Walk the page so IntersectionObserver reveals fire before the
      // full-page capture (otherwise below-fold sections shoot at opacity 0).
      await page.evaluate(async () => {
        // behavior: "instant" matters: html has scroll-behavior smooth, and
        // rapid smooth scrollTo calls cancel each other before reaching depth.
        const step = window.innerHeight * 0.8;
        const max = document.documentElement.scrollHeight;
        for (let y = 0; y <= max; y += step) {
          window.scrollTo({ top: y, behavior: "instant" });
          await new Promise((r) => setTimeout(r, 110));
        }
        window.scrollTo({ top: 0, behavior: "instant" });
      });
      await page.waitForTimeout(700);
      const overflow = await page.evaluate(() => {
        const doc = document.documentElement;
        const over = doc.scrollWidth - doc.clientWidth;
        let culprits = [];
        if (over > 0) {
          const vw = doc.clientWidth;
          document.querySelectorAll("body *").forEach((el) => {
            const r = el.getBoundingClientRect();
            if (r.right > vw + 1 || r.left < -1) {
              const cls = (el.className && String(el.className).slice(0, 80)) || "";
              culprits.push(
                `${el.tagName.toLowerCase()}.${cls} [${Math.round(r.left)},${Math.round(r.right)}]`,
              );
            }
          });
          culprits = culprits.slice(0, 6);
        }
        return { over, culprits };
      });
      const file = path.join(OUT, `${name}-${width}.png`);
      // Hide the Next dev-tools badge in captures.
      await page.addStyleTag({ content: "nextjs-portal{display:none !important}" });
      // fullPage stitching glitches background-clip:text gradients (the gold
      // odometers ghost mid-roll). Grow the viewport to the document instead
      // and capture in one pass, then restore.
      const docH = await page.evaluate(() => document.documentElement.scrollHeight);
      await page.setViewportSize({ width, height: Math.min(docH, 10000) });
      await page.waitForTimeout(350);
      await page.screenshot({ path: file, fullPage: false });
      await page.setViewportSize({ width, height });
      report.push({
        name,
        width,
        overflowPx: overflow.over,
        culprits: overflow.culprits,
        consoleErrors: [...new Set(errors)].slice(0, 4),
      });
    }
    await ctx.close();
  }
  await browser.close();
  for (const r of report) {
    const bad = r.error || r.overflowPx > 0 || (r.consoleErrors && r.consoleErrors.length);
    console.log(
      `${bad ? "XX" : "ok"} ${r.name}@${r.width}` +
        (r.error ? ` ${r.error}` : ` overflow=${r.overflowPx}px`) +
        (r.culprits && r.culprits.length ? ` | ${r.culprits.join(" ; ")}` : "") +
        (r.consoleErrors && r.consoleErrors.length
          ? ` | console: ${r.consoleErrors.join(" || ")}`
          : ""),
    );
  }
})();
