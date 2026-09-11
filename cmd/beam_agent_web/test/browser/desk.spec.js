const { test, expect } = require("@playwright/test");
const token = "local-browser-fixture-token-only";
test("cold Desk startup survives refresh and a different computer root creates its own session", async ({page}) => {
  await page.goto("/");
  await page.getByLabel("Runtime access token").fill(token);
  await page.getByRole("button", {name:/Open workspace/}).click();
  await expect(page.locator(".session-card")).toHaveCount(0);
  const form = page.locator('form[action="/sessions"]');
  const requestId = await form.locator('input[name="request_id"]').inputValue();
  const csrf = await form.locator('input[name="_csrf_token"]').inputValue();
  await page.getByRole("button", {name:"Start a new session"}).click();
  await expect(page.locator(".startup-page")).toBeVisible();
  const waitingUrl = page.url();
  const repeated = await page.request.post("/sessions", {form: {request_id:requestId, _csrf_token:csrf}, maxRedirects:0});
  expect(repeated.status()).toBe(302);
  expect(new URL(repeated.headers().location, page.url()).href).toBe(waitingUrl);
  await page.reload();
  await expect(page.locator("#startup-status")).toContainText(/initializing|opening/);
  await expect(page).toHaveURL(/\/sessions\/session-/, {timeout:20000});
  const firstSession = page.url();
  await page.goto("/");
  await expect(page.locator(".session-card")).toHaveCount(1);
  await page.goto(firstSession);
  await page.getByRole("link", {name:/Observe a different repository/}).click();
  const originalRoot = await page.getByLabel("New session workspace").inputValue();
  await page.getByRole("button", {name:"Computer /", exact:true}).click();
  await expect(page.getByLabel("New session workspace")).toHaveValue("/");
  await page.getByLabel("Folder on this computer").fill(originalRoot);
  await page.getByRole("button", {name:"Open folder", exact:true}).click();
  await expect(page.getByLabel("New session workspace")).toHaveValue(originalRoot);
  await page.getByRole("button", {name:"↑ Up", exact:true}).click();
  await page.getByRole("button", {name:"▸ second-workspace", exact:true}).click();
  await expect(page.getByLabel("New session workspace")).toHaveValue(/second-workspace$/);
  await page.screenshot({path:"test-results/computer-picker-desktop.png", fullPage:true});
  await page.setViewportSize({width:390,height:844});
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth && document.documentElement.scrollHeight <= innerHeight)).toBe(true);
  await page.screenshot({path:"test-results/computer-picker-mobile.png", fullPage:true});
  await page.setViewportSize({width:1280,height:900});
  await page.getByRole("button", {name:"Use folder for an observer"}).click();
  await expect(page).toHaveURL(/\/sessions\/session-.*\/observer$/);
  await expect(page.locator(".observer-root")).toContainText("second-workspace");
  expect(page.url()).not.toBe(firstSession);
  await page.goto("/");
  await expect(page.locator(".session-card")).toHaveCount(2);
  await expect(page.locator(".session-card").filter({hasText:"second-workspace"})).toHaveCount(1);
});
test("documentation observer start, pause and resume stay session-scoped and sync across tabs", async ({page, context}) => {
  await login(page);
  const path = new URL(page.url()).pathname;
  const observer = page.locator("#documentation-mission");
  await expect(observer).toContainText("provider allowance");
  await observer.getByRole("link", {name:"Choose folders"}).click();
  await expect(page.locator(".observer-root")).toContainText("workspace");
  await page.getByRole("button", {name:"▸ docs with spaces", exact:true}).click();
  await expect(page.getByLabel("Browse path", {exact:true})).toHaveValue("docs with spaces");
  await page.getByRole("button", {name:"▸ nested", exact:true}).click();
  await expect(page.getByLabel("Browse path", {exact:true})).toHaveValue("docs with spaces/nested");
  await page.getByRole("button", {name:"Add this folder", exact:true}).click();
  await expect(page.getByLabel("Watched paths")).toHaveValue("docs with spaces/nested");
  await page.getByRole("button", {name:"↑ Up", exact:true}).click();
  await expect(page.getByLabel("Browse path", {exact:true})).toHaveValue("docs with spaces");
  await expect(page.getByLabel("Watched paths")).toHaveValue("docs with spaces/nested");
  await page.screenshot({path:"test-results/observer-folder-picker-desktop.png", fullPage:true});
  await page.setViewportSize({width:390,height:844});
  await page.screenshot({path:"test-results/observer-folder-picker-mobile.png", fullPage:true});
  expect(await page.evaluate(()=>document.documentElement.scrollWidth > innerWidth)).toBe(false);
  await page.getByRole("button", {name:"Start documentation observer", exact:true}).click();
  await expect(observer.getByRole("button", {name:"Pause observer"})).toBeVisible();
  await expect(observer).toContainText("docs with spaces/nested");
  await expect(observer.locator(".finding-card")).toHaveCount(2);
  await page.setViewportSize({width:1440,height:1000});
  await observer.locator(".observer-report").evaluate(el => el.scrollIntoView({block:"start", behavior:"instant"}));
  await page.screenshot({path:"test-results/observer-findings-desktop.png", fullPage:true});
  await page.setViewportSize({width:390,height:844});
  await observer.locator(".observer-report").evaluate(el => el.scrollIntoView({block:"start", behavior:"instant"}));
  await page.screenshot({path:"test-results/observer-findings-mobile.png", fullPage:true});
  await observer.getByRole("link", {name:"Prepare a fix ↗"}).first().click();
  await expect(page.getByRole("heading", {name:/From finding/})).toBeVisible();
  await expect(page.locator("main")).toContainText("No automatic merge");
  await page.getByRole("button", {name:"Start isolated fix agent"}).click();
  await expect(observer.locator(".followup-card")).toHaveCount(1);
  await expect(observer.locator(".followup-card")).toContainText("Retained worktree", {timeout:15000});
  await expect(observer.getByRole("button", {name:"Resume observer"})).toBeVisible();
  await observer.getByRole("button", {name:"Resume observer"}).click();
  const second = await context.newPage();
  await second.goto(path);
  await second.locator("#documentation-mission").getByRole("button", {name:"Pause observer"}).click();
  await expect(observer.getByRole("button", {name:"Resume observer"})).toBeVisible();
  await observer.getByRole("link", {name:"Choose folders"}).click();
  await expect(page.getByLabel("Watched paths")).toHaveValue("docs with spaces/nested");
  await page.getByLabel("Watched paths").fill("README.md");
  await page.getByRole("button", {name:"Save watched paths"}).click();
  await expect(observer.getByRole("button", {name:"Resume observer"})).toBeVisible();
  await expect(observer).toContainText("README.md");
  await expect(second.locator("#documentation-mission")).toContainText("README.md");
  await observer.getByRole("button", {name:"Resume observer"}).click();
  await expect(second.locator("#documentation-mission").getByRole("button", {name:"Pause observer"})).toBeVisible();
  await page.reload();
  await expect(observer).toContainText("0 / 3 assessments");
  await page.setViewportSize({width:1280,height:900});
  await page.screenshot({path:"test-results/documentation-observer-desktop.png", fullPage:true});
  await page.setViewportSize({width:390,height:844});
  await page.screenshot({path:"test-results/documentation-observer-mobile.png", fullPage:true});
  expect(await page.evaluate(()=>document.documentElement.scrollWidth > innerWidth)).toBe(false);
  await page.goto("/");
  const other = await page.locator(".session-open").evaluateAll((links, current) => links.map(l=>l.getAttribute("href")).find(href=>href!==current), path);
  await page.goto(other);
  await expect(page.locator("#documentation-mission").getByRole("button", {name:"Start documentation observer"})).toBeVisible();
  await second.locator("#documentation-mission").getByRole("button", {name:"Stop observer & fixes"}).click();
  await page.goto(path);
  await expect(observer.getByRole("button", {name:"Delete observer"})).toBeVisible();
  await observer.evaluate(el => el.scrollIntoView({block:"start", behavior:"instant"}));
  await page.screenshot({path:"test-results/observer-stopped-mobile.png", fullPage:true});
  await page.setViewportSize({width:1440,height:1000});
  await page.screenshot({path:"test-results/observer-stopped-desktop.png", fullPage:true});
  await observer.getByRole("button", {name:"Delete observer"}).click();
  await expect(second.locator("#documentation-mission").getByRole("button", {name:"Start documentation observer"})).toBeVisible();
  await expect(observer.locator(".followup-card")).toHaveCount(1);
  await expect(observer.locator(".followup-card")).toContainText("Retained worktree");
  await second.close();
});
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

