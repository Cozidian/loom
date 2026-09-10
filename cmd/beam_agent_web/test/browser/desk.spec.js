const { test, expect } = require("@playwright/test");
const token = "local-browser-fixture-token-only";
async function login(page) {
  await page.goto("/");
  await page.getByLabel("Runtime access token").fill(token);
  await page.getByRole("button", { name: /Open workspace/ }).click();
  await expect(page.getByRole("heading", {name: "Your work, together."})).toBeVisible();
  await expect(page.locator(".session-card")).toHaveCount(2);
  await page.locator(".session-open").first().click();
  await expect(
    page.getByRole("heading", { name: "Make good things." }),
  ).toBeVisible();
  await expect(page.locator("#connection")).toContainText("Live");
}
test("one-click CLI launch authenticates and removes the one-time fragment", async ({ page, browser }) => {
  const ticket = "disposable-browser-launch-ticket-0123456789";
  await page.goto("/#launch=" + ticket);
  await expect(page.getByRole("heading", { name: "Your work, together." })).toBeVisible();
  expect(page.url()).not.toContain(ticket);
  expect(await page.content()).not.toContain(token);
  expect(await page.content()).not.toContain(ticket);
  const isolated = await browser.newContext();
  const second = await isolated.newPage();
  await second.goto(page.url() + "#launch=" + ticket);
  await expect(second.getByRole("alert")).toContainText("already used");
  await isolated.close();
});
test("overview discovers both sessions and two tabs keep commands and drafts scoped", async ({page, context}) => {
  await login(page);
  await page.goto("/");
  await expect(page.locator(".session-card")).toHaveCount(2);
  await page.screenshot({path:"test-results/desk-overview.png",fullPage:true});
  const paths = await page.locator(".session-open").evaluateAll(links => links.map(link => link.getAttribute("href")));
  const second = await context.newPage();
  await page.goto(paths[0]);
  await second.goto(paths[1]);
  await page.getByLabel("What should we work on?").fill("session A isolated answer");
  await page.getByRole("button",{name:/Set things in motion/}).click();
  await second.getByLabel("What should we work on?").fill("session B isolated answer");
  await second.getByRole("button",{name:/Set things in motion/}).click();
  await expect(page.locator("#conversation .assistant").last()).toContainText("session A isolated answer");
  await expect(second.locator("#conversation .assistant").last()).toContainText("session B isolated answer");
  await expect(page.locator("#conversation")).not.toContainText("session B isolated answer");
  await expect(second.locator("#conversation")).not.toContainText("session A isolated answer");
  await page.getByLabel("What should we work on?").fill("private draft A");
  await page.goto(paths[1]);
  await expect(page.getByLabel("What should we work on?")).not.toHaveValue("private draft A");
  await page.goto(paths[0]);
  await expect(page.getByLabel("What should we work on?")).toHaveValue("private draft A");
  await second.close();
});
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
  await expect(page.locator("#conversation .assistant").last()).toContainText("Observe this browser delivery trial");
  await expect(page.locator(".work-state")).toContainText("Work completed");
  await page.reload();
  await expect(page.locator("#conversation .assistant").last()).toContainText("Observe this browser delivery trial");
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

test("overview explicitly creates a new session and its output can be read", async ({page}) => {
  await login(page);
  await page.goto("/");
  await page.getByRole("button", {name:"Start a new session"}).click();
  await expect(page).toHaveURL(/\/sessions\/session-/);
  await page.getByLabel("What should we work on?").fill("New Desk-owned session works");
  await page.getByRole("button",{name:/Set things in motion/}).click();
  await expect(page.locator("#conversation .assistant").last()).toContainText("New Desk-owned session works");
  await page.goto("/");
  await expect(page.locator(".session-card")).toHaveCount(3);
});
