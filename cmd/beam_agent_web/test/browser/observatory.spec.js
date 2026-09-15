const { test, expect } = require("@playwright/test");
const token = "local-browser-fixture-token-only";

async function login(page) {
  await page.goto("/");
  await page.getByLabel("Runtime access token").fill(token);
  await page.getByRole("button", { name: /Open workspace/ }).click();
  await expect(page.getByRole("heading", { name: "Your work, together." })).toBeVisible();
  await page.locator(".session-open").first().click();
  await expect(page.getByRole("heading", { name: "Make good things." })).toBeVisible();
}

test("the observatory is reachable from the session page and renders without CSP violations", async ({
  page,
}) => {
  const violations = [];
  page.on("console", (msg) => {
    if (msg.type() === "error" && msg.text().includes("Content Security Policy")) {
      violations.push(msg.text());
    }
  });

  await login(page);
  await page.getByRole("link", { name: "Repository Observatory" }).click();
  await expect(page.getByRole("heading", { name: /Your code has/ })).toBeVisible();
  await expect(page.locator("#obs-graph svg")).toBeVisible();
  await page.waitForTimeout(500);

  await page.getByRole("link", { name: "← Back to session" }).click();
  await expect(page.getByRole("heading", { name: "Make good things." })).toBeVisible();

  expect(violations).toEqual([]);
});

test("every observatory tab renders its panel and the exploded view is interactive", async ({
  page,
}) => {
  await login(page);
  await page.getByRole("link", { name: "Repository Observatory" }).click();

  await page.locator('.observatory-tab[data-tab="exploded"]').click();
  await expect(page.locator("#obs-exploded .observatory-ring").first()).toBeVisible();
  const before = await page
    .locator(".observatory-exploded-rig")
    .evaluate((el) => el.style.transform);
  await page.mouse.move(700, 700);
  await page.mouse.down();
  await page.mouse.move(760, 660);
  await page.mouse.up();
  const after = await page
    .locator(".observatory-exploded-rig")
    .evaluate((el) => el.style.transform);
  expect(after).not.toBe(before);

  await page.locator('.observatory-tab[data-tab="risk"]').click();
  await expect(page.locator('[data-tab-panel="risk"]')).toBeVisible();

  await page.locator('.observatory-tab[data-tab="libraries"]').click();
  await expect(page.locator('[data-tab-panel="libraries"]')).toBeVisible();

  await page.screenshot({ path: "test-results/observatory-libraries.png", fullPage: true });
});

test("selecting a node updates the Signal Inspector without a page reload", async ({ page }) => {
  await login(page);
  await page.getByRole("link", { name: "Repository Observatory" }).click();
  await expect(page.locator("#obs-graph svg")).toBeVisible();

  const firstHotspot = page.locator(".observatory-hotspot").first();
  const path = await firstHotspot.getAttribute("data-select-path");
  await firstHotspot.click();

  await expect(page.locator("#obs-inspector .path")).toHaveText(path);
  await expect(page.locator("#obs-inspector")).toContainText("Coverage is unknown");
});
