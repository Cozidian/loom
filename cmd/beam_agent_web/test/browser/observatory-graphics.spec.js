const {test,expect}=require('@playwright/test');
test('mobile atlas keeps navigation, map, evidence and rehearsal accessible',async({page})=>{
  await page.setViewportSize({width:390,height:844});await page.emulateMedia({reducedMotion:'reduce'});
  await page.goto('/');await page.getByLabel('Runtime access token').fill('local-browser-fixture-token-only');await page.getByRole('button',{name:/Open workspace/}).click();await page.goto('/observatory');
  await expect(page.locator('.cockpit')).toBeVisible();
  expect(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth)).toBe(true);
  await page.getByLabel('Find a component or file').fill('src/auth');
  await page.locator('.obs-tree-item').click();
  await expect(page.locator('#obs-inspector')).toContainText('src/auth');
  await page.locator('#obs-inspector').scrollIntoViewIfNeeded();
  await page.screenshot({path:'test-results/observatory-mobile-evidence.png',fullPage:true});
  await page.getByRole('button',{name:'Rehearse a change ↗',exact:true}).click();
  await expect(page.getByLabel('Proposed change')).toBeVisible();
  await page.getByRole('button',{name:'Prepare evidence-backed brief ↗'}).click();
  await expect(page.getByRole('dialog')).toBeVisible();
  expect(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth)).toBe(true);
});

test('an older runtime report shows an actionable error instead of an inert cockpit',async({page})=>{
  await page.goto('/');await page.getByLabel('Runtime access token').fill('local-browser-fixture-token-only');await page.getByRole('button',{name:/Open workspace/}).click();
  await page.route('**/observatory',async route=>{
    const response=await route.fetch();
    const html=await response.text();
    const legacy=html.replace(/(<script type="application\/json" id="obs-data">)([\s\S]*?)(<\/script>)/,(_,open,json,close)=>{
      const report=JSON.parse(json);delete report.model;return open+JSON.stringify(report).replaceAll('</','<\\/')+close;
    });
    await route.fulfill({response,body:legacy});
  });
  await page.goto('/observatory');
  await expect(page.getByRole('alert')).toContainText('Rebuild Loom');
  await expect(page.locator('[data-mode="understand"]')).toBeDisabled();
  await expect(page.locator('#obs-coverage')).toHaveText('Repository model unavailable');
});
