/* Interaction smoke for the craft pass (dev tool, not shipped):
   side toggle thumb, market dropdown entrance, simulated-fill flourish. */
const { chromium } = require(
  "C:/Users/skadd/AppData/Local/Temp/claude/C--Users-skadd/e9e3dca6-f95e-4dcc-8929-d0b3d3f30c0c/scratchpad/node_modules/playwright",
);
const OUT =
  "C:/Users/skadd/AppData/Local/Temp/claude/C--Users-skadd/e9e3dca6-f95e-4dcc-8929-d0b3d3f30c0c/scratchpad/shots";
const BASE = process.env.BASE || "http://localhost:3199";

(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });
  const errors = [];
  page.on("console", (m) => m.type() === "error" && errors.push(m.text().slice(0, 200)));
  page.on("pageerror", (e) => errors.push("PAGEERROR " + String(e).slice(0, 200)));

  await page.goto(BASE + "/", { waitUntil: "networkidle" });
  await page.waitForTimeout(1500);

  // 1. Side thumb: switch to SHORT, thumb should carry the loss tint across.
  await page.getByRole("button", { name: "Short", exact: true }).click();
  await page.waitForTimeout(400);
  const thumbSide = await page.locator(".side-thumb").getAttribute("data-side");
  console.log("thumb side after SHORT click:", thumbSide);

  // 2. Market selector: open, entrance class present, pick a row.
  await page.locator("button[aria-haspopup='listbox']").click();
  await page.waitForTimeout(300);
  const ddVisible = await page.locator(".dd-pop").isVisible();
  console.log("dropdown open + dd-pop:", ddVisible);
  await page.screenshot({ path: OUT + "/x-dropdown.png" });
  const rows = page.locator(".dd-pop [role='option']");
  console.log("rows:", await rows.count());
  await rows.nth(2).click();
  await page.waitForTimeout(800);

  // 3. Fill flourish: click the CTA, expect btn-filled + label swap + receipt.
  const cta = page.locator("button.btn-amber", { hasText: /SIM/i }).first();
  await cta.click();
  await page.waitForTimeout(250);
  const filled = await page.locator("button.btn-filled").count();
  console.log("btn-filled active:", filled > 0);
  await page.screenshot({ path: OUT + "/x-filled.png" });
  // Spin ceremony may be up; dismiss if present.
  const dismiss = page.getByRole("button", { name: /Back to the table/i });
  if (await dismiss.count()) {
    await page.waitForTimeout(2600);
    await dismiss.click();
  }
  await page.waitForTimeout(1600);
  const backToNormal = await page.locator("button.btn-filled").count();
  console.log("flourish cleared:", backToNormal === 0);

  // 4. Tape present with both loop copies.
  console.log("tape groups:", await page.locator(".tape-track > span").count());

  console.log("console errors:", errors.length ? errors.join(" || ") : "none");
  await browser.close();
})();
