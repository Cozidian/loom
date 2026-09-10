const { test, expect } = require("@playwright/test");
const token = "local-browser-fixture-token-only";
async function login(page) {
  await page.goto("/");
  await page.getByLabel("Runtime access token").fill(token);
  await page.getByRole("button", { name: /Open workspace/ }).click();
  await expect(
    page.getByRole("heading", { name: "Make good things." }),
  ).toBeVisible();
  await expect(page.locator("#connection")).toContainText("Live");
}
test("real API submission, polling, agent detail and desktop layout", async ({
  page,
}) => {
  await page.setViewportSize({ width: 1440, height: 1050 });
  await login(page);
  await page.locator("details.agent summary").first().click();
  await expect(page.locator("details.agent").first()).toHaveAttribute(
    "open",
    "",
  );
  await page.locator(".activity details summary").first().click();
  const previousSync = await page.locator("#connection").textContent();
  await expect(page.locator("#connection")).not.toHaveText(previousSync);
  await expect(page.locator("details.agent").first()).toHaveAttribute("open", "");
  await expect(page.locator(".activity details").first()).toHaveAttribute("open", "");
  await page
    .getByLabel("What should we work on?")
    .fill("Observe this browser delivery trial");
  await page.getByRole("button", { name: /Set things in motion/ }).click();
  await expect(page.locator("#notice")).toContainText("Prompt accepted");
  await expect(page.getByLabel("What should we work on?")).toHaveValue("");
  await expect(page.locator(".activity li").first()).toContainText(
    "goal work finished",
  );
  expect(await page.content()).not.toContain(token);
  await page.screenshot({
    path: "test-results/desk-desktop.png",
    fullPage: true,
  });
});
test("narrow layout, draft persistence, cancellation and logout", async ({
  page,
}) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await login(page);
  const editor = page.getByLabel("What should we work on?");
  await editor.fill("A draft that must survive refresh");
  await page.reload();
  await expect(editor).toHaveValue("A draft that must survive refresh");
  expect(
    await page.evaluate(
      () => document.documentElement.scrollWidth <= window.innerWidth,
    ),
  ).toBe(true);
  await page.screenshot({
    path: "test-results/desk-mobile.png",
    fullPage: true,
  });
  await page.getByRole("button", { name: "Stop current work" }).click();
  await expect(editor).toHaveValue("A draft that must survive refresh");
  await page.getByRole("button", { name: "Disconnect this browser" }).click();
  await expect(page.getByLabel("Runtime access token")).toBeVisible();
});
test("browser writes require CSRF even with an authenticated cookie", async ({
  page,
}) => {
  await login(page);
  const rejected = await page.request.post("/commands/cancel", { form: {} });
  expect(rejected.status()).toBe(403);
});
