const { test, expect } = require('@playwright/test');
async function open(page) {
  await page.goto('/');
  await page.getByLabel('Runtime access token').fill('local-browser-fixture-token-only');
  await page.getByRole('button',{name:/Open workspace/}).click();
  await page.goto('/observatory');
  await expect(page.locator('.cockpit')).toBeVisible();
}

test('system atlas presents real imports, multidimensional evidence and a reviewable change brief', async ({page})=>{
  const errors=[];page.on('pageerror',e=>errors.push(e.message));page.on('console',m=>{if(m.type()==='error')errors.push(m.text());});
  await open(page);
  await expect(page.getByRole('heading',{name:'northstar-commerce'})).toBeVisible();
  await expect(page.locator('[data-component]')).toHaveCount(15);
  await page.screenshot({path:'test-results/observatory-atlas-desktop.png',fullPage:true});
  await page.getByRole('button',{name:'Explore all 5 Application components'}).click();
  await expect(page.locator('[data-component]')).toHaveCount(5);
  await expect(page.locator('#obs-map-scope')).toContainText('Focused layer');
  await page.getByRole('button',{name:'↺ Reset view'}).click();
  await page.locator('[data-component="src/ui"]').click();
  await expect(page.getByLabel('Trace destination')).toHaveCount(0);
  await expect(page.locator('[data-lens="churn"]')).toHaveCount(0);
  await expect(page.locator('[data-lens="architecture"]')).toBeVisible();
  await expect(page.locator('[data-lens="integrations"]')).toBeVisible();
  await expect(page.locator('[data-lens="interactions"]')).toBeVisible();
  await expect(page.locator('[data-lens="protocols"]')).toBeVisible();

  await page.locator('[data-component="src/api"]').click();
  await page.locator('[data-lens="protocols"]').click();
  await expect(page.locator('#obs-inspector')).toContainText('Detected routes & RPCs');
  await expect(page.locator('#obs-inspector')).toContainText('GET /api/orders');
  await expect(page.locator('#obs-inspector')).toContainText('POST /api/webhooks/payment');

  await page.locator('[data-lens="integrations"]').click();
  await page.locator('[data-component="src/payments"]').click();
  await expect(page.locator('#obs-inspector')).toContainText('External touchpoints');
  await expect(page.locator('#obs-inspector')).toContainText('stripe');
  await expect(page.locator('#obs-inspector')).toContainText('declared · npm');

  await page.locator('[data-lens="interactions"]').click();
  await expect(page.locator('#obs-inspector')).toContainText('Co-change partners');

  await page.locator('[data-lens="architecture"]').click();
  await page.locator('[data-component="src/auth"]').click();
  await page.getByRole('button', {name:'src/auth/login.ts', exact:true}).click();
  await expect(page.locator('.obs-code-view')).toContainText('export const login');

  await page.locator('[data-mode="investigate"]').click();
  await expect(page.locator('[data-lens="churn"]')).toBeVisible();
  await page.locator('[data-component="src/ui"]').click();
  await page.getByLabel('Trace destination').selectOption('src/data');
  await page.getByRole('button',{name:'Trace dependency path →'}).click();
  await expect(page.locator('.obs-trace-result')).toContainText('src/ui/account.tsx → src/auth/login.ts');
  await expect(page.locator('.obs-trace-result')).toContainText('src/auth/login.ts → src/data/users.ts');
  await page.locator('[data-component="src/data"]').click();
  await expect(page.locator('#obs-inspector')).toContainText('Boundary relationships');
  await page.getByRole('button',{name:'Rehearse a change ↗',exact:true}).click();
  await expect(page.locator('#obs-inspector')).toContainText('src/ui/checkout.tsx');
  await expect(page.locator('#obs-inspector')).toContainText('src/checkout/order.test.ts');
  await page.getByLabel('Proposed change').fill('Move storage behind a versioned interface');
  await page.screenshot({path:'test-results/observatory-impact-desktop.png',fullPage:true});
  await page.getByRole('button',{name:'Prepare evidence-backed brief ↗'}).click();
  await expect(page.getByLabel('Editable investigation brief')).toHaveValue(/Move storage behind a versioned interface/);
  await expect(page.getByLabel('Editable investigation brief')).toHaveValue(/src\/auth\/login.ts:1/);
  await expect(page.getByLabel('Editable investigation brief')).toHaveValue(/Do not modify code/);
  const download=page.waitForEvent('download');await page.getByRole('button',{name:'Download .md'}).click();
  expect((await download).suggestedFilename()).toBe('observatory-investigation.md');
  await page.getByRole('button',{name:'Close investigation brief'}).click();
  await page.getByRole('button',{name:'Evidence & blind spots ↗'}).click();
  await expect(page.getByRole('dialog')).toContainText('No vulnerabilities established');
  await expect(page.getByRole('dialog')).toContainText('No deployments, traces');
  await page.screenshot({path:'test-results/observatory-evidence.png',fullPage:true});
  expect(errors).toEqual([]);
});

test('history scrubs actual commits on current topology; search, isolation, zoom and keyboard selection work',async({page})=>{
  await open(page);
  await page.getByLabel('Scrub sampled commit history').fill('3');
  await expect(page.locator('#obs-time-detail')).toContainText('Tighten identity checks');
  await expect(page.locator('.obs-component.touched')).toHaveCount(1);
  await page.getByRole('button',{name:'Now',exact:true}).click();
  await expect(page.locator('#obs-time-label')).toHaveText('Current worktree');
  await page.getByRole('button',{name:'▶ Play history'}).click();
  await expect(page.getByRole('button',{name:'Ⅱ Pause history'})).toBeVisible();
  await page.getByRole('button',{name:'Ⅱ Pause history'}).click();
  await page.getByRole('button',{name:'Now',exact:true}).click();
  await page.getByLabel('Find a component or file').fill('src/auth');
  await expect(page.locator('[data-component]')).toHaveCount(1);
  await page.locator('[data-component="src/auth"]').focus();await page.keyboard.press('Enter');
  await expect(page.locator('#obs-inspector')).toContainText('Boundary relationships');
  await page.locator('[data-mode="investigate"]').click();
  await expect(page.locator('#obs-inspector')).toContainText('Security-sensitive names');
  await page.getByLabel('Find a component or file').fill('');
  await page.getByRole('button',{name:'Isolate neighborhood'}).click();
  await expect(page.locator('[data-component]')).toHaveCount(5);
  await page.getByRole('button',{name:'Zoom in',exact:true}).click();
  await expect(page.locator('[data-world]')).toHaveAttribute('transform',/scale\(1.2\)/);
  await page.getByRole('button',{name:'↺ Reset view'}).click();
  await expect(page.locator('[data-component]')).toHaveCount(15);
  await page.getByLabel('Find a component or file').fill('no-such-file');
  await expect(page.locator('#obs-empty')).toBeVisible();
});
