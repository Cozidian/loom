// Real macOS launchd + Phoenix + Chrome smoke, in isolated test-owned directories.
// No login-item installation, no personal settings and no paid provider calls.
const {execFileSync} = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const net = require('node:net');
const assert = require('node:assert/strict');
const {chromium} = require('@playwright/test');
const checkout = path.resolve(__dirname, '../../..');
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'loom-service-smoke-'));
const config = path.join(root, 'config.json');
const env = {...process.env, LOOM_SERVICE_DIR:path.join(root,'service'), LOOM_DISCOVERY_DIR:path.join(root,'live')};
const cli = (...args) => execFileSync(path.join(checkout,'loom'), ['--config',config,...args], {env, cwd:root, encoding:'utf8', timeout:60000});
const record = () => JSON.parse(fs.readFileSync(path.join(root,'service/runtime.json'),'utf8'));
async function api(method, suffix, data) {
  const r = record();
  const response = await fetch(`http://127.0.0.1:${r.http_port}/api/v1/${suffix}`, {method,
    headers:{authorization:`Bearer ${r.token}`, 'content-type':'application/json'}, body:data ? JSON.stringify(data):undefined});
  const body = await response.json(); assert.equal(body.ok,true); return body.result;
}
const launch = () => {
  const output = cli('desk','--no-open');
  const url = output.match(/http:\/\/localhost:\d+\/\S*/)?.[0];
  assert.ok(url, 'CLI must return a fresh browser launch link'); return url;
};
async function until(fn, n=100) {
  for (let i=0;i<n;i++) {if (await fn()) return; await new Promise(r=>setTimeout(r,100));}
  throw new Error('Expected state did not become ready');
}
async function tuiDetach(session) {
  const endpoint = JSON.parse(fs.readFileSync(path.join(root,'live',session+'.json'),'utf8'));
  await new Promise((resolve,reject)=>{
    const socket = net.connect(endpoint.tui_port,'127.0.0.1');
    const timeout = setTimeout(()=>{socket.destroy();reject(new Error('TUI timeout'));},5000);
    let data = Buffer.alloc(0);
    socket.on('connect',()=>{
      const bytes = Buffer.from(JSON.stringify({token:endpoint.token}));
      const frame = Buffer.alloc(4+bytes.length); frame.writeUInt32BE(bytes.length); bytes.copy(frame,4);socket.write(frame);
    });
    socket.on('error',reject);
    socket.on('data',chunk=>{
      data=Buffer.concat([data,chunk]);
      if(data.length>=4 && data.length>=data.readUInt32BE(0)+4) {
        const init=JSON.parse(data.subarray(4,4+data.readUInt32BE(0)));
        assert.equal(init.type,'init'); assert.equal(init.session_id,session);
        clearTimeout(timeout);socket.end();resolve();
      }
    });
  });
}
(async()=>{
  let browser;
  try {
    cli('init','--non-interactive','--provider','echo','--data-dir',path.join(root,'sessions'));
    execFileSync('git',['init','-q'],{cwd:root});
    fs.writeFileSync(path.join(root,'README.md'),'Loom service fixture\n');
    execFileSync('git',['add','README.md'],{cwd:root});
    cli('service','start');
    const first = record().instance;
    cli('service','start'); assert.equal(record().instance,first,'start must be idempotent');
    browser = await chromium.launch({channel:'chrome'});
    const context = await browser.newContext({viewport:{width:1440,height:1000}});
    const page = await context.newPage();
    await page.goto(launch());
    await page.getByRole('heading',{name:'Your work, together.'}).waitFor();
    // Create explicitly in the fixture workspace, not the service launch directory.
    const job = await api('POST','sessions',{workspace:root,request_id:'loom-smoke-start-000001'});
    let session;
    await until(async()=>{const state=await api('GET','session-starts/'+job.request_id);session=state.session_id;return state.status==='ready';});
    await page.reload();
    await page.locator('.session-card .session-open').click();
    await page.getByRole('heading',{name:'Make good things.'}).waitFor();
    await tuiDetach(session);
    await page.getByRole('button',{name:'Start documentation observer',exact:true}).click();
    await page.getByRole('button',{name:'Pause observer',exact:true}).waitFor();
    fs.mkdirSync(path.join(checkout,'cmd/beam_agent_web/test-results'),{recursive:true});
    await page.screenshot({path:path.join(checkout,'cmd/beam_agent_web/test-results/loom-service-desktop.png')});
    const before = record().instance;
    // A cleared cookie is the browser-visible equivalent of the overnight expiry.
    await context.clearCookies(); await page.reload();
    assert.match(await page.locator('body').innerText(),/loom desk/);
    await page.screenshot({path:path.join(checkout,'cmd/beam_agent_web/test-results/loom-reconnect.png')});
    await page.goto(launch());
    await page.locator('.session-card .session-open').click();
    await page.getByRole('button',{name:'Pause observer',exact:true}).waitFor();
    assert.equal(record().instance,before,'fresh browser auth must not restart the service');
    await page.setViewportSize({width:390,height:844});
    await page.screenshot({path:path.join(checkout,'cmd/beam_agent_web/test-results/loom-service-mobile.png')});
    assert.ok(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth));
    // Kill only the web child belonging to this isolated service. The owner and
    // session must survive and publish a new browser connection.
    const web = await api('GET','service');
    const childPid = execFileSync('lsof',['-t',`-iTCP:${web.desk_port}`,'-sTCP:LISTEN'],{encoding:'utf8'}).trim();
    assert.match(childPid,/^\d+$/);
    let parentPid = childPid;
    // OTP may insert erl_child_setup between the BEAM owner and a port program.
    for(let hop=0;hop<6 && parentPid!==record().owner_pid && Number(parentPid)>1;hop++) {
      parentPid=execFileSync('ps',['-o','ppid=','-p',parentPid],{encoding:'utf8'}).trim();
    }
    assert.equal(parentPid,record().owner_pid,'only terminate this fixture service web child');
    process.kill(Number(childPid),'SIGTERM');
    await until(async()=>{const status=await api('GET','service');return status.desk_port && status.desk_port!==web.desk_port;},200);
    assert.equal(record().instance,before,'web child restart must not replace backend');
    await page.goto(launch());
    await page.locator('.session-card .session-open').click();
    await page.getByRole('button',{name:'Pause observer',exact:true}).waitFor();
    // Explicit service stop/restart, not client exit, changes the owner.
    cli('service','stop');
    await until(async()=>{try{await api('GET','service');return false;}catch{return true;}});
    cli('service','start');
    assert.notEqual(record().instance,first);
    await until(async()=>{const status=await api('GET','service');return status.recovery[session]==='restored_idle';});
    await page.goto(launch());
    await page.locator('.session-card .session-open').click();
    await page.getByRole('button',{name:'Resume observer',exact:true}).waitFor();
    console.log('PASS: launchd singleton, short-lived CLI, real TUI detach, browser reauthentication, web-child restart, desktop/mobile and paused observer recovery.');
  } finally {
    if(browser) await browser.close();
    try{cli('service','stop');}catch{}
    // Only this smoke-created tree is removed. The job never installs at login.
    fs.rmSync(root,{recursive:true,force:true});
  }
})().catch(error=>{console.error(error.message);process.exitCode=1;});