test("night theme renders locally with mobile layout and visible keyboard focus", async ({page}) => {
  await page.goto("/");
  await expect(page.locator("html")).toHaveCSS("color-scheme", "dark");
  await expect(page.locator(".night-scene img")).toBeVisible();
  await expect.poll(() => page.locator(".night-scene img").evaluate(img => img.naturalWidth)).toBeGreaterThan(0);
  await page.screenshot({path: "test-results/desk-login.png", fullPage: true});
  await login(page);
  await page.goto("/");
  await page.emulateMedia({reducedMotion: "reduce"});
  await expect(page.locator("html")).toHaveCSS("scroll-behavior", "auto");
  await page.keyboard.press("Tab");
  await expect(page.locator(".wordmark")).toBeFocused();
  await expect(page.locator(".wordmark")).toHaveCSS("outline-style", "solid");
  for (const width of [320, 390, 768]) {
    await page.setViewportSize({width, height: 844});
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
    await expect(page.locator(".session-open").first()).toBeVisible();
  }
  await page.setViewportSize({width: 390, height: 844});
  await page.screenshot({path: "test-results/desk-overview-mobile.png", fullPage: true});
});

test("long content stays inside the viewport and polling preserves panel scrolling", async ({page}) => {
  await login(page);
  for (const width of [320, 390, 768, 1440]) {
    await page.setViewportSize({width, height:780});
    const bounds = await page.evaluate(() => {
      const list = document.querySelector(".message-list");
      const pre = document.createElement("pre");
      pre.className = "message-content";
      pre.textContent = ("Long output " + "x".repeat(250) + "\n").repeat(500);
      list.replaceChildren(pre);
      const composer = document.querySelector(".composer").getBoundingClientRect();
      const panels = document.querySelector("#panels").getBoundingClientRect();
      return {docHeight:document.documentElement.scrollHeight, docWidth:document.documentElement.scrollWidth,
        height:innerHeight, width:innerWidth, composerBottom:composer.bottom, panelBottom:panels.bottom,
        composerTop:composer.top, transcriptScrolls:list.scrollHeight > list.clientHeight};
    });
    expect(bounds.docHeight).toBeLessThanOrEqual(bounds.height);
    expect(bounds.docWidth).toBeLessThanOrEqual(bounds.width);
    expect(bounds.composerBottom).toBeLessThanOrEqual(bounds.height);
    expect(bounds.panelBottom).toBeLessThanOrEqual(bounds.composerTop);
    expect(bounds.transcriptScrolls).toBe(true);
  }
  await page.reload();
  await page.locator("#panels").evaluate(el => { el.scrollTop = 120; });
  await expect.poll(() => page.locator("#panels").evaluate(el => el.scrollTop)).toBe(120);
  const synced = await page.locator("#connection").textContent();
  await expect.poll(() => page.locator("#connection").textContent()).not.toBe(synced);
  expect(await page.locator("#panels").evaluate(el => el.scrollTop)).toBe(120);
  await page.setViewportSize({width:390, height:780});
  await page.screenshot({path:"test-results/desk-bounded-mobile.png", fullPage:true});
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
