/* One-off dev tool: open the market selector on / and screenshot desktop + mobile. */
const { chromium } = require(
  "C:/Users/skadd/AppData/Local/Temp/claude/C--Users-skadd/e9e3dca6-f95e-4dcc-8929-d0b3d3f30c0c/scratchpad/node_modules/playwright",
);
const OUT =
  "C:/Users/skadd/AppData/Local/Temp/claude/C--Users-skadd/e9e3dca6-f95e-4dcc-8929-d0b3d3f30c0c/scratchpad/shots";

(async () => {
  const browser = await chromium.launch();
  for (const [name, width, height] of [
    ["selector-1440", 1440, 900],
    ["selector-390", 390, 844],
  ]) {
    const page = await browser.newPage({ viewport: { width, height } });
    await page.goto("http://localhost:3199/", { waitUntil: "networkidle" });
    await page.waitForTimeout(800);
    await page.getByRole("button", { name: /CASHCAT/ }).first().click();
    await page.waitForTimeout(500);
    await page.addStyleTag({ content: "nextjs-portal{display:none !important}" });
    await page.screenshot({ path: `${OUT}/${name}.png` });
    await page.close();
  }
  await browser.close();
  console.log("done");
})();
