/* The browser projects the runtime's versioned evidence model. It never owns
   execution, calls a provider, or applies the changes being rehearsed. */
(() => {
  'use strict';
  const payload = document.getElementById('obs-data');
  const root = document.querySelector('.cockpit');
  if (!payload || !root) return;
  function unavailable(message) {
    const empty = document.getElementById('obs-empty');
    empty.hidden = false;
    empty.textContent = message;
    empty.setAttribute('role', 'alert');
    document.getElementById('obs-coverage').textContent = 'Repository model unavailable';
    document.getElementById('obs-inspector').textContent = message;
    root.querySelectorAll('button, input').forEach(control => { control.disabled = true; });
  }
  let report;
  try { report = JSON.parse(payload.textContent); }
  catch { unavailable('The repository report could not be read. Reload the page to request a fresh report.'); return; }
  const model = report.model;
  if (!model || model.schema_version !== 1) {
    unavailable('The running Loom service does not provide the model required by this Observatory. Rebuild Loom with mix loom.build --frontend web, then stop and start the service and reopen Desk.');
    return;
  }
  const $ = id => document.getElementById(id);
  const files = new Map(model.files.map(f => [f.path, f]));
  const components = new Map(model.components.map(c => [c.id, c]));
  const layers = [
    ['interface', '01', 'Interfaces', 'Where the system meets the world', '#91c9ef'],
    ['application', '02', 'Application', 'Composition & supporting behavior', '#a9a0ed'],
    ['domain', '03', 'Core behavior', 'Rules, state & lifecycle', '#9ee1be'],
    ['data', '04', 'Data & persistence', 'Schemas, storage & durable state', '#efc382'],
    ['operations', '05', 'Delivery & operations', 'Configuration & deployment machinery', '#e6a6ad'],
    ['assurance', '06', 'Assurance', 'Tests, documentation & evaluation', '#a9b7c7']
  ];
  const state = {mode:'understand', lens:'architecture', selected:null, file:null, query:'', trace:null, layerFocus:null, isolate:false, spread:55, zoom:1, pan:{x:0,y:0}, time:model.timeline.length};
  const LENS_SETS = {
    understand: [['architecture','Architecture'],['integrations','Integrations'],['interactions','Interactions'],['protocols','Protocols']],
    investigate: [['churn','Change pressure'],['tests','Test evidence'],['security','Sensitive paths']],
    rehearse: []
  };
  let timer = null;
  const sourceCache = new Map();
  const colors = Object.fromEntries(layers.map(l=>[l[0],l[4]]));
  const svgNS = 'http://www.w3.org/2000/svg';
  function el(tag, cls, text) { const n = document.createElement(tag); if(cls) n.className=cls; if(text!==undefined) n.textContent=text; return n; }
  function svg(tag, attrs, text) { const n=document.createElementNS(svgNS,tag); for(const [k,v] of Object.entries(attrs||{})) n.setAttribute(k,v); if(text!==undefined)n.textContent=text; return n; }
  function button(text, fn, cls='obs-quiet') { const b=el('button',cls,text); b.type='button'; b.addEventListener('click',fn); return b; }
  function announce(text) { $('obs-announcement').textContent=text; }
  function trunc(s,n=27) { return s.length>n?s.slice(0,n-1)+'…':s; }
  function metric(parent,label,value) { const row=el('div','obs-metric'); row.append(el('dt','',label),el('dd','',String(value))); parent.append(row); }
  function addText(parent,title,text) { const block=el('section','obs-evidence-section'); block.append(el('h3','',title),el('p','',text));parent.append(block); return block; }
  function filteredComponents() {
    const q=state.query.toLowerCase();
    let list=model.components.filter(c=>!q || c.id.toLowerCase().includes(q) || c.files.some(p=>p.toLowerCase().includes(q)));
    if(state.layerFocus)list=list.filter(c=>c.layer===state.layerFocus);
    if(state.isolate && state.selected) {
      const c=components.get(state.selected); const ids=new Set([c.id,...c.consumers,...c.dependencies]);
      list=list.filter(c=>ids.has(c.id));
    }
    return list;
  }
  function select(id,path=null) { state.selected=id;state.file=path;state.trace=null;if(state.layerFocus&&components.get(id)?.layer!==state.layerFocus)state.layerFocus=null; render();announce(`Selected ${path||id}`); }
  function impact(target) {
    const seeds = model.files.filter(f=>f.path===target||f.component===target).map(f=>f.path);
    const reached = new Set(seeds); let frontier=new Set(seeds);
    for(let depth=0;depth<12 && frontier.size;depth++) {
      const next=new Set(model.edges.filter(e=>frontier.has(e.target)&&!reached.has(e.source)).map(e=>e.source));
      next.forEach(p=>reached.add(p)); frontier=next;
    }
    const affected=model.files.filter(f=>reached.has(f.path));
    return {seeds, affected:affected.map(f=>f.path), downstream:affected.filter(f=>!seeds.includes(f.path)).map(f=>f.path),
      tests:[...new Set(affected.flatMap(f=>f.tests))], components:[...new Set(affected.map(f=>f.component))], security:affected.filter(f=>f.security_sensitive).map(f=>f.path)};
  }
  function trace(origin,destination) {
    const starts=model.files.filter(f=>f.path===origin||f.component===origin).map(f=>f.path);
    const targets=new Set(model.files.filter(f=>f.path===destination||f.component===destination).map(f=>f.path));
    const seen=new Set(starts),queue=starts.map(path=>({path,edges:[]}));
    while(queue.length){
      const current=queue.shift();
      if(targets.has(current.path))return {found:true,edges:current.edges,destination};
      if(current.edges.length>=12)continue;
      for(const e of model.edges.filter(e=>e.source===current.path)){
        if(seen.has(e.target))continue;seen.add(e.target);queue.push({path:e.target,edges:[...current.edges,e]});
      }
    }
    return {found:false,edges:[],destination};
  }
  function tracePanel(host,c,f) {
    const section=addText(host,'Trace a reference path','Find an observed import chain to another component. This is not a runtime request trace.');
    const selectBox=el('select','obs-trace-select');selectBox.setAttribute('aria-label','Trace destination');
    const destinations=model.components.filter(other=>other.id!==c.id);
    for(const other of destinations){const option=el('option','',other.id);option.value=other.id;selectBox.append(option);}
    if(destinations.some(d=>d.layer==='data'))selectBox.value=destinations.find(d=>d.layer==='data').id;
    const result=el('div','obs-trace-result');result.setAttribute('aria-live','polite');
    const run=button('Trace dependency path →',()=>{
      state.trace=trace(f?f.path:c.id,selectBox.value);result.replaceChildren();
      if(!state.trace.found)result.append(el('p','obs-muted','No path resolved. Dynamic calls, aliases or missing source may hide a real connection.'));
      else for(const edge of state.trace.edges){const row=el('div','obs-reference');row.append(el('code','',`${edge.source} → ${edge.target}`),el('small','',edge.evidence));result.append(row);}
      renderMap();
    });run.disabled=!destinations.length;section.append(selectBox,run,result);
  }
  function tree() {
    const host=$('obs-tree');host.replaceChildren();
    const visible=filteredComponents();
    $('obs-component-count').textContent=model.components.length;
    for(const [id,number,name,,color] of layers) {
      const members=visible.filter(c=>c.layer===id);if(!members.length)continue;
      const group=el('section','obs-tree-group');const heading=el('h3','');const dot=el('i','obs-layer-dot');dot.style.background=color;
      heading.append(dot,el('span','',name),el('small','',String(members.length)));group.append(heading);
      for(const c of members) {
        const b=button('',()=>select(c.id),'obs-tree-item'+(state.selected===c.id?' selected':''));
        b.append(el('span','',c.id),el('small','',String(c.file_count)));b.setAttribute('aria-pressed',String(state.selected===c.id));group.append(b);
      }
      host.append(group);
    }
    if(!visible.length)host.append(el('p','obs-muted','No matches. Search a path or reset.'));
  }
  function renderMap() {
    const atlas=$('obs-atlas');atlas.replaceChildren();
    const visible=filteredComponents();
    const activeCommit=model.timeline[state.time];
    const touched=new Set(activeCommit?.files||[]);
    const shown=state.layerFocus||state.query||state.isolate?visible.slice(0,48):layers.flatMap(([layer])=>visible.filter(c=>c.layer===layer).sort((a,b)=>Number(b.id===state.selected)-Number(a.id===state.selected)||Number(b.files.some(p=>touched.has(p)))-Number(a.files.some(p=>touched.has(p)))||b.consumers.length-a.consumers.length||b.commits-a.commits).slice(0,4));

    const rehearsal=state.mode==='rehearse'&&state.selected?impact(state.file||state.selected):null;
    const affected=new Set(rehearsal?.components||[]);
    const routeEdges=state.trace?.found?state.trace.edges:[];
    const routeComponents=new Set(routeEdges.flatMap(e=>[files.get(e.source)?.component,files.get(e.target)?.component]));
    const selected=components.get(state.selected);
    const neighborhood=new Set(selected?[selected.id,...selected.consumers,...selected.dependencies]:[]);
    const defs=svg('defs');const marker=svg('marker',{id:'obs-arrow',viewBox:'0 0 10 10',refX:9,refY:5,markerWidth:5,markerHeight:5,orient:'auto-start-reverse'});marker.append(svg('path',{d:'M 0 0 L 10 5 L 0 10 z',fill:'#738c9d'}));defs.append(marker);atlas.append(defs);
    const world=svg('g',{'data-world':'true'});atlas.append(world);
    const planes=svg('g');const links=svg('g');const cards=svg('g');world.append(planes,links,cards);
    const positions=new Map();let y=40;
    const width=1040;const cardWidth=211;const cardHeight=48;
    const populated=layers.filter(l=>shown.some(c=>c.layer===l[0]));
    for(let pair=0;pair<populated.length;pair+=2) {
      const pairLayers=populated.slice(pair,pair+2);
      let pairHeight=0;
      pairLayers.forEach(([layer,num,name,description,color],column)=>{
        const members=shown.filter(c=>c.layer===layer);
        const columns=populated.length===1?4:2;
        const total=visible.filter(c=>c.layer===layer).length;
        const collapsed=total>members.length;
        const height=Math.ceil(members.length/columns)*(cardHeight+10)+34+(collapsed?28:0);
        pairHeight=Math.max(pairHeight,height);
        const left=20+column*510,shift=(pair/2%2)*8,planeWidth=columns===4?980:470;
        planes.append(svg('path',{d:`M ${left} ${y} L ${left+planeWidth} ${y} L ${left+planeWidth+20} ${y+height} L ${left+20} ${y+height} Z`,fill:color,'fill-opacity':.04,stroke:color,'stroke-opacity':.2}));
        planes.append(svg('text',{x:left+18,y:y+20,fill:color,class:'obs-plane-title'},`${num} / ${name.toUpperCase()}`));
        members.forEach((c,i)=>positions.set(c.id,{x:left+18+shift+(i%columns)*230,y:y+30+Math.floor(i/columns)*(cardHeight+10)}));
        if(collapsed){
          const expand=svg('g',{class:'obs-layer-expand',tabindex:0,role:'button','aria-label':`Explore all ${total} ${name} components`,transform:`translate(${left+18},${y+height-22})`});
          expand.append(svg('rect',{width:440,height:24,fill:'transparent'}),svg('text',{x:0,y:13,fill:color},`+ ${total-members.length} more · explore this layer →`));
          const focus=()=>{state.layerFocus=layer;state.pan={x:0,y:0};state.zoom=1;render();};
          expand.addEventListener('click',focus);expand.addEventListener('keydown',e=>{if(e.key==='Enter'||e.key===' '){e.preventDefault();focus();}});cards.append(expand);
        }
      });
      y+=pairHeight+8+state.spread*.15;
    }
    const coChangeMode=state.mode==='understand'&&state.lens==='interactions';
    const grouped=new Map();
    for(const e of (coChangeMode?model.co_change:model.edges)) {
      let a=files.get(e.source)?.component,b=files.get(e.target)?.component;
      if(!a||!b||a===b||!positions.has(a)||!positions.has(b))continue;
      if(coChangeMode&&a>b)[a,b]=[b,a];
      const key=JSON.stringify([a,b]); grouped.set(key,(grouped.get(key)||0)+(coChangeMode?e.commits:1));
    }
    for(const [key,count] of grouped) {
      const [a,b]=JSON.parse(key),p=positions.get(a),q=positions.get(b);
      const lit=routeEdges.length?routeEdges.some(e=>files.get(e.source)?.component===a&&files.get(e.target)?.component===b):state.mode==='rehearse'?affected.has(a)&&affected.has(b):a===state.selected||b===state.selected;
      const x1=p.x+cardWidth/2,y1=p.y+cardHeight,x2=q.x+cardWidth/2,y2=q.y;
      const bend=Math.max(38,Math.abs(y2-y1)*.4);
      const attrs={d:`M ${x1} ${y1} C ${x1} ${y1+bend} ${x2} ${y2-bend} ${x2} ${y2}`,class:`obs-atlas-edge${lit?' lit':''}${coChangeMode?' co-change':''}`,'stroke-width':lit?2:1};
      if(!coChangeMode)attrs['marker-end']='url(#obs-arrow)';
      const edge=svg('path',attrs);
      edge.append(svg('title',{},coChangeMode?`${a} ↔ ${b}: ${count} shared commits (correlation, not a dependency)`:`${a} → ${b}: ${count} static references`));links.append(edge);
    }
    const maxChurn=Math.max(1,...model.components.map(c=>c.commits));
    const maxCoChange=Math.max(1,...model.components.map(c=>c.co_change_partners.reduce((s,p)=>s+p.commits,0)));
    const maxProtocols=Math.max(1,...model.components.map(c=>c.protocol_count));
    for(const c of shown) {
      const p=positions.get(c.id),isSelected=c.id===state.selected;
      const hasActivity=c.files.some(path=>touched.has(path));
      const dim=activeCommit?!hasActivity:routeEdges.length?!routeComponents.has(c.id):state.mode==='rehearse'&&rehearsal?!affected.has(c.id):state.isolate&&!neighborhood.has(c.id);
      const card=svg('g',{transform:`translate(${p.x},${p.y})`,class:`obs-component${isSelected?' selected':''}${dim?' dim':''}${hasActivity?' touched':''}${affected.has(c.id)?' affected':''}`,tabindex:0,role:'button','aria-label':`${c.id}, ${c.file_count} files`,'aria-pressed':String(isSelected),'data-component':c.id});
      const color=colors[c.layer];
      card.append(svg('rect',{width:cardWidth,height:cardHeight,rx:5,class:'obs-component-body'}));
      card.append(svg('rect',{width:3,height:cardHeight-16,x:0,y:8,fill:color,rx:1}));
      card.append(svg('text',{x:14,y:18,class:'obs-component-name'},trunc(c.id,26)));
      const coChangeWeight=c.co_change_partners.reduce((s,p)=>s+p.commits,0);
      const declaredTouchpoints=c.external_touchpoints.filter(t=>t.declared).length;
      let detail=`${c.file_count} files · ${c.consumers.length} consumers`;
      if(state.lens==='churn')detail=`${c.commits} sampled file touches`;
      if(state.lens==='tests')detail=`${c.test_matches}/${c.file_count} test matches`;
      if(state.lens==='security')detail=`${c.security_paths} sensitive path names`;
      if(state.lens==='integrations')detail=`${c.external_touchpoints.length} touchpoints · ${declaredTouchpoints} declared`;
      if(state.lens==='interactions')detail=`${c.co_change_partners.length} co-change link${c.co_change_partners.length===1?'':'s'}`;
      if(state.lens==='protocols')detail=`${c.protocol_count} detected route${c.protocol_count===1?'':'s'}`;
      card.append(svg('text',{x:14,y:32,class:'obs-component-detail'},detail));
      if(state.lens==='architecture') {
        for(let i=0;i<Math.min(c.file_count,24);i++)card.append(svg('rect',{x:14+i*6,y:40,width:3,height:3,fill:color,opacity:.6}));
      } else {
        const proportion=
          state.lens==='churn'?c.commits/maxChurn:
          state.lens==='tests'?(c.file_count?c.test_matches/c.file_count:0):
          state.lens==='security'?(c.file_count?c.security_paths/c.file_count:0):
          state.lens==='integrations'?(c.external_touchpoints.length?declaredTouchpoints/c.external_touchpoints.length:0):
          state.lens==='interactions'?coChangeWeight/maxCoChange:
          state.lens==='protocols'?c.protocol_count/maxProtocols:0;
        card.append(svg('rect',{x:14,y:40,width:180,height:3,fill:'#2a3641',rx:1}));
        card.append(svg('rect',{x:14,y:40,width:180*proportion,height:3,fill:color,rx:1}));
      }
      card.append(svg('title',{},`${c.id}\n${c.purpose}\n${detail}`));
      card.addEventListener('click',()=>select(c.id));card.addEventListener('keydown',e=>{if(e.key==='Enter'||e.key===' '){e.preventDefault();select(c.id);}});
      cards.append(card);
    }
    atlas.setAttribute('viewBox',`0 0 ${width} ${Math.max(430,y)}`);
    atlas.style.minHeight='440px';
    $('obs-empty').hidden=shown.length>0;
    $('obs-map-count').textContent=`${shown.length} / ${model.components.length} components · ${grouped.size} boundary links`;
    $('obs-map-scope').textContent=state.layerFocus?'Focused layer · Reset to show the system':shown.length<visible.length?'Some layers collapsed · explore a layer to see all':'Inferred layers · static references';
    applyPan();
  }
  function applyPan(){const world=$('obs-atlas').querySelector('[data-world]');if(world)world.setAttribute('transform',`translate(${state.pan.x} ${state.pan.y}) scale(${state.zoom})`);}
  function renderLenses() {
    const options=LENS_SETS[state.mode]||[];
    if(!options.some(([id])=>id===state.lens))state.lens=options.length?options[0][0]:state.lens;
    $('obs-lenses').hidden=options.length===0;
    const host=$('obs-lens-buttons');host.replaceChildren();
    for(const [id,label] of options) {
      const b=button(label,()=>{state.lens=id;render();});
      b.dataset.lens=id;b.classList.toggle('active',id===state.lens);b.setAttribute('aria-pressed',String(id===state.lens));
      host.append(b);
    }
  }
  async function fetchSource(path) {
    try {
      const r=await fetch(`${root.dataset.sessionUrl}/observatory/file?path=${encodeURIComponent(path)}`);
      const body=await r.json().catch(()=>null);
      if(!r.ok||!body||body.error)return {error:'Source unavailable for this file.'};
      return body;
    } catch { return {error:'Source request failed. Check your connection and try again.'}; }
  }
  function paintSource(code,result) {
    code.textContent=result.error?result.error:result.content+(result.truncated?'\n\n… truncated at 200KB — open the file directly for the rest.':'');
    code.classList.toggle('obs-code-error',!!result.error);
  }
  function loadSource(path,code) {
    if(sourceCache.has(path)){paintSource(code,sourceCache.get(path));return;}
    fetchSource(path).then(result=>{sourceCache.set(path,result);if(state.file===path)paintSource(code,result);});
  }
  function sourceViewer(host,f) {
    const section=addText(host,'Source','Full file text, read on demand from the workspace. Not part of the model\'s bounded source sample.');
    const pre=el('pre','obs-code-view');const code=el('code','','Loading…');pre.append(code);section.append(pre);
    loadSource(f.path,code);
  }
  function pathList(parent, paths, empty='None observed in this model.') {
    if(!paths.length){parent.append(el('p','obs-muted',empty));return;}
    const list=el('div','obs-path-list');
    paths.slice(0,60).forEach(p=>list.append(button(p,()=>{const f=files.get(p);if(f)select(f.component,p);},'obs-path')));
    if(paths.length>60)list.append(el('small','',`${paths.length-60} more in the model JSON`));parent.append(list);
  }
  function integrationsPanel(host,c,f) {
    const section=addText(host,'External touchpoints','Unresolved import names matched against declared dependencies by name only. An unmatched name may be undeclared, a bundler alias, or a file outside this model\'s limit.');
    const list=f?f.external_touchpoints:c.external_touchpoints;
    if(!list.length){section.append(el('p','obs-muted','No unresolved external references observed here.'));return;}
    for(const t of list) {
      const item=el('div','obs-reference');
      item.append(el('code','',t.package),el('small','',t.declared?`declared · ${t.ecosystem} ${t.version}`:'unrecognized · may be undeclared, a bundler alias, or outside this model\'s limit'));
      section.append(item);
    }
  }
  function interactionsPanel(host,c,f) {
    const section=addText(host,'Co-change partners','Files or components committed together in the sampled history. Correlation only — never promoted to a dependency.');
    const partners=f?f.co_change:c.co_change_partners;
    if(!partners.length){section.append(el('p','obs-muted','No co-change observed in the sampled commits.'));return;}
    const box=el('div','obs-path-list');
    partners.slice(0,20).forEach(p=>{
      const label=f?p.path:p.id;
      box.append(button(`${label} · ${p.commits} shared commit${p.commits===1?'':'s'}`,()=>{
        if(f){const target=files.get(p.path);if(target)select(target.component,p.path);} else select(p.id);
      },'obs-path'));
    });
    section.append(box);
  }
  function protocolsPanel(host,c,f) {
    const section=addText(host,'Detected routes & RPCs','Regex heuristics for common framework conventions (Phoenix/Plug, Express-style, Flask/FastAPI, Django). Not a live route table — dynamic registration and mounted sub-routers can hide real endpoints.');
    const matches=f?f.protocols:c.files.flatMap(p=>(files.get(p)?.protocols||[]).map(m=>({...m,file:p})));
    if(!matches.length){section.append(el('p','obs-muted','No route or RPC declarations matched in the modeled source.'));return;}
    matches.slice(0,40).forEach(m=>{
      const item=el('div','obs-reference');
      item.append(el('code','',`${m.method} ${m.path}`),el('small','',`${m.framework}${f?(m.line?` · line ${m.line}`:''):` · ${m.file}`}`));
      section.append(item);
    });
  }
  function understandLensPanel(host,c,f) {
    if(state.lens==='integrations')return integrationsPanel(host,c,f);
    if(state.lens==='interactions')return interactionsPanel(host,c,f);
    if(state.lens==='protocols')return protocolsPanel(host,c,f);
    if(f){addText(host,'Go deeper','Reference locations, contribution history and candidate tests live in Investigate.');return;}
    const relations=addText(host,'Boundary relationships','Consumer → dependency. Static matches, not observed runtime calls.');
    for(const [label,ids] of [['Used by',c.consumers],['Depends on',c.dependencies]]) {
      relations.append(el('h4','',label));if(!ids.length)relations.append(el('p','obs-muted','No cross-component reference resolved.'));
      ids.forEach(id=>relations.append(button(id,()=>select(id),'obs-path')));
    }
    const section=addText(host,'Pull this component apart',`${c.file_count} modeled files. Select one to see its place in the shape.`);pathList(section,c.files);
  }
  function inspect() {
    const host=$('obs-inspector');host.replaceChildren();
    const c=components.get(state.selected),f=files.get(state.file);
    if(!c){
      host.append(el('p','obs-eyebrow','ORIENTATION / START WITH THE SHAPE'),el('h2','','Every system leaves a trace.'));
      addText(host,'Your first reading',`${model.components.length} inferred components across ${new Set(model.components.map(c=>c.layer)).size} layers. Follow arrows from consumers toward the code they depend on.`);
      const stats=el('dl','obs-metrics');metric(stats,'Modeled files',model.files.length);metric(stats,'Static references',model.edges.length);metric(stats,'Sampled commits',model.timeline.length);host.append(stats);
      addText(host,'Repository fingerprint', (report.languages||[]).map(l=>`${l.language}: ${l.files} files`).join(' · ') + '. Languages describe the indexed source, not deployed services.');
      addText(host,'Read the map','Layers come from file paths. Open a component to see its files and the exact references behind each boundary. A quiet area is not necessarily safe.');
      const route=el('section','obs-reading-route');route.append(el('h3','','A route into the system'));
      for(const [i,r] of model.investigations.slice(0,3).entries())route.append(button(`${String(i+1).padStart(2,'0')}  ${r.target}`,()=>select(r.target),'obs-route'));host.append(route);
      addText(host,'What is deliberately unknown','Production behavior, vulnerability status, measured test coverage and business intent need additional evidence.');return;
    }
    host.append(el('p','obs-eyebrow',f?'FILE / SOURCE EVIDENCE':'COMPONENT / INFERRED BOUNDARY'));
    host.append(el('h2','',f?f.path.split('/').pop():c.name),el('p','obs-selection-path',f?f.path:c.id));
    if(f)host.append(button('← Component overview',()=>select(c.id)));
    const purpose=addText(host,'Working hypothesis',f?f.purpose:c.purpose);purpose.append(el('span','obs-tag','Inferred from path · verify in source'));
    const stats=el('dl','obs-metrics');
    metric(stats,f?'Sampled commits':'File touches',f?f.commits:c.commits);
    metric(stats,'Static consumers',f?f.consumers:c.consumers.length);
    metric(stats,'Test filename matches',f?f.tests.length:c.test_matches);
    metric(stats,'Unresolved references',f?f.unresolved:c.unresolved);host.append(stats);
    if(state.mode==='rehearse')renderRehearsal(host,c,f);
    else if(state.mode==='understand') {
      const actions=el('div','obs-inspector-actions');actions.append(button('Investigate this boundary ↗',()=>setMode('investigate'),'obs-primary'),button('Rehearse a change ↗',()=>setMode('rehearse'),'obs-quiet'));host.append(actions);
      if(f) {
        addText(host,'Source footprint',`${f.lines===null?'Source not read':`${f.lines} lines`} · ${f.bytes.toLocaleString()} bytes. Size is not semantic complexity.`);
        sourceViewer(host,f);
      }
      understandLensPanel(host,c,f);
    }
    else {
      const actions=el('div','obs-inspector-actions');actions.append(button('Rehearse a change ↗',()=>setMode('rehearse'),'obs-primary'),button('Prepare investigation',()=>brief(),'obs-quiet'));host.append(actions);
      const reasons=[];
      if((f?Number(f.security_sensitive):c.security_paths)>0)reasons.push('Security-sensitive names occur here. Confirm whether this sits on an authentication or permission path.');
      if((f?f.tests.length:c.test_matches)===0)reasons.push('No matching test filenames found. Coverage is unknown; inspect integration tests before assuming a gap.');
      if((f?f.consumers:c.consumers.length)>0)reasons.push('Observed consumers depend on this boundary. Establish the contract before rewriting it.');
      if((f?f.unresolved:c.unresolved)>0)reasons.push('Some references are unresolved. Impact analysis will miss those paths.');
      addText(host,'Why investigate?',reasons.join(' ')||'No warning established from these signals. Inspect intent and tests before treating the area as safe.');
      tracePanel(host,c,f);
      if(f) {
        addText(host,'Source footprint',`${f.lines===null?'Source not read':`${f.lines} lines`} · ${f.bytes.toLocaleString()} bytes. Size is not semantic complexity.`);
        sourceViewer(host,f);
        if(f.authors.length)addText(host,'Sampled contribution',f.authors.slice(0,4).map(a=>`${a.name}: ${a.commits} commits`).join(' · ') + '. This is not ownership authority.');
        const refs=el('section','obs-evidence-section');refs.append(el('h3','','Reference evidence'));
        for(const e of model.edges.filter(e=>e.source===f.path||e.target===f.path).slice(0,25)) {
          const item=el('div','obs-reference');item.append(el('code','',`${e.source} → ${e.target}`),el('small','',`${e.evidence} · ${e.reference} · lexical static match`));refs.append(item);
        }
        for(const e of model.unresolved.filter(e=>e.source===f.path).slice(0,8))refs.append(el('p','obs-muted',`${e.evidence} → ${e.reference} · unresolved (external package, alias or missing target)`));
        host.append(refs);const tests=addText(host,'Candidate tests','Filename matches only; none executed.');pathList(tests,f.tests);
      } else {
        const relations=addText(host,'Boundary relationships','Consumer → dependency. Static matches, not observed runtime calls.');
        for(const [label,ids] of [['Used by',c.consumers],['Depends on',c.dependencies]]) {
          relations.append(el('h4','',label));if(!ids.length)relations.append(el('p','obs-muted','No cross-component reference resolved.'));
          ids.forEach(id=>relations.append(button(id,()=>select(id),'obs-path')));
        }
        const section=addText(host,'Pull this component apart',`${c.file_count} modeled files. Select one to inspect its evidence.`);pathList(section,c.files);
      }
    }
  }
  function renderRehearsal(host,c,f) {
    const result=impact(f?f.path:c.id);
    const proposal=el('section','obs-proposal');proposal.append(el('h3','','What are you considering?'));
    const input=el('textarea','');input.id='obs-proposal';input.rows=3;input.placeholder='e.g. Replace this boundary while preserving its callers';input.setAttribute('aria-label','Proposed change');input.value=proposalDraft;input.addEventListener('input',()=>proposalDraft=input.value);proposal.append(input);host.append(proposal);
    const counts=el('dl','obs-metrics');metric(counts,'Potentially affected files',result.affected.length);metric(counts,'Downstream files',result.downstream.length);metric(counts,'Candidate tests',result.tests.length);host.append(counts);
    addText(host,'Partial static reachability','This rehearsal assumes the selected boundary changes. It traces reverse imports up to 12 hops. The proposal text is recorded for investigation; it does not alter the graph estimate.');
    const down=addText(host,'Possible blast radius','Highlighted components include the selected scope and reachable consumers. Co-change is not used as a dependency.');pathList(down,result.downstream,'No downstream consumer resolved. This does not establish that the change is isolated.');
    const tests=addText(host,'Verification surface','Inspect these candidates, then identify missing integration and deployment checks.');pathList(tests,result.tests,'No candidate tests matched. Discover behavioral tests before changing this boundary.');
    if(result.security.length)addText(host,'Security review surface',result.security.slice(0,6).join(' · '));
    addText(host,'Before a rewrite','Characterize current behavior. Protect contracts with tests. Migrate one consumer at a time and verify rollback. Churn and size alone do not justify replacement.');
    host.append(button('Prepare evidence-backed brief ↗',()=>brief(),'obs-primary'));
  }
  let proposalDraft='';
  function brief() {
    if(!state.selected)return;
    const target=state.file||state.selected,result=impact(target),c=components.get(state.selected);
    const refs=model.edges.filter(e=>result.affected.includes(e.source)&&result.affected.includes(e.target));
    $('obs-brief').value=[`# Investigate ${target}`,`Repository: ${report.workspace_root}`,`Snapshot: ${report.head||'unversioned'} · ${report.generated_at}`,`\nIntent: ${proposalDraft||'Understand this boundary and recommend the next safe step.'}`,`\nWorking hypothesis (path inference): ${c.purpose}`,`\nStatic impact: ${result.affected.length} files across ${result.components.length} components; up to 12 reverse-import hops.`, `\nPotential downstream files:\n${result.downstream.map(p=>'- '+p).join('\n')||'- None resolved; isolation is unproven.'}`,`\nCandidate tests (not executed):\n${result.tests.map(p=>'- '+p).join('\n')||'- None matched; identify behavioral tests.'}`,`\nReference evidence:\n${refs.slice(0,40).map(e=>`- ${e.evidence}: ${e.source} → ${e.target}`).join('\n')||'- No internal import evidence resolved.'}`,`\nUnknowns:\n${model.limits.map(l=>'- '+l).join('\n')}`,`\nTask: Recheck current source and Git state. Explain the boundary, validate this impact estimate, inspect relevant tests and recommend a safe sequence. Do not modify code in this investigation. Do not invoke paid providers or external integrations without the session's authorization.`, `\nAgent query: repository_intelligence {"action":"impact","target":${JSON.stringify(target)}}`].join('\n');
    $('obs-brief-dialog').showModal();
  }
  function setMode(mode) {state.mode=mode;state.trace=null;if(mode==='rehearse'&&!state.selected&&model.components.length)state.selected=model.investigations[0]?.target||model.components[0].id;render();}
  function render() {
    document.querySelectorAll('[data-mode]').forEach(b=>{b.classList.toggle('active',b.dataset.mode===state.mode);b.setAttribute('aria-pressed',String(b.dataset.mode===state.mode));});
    renderLenses();
    $('obs-isolate').setAttribute('aria-pressed',String(state.isolate));
    $('obs-stage-title').textContent=state.mode==='rehearse'?'Change one thing. Trace the consequences.':state.mode==='investigate'?'Follow the evidence into the system.':'See the system. Find your bearings.';
    $('obs-stage-description').textContent=state.mode==='rehearse'?'A bounded rehearsal, with uncertainty in the open.':state.mode==='investigate'?'Select a lens. Inspect the signals. Challenge the hypothesis.':'Follow the boundaries, then pull a component apart.';
    tree();renderMap();inspect();
  }
  document.querySelectorAll('[data-mode]').forEach(b=>b.addEventListener('click',()=>setMode(b.dataset.mode)));
  $('obs-search').addEventListener('input',e=>{state.query=e.target.value;tree();renderMap();});
  $('obs-isolate').addEventListener('click',()=>{if(!state.selected){announce('Select a component first.');return;}state.isolate=!state.isolate;render();});
  $('obs-reset').addEventListener('click',()=>{Object.assign(state,{selected:null,file:null,query:'',trace:null,layerFocus:null,isolate:false,zoom:1,pan:{x:0,y:0},spread:55});$('obs-search').value='';$('obs-spread').value=55;render();});
  $('obs-spread').addEventListener('input',e=>{state.spread=Number(e.target.value);renderMap();});
  $('obs-zoom-in').addEventListener('click',()=>{state.zoom=Math.min(2.5,state.zoom*1.2);applyPan();});
  $('obs-zoom-out').addEventListener('click',()=>{state.zoom=Math.max(.5,state.zoom/1.2);applyPan();});
  let drag=null;
  $('obs-atlas').addEventListener('pointerdown',e=>{if(e.target.closest('[role=button]'))return;drag={x:e.clientX,y:e.clientY};$('obs-atlas').setPointerCapture(e.pointerId);});
  $('obs-atlas').addEventListener('pointermove',e=>{if(!drag)return;const s=$('obs-atlas').viewBox.baseVal.width/$('obs-atlas').clientWidth;state.pan.x+=(e.clientX-drag.x)*s;state.pan.y+=(e.clientY-drag.y)*s;drag={x:e.clientX,y:e.clientY};applyPan();});
  for(const event of ['pointerup','pointercancel'])$('obs-atlas').addEventListener(event,()=>drag=null);
  document.addEventListener('keydown',e=>{if(e.key==='/'&&!['INPUT','TEXTAREA'].includes(e.target.tagName)&&!document.querySelector('dialog[open]')){e.preventDefault();$('obs-search').focus();}});

  // Time is commit activity over CURRENT topology, never fabricated old architecture.
  $('obs-time-range').max=model.timeline.length;$('obs-time-range').value=model.timeline.length;
  model.timeline.forEach(commit=>{const bar=el('i','');bar.style.height=(5+Math.min(26,Math.sqrt(commit.files.length)*4))+'px';$('obs-time-bars').append(bar);});
  function time() {
    const commit=model.timeline[state.time];
    $('obs-time-range').value=state.time;
    $('obs-time-label').textContent=commit?`${commit.date.slice(0,10)} / ${commit.hash.slice(0,7)}`:'Current worktree';
    $('obs-time-detail').textContent=commit?`${commit.subject} · ${commit.author} · ${commit.files.length} paths touched. Highlighted on today's topology; collapsed, deleted or unmodeled files may be absent.`:"Actual commit activity projected onto today’s architecture. This is not a reconstruction of historical topology.";
    [...$('obs-time-bars').children].forEach((b,i)=>b.classList.toggle('active',i===state.time));renderMap();
  }
  function stop(){clearInterval(timer);timer=null;$('obs-time-play').textContent='▶ Play history';}
  $('obs-time-range').addEventListener('input',e=>{stop();state.time=Number(e.target.value);time();});
  $('obs-time-now').addEventListener('click',()=>{stop();state.time=model.timeline.length;time();});
  $('obs-time-play').disabled=!model.timeline.length;
  $('obs-time-play').addEventListener('click',()=>{if(timer){stop();return;}if(state.time>=model.timeline.length)state.time=0;time();$('obs-time-play').textContent='Ⅱ Pause history';timer=setInterval(()=>{state.time++;time();if(state.time>=model.timeline.length)stop();},1000);});
  document.addEventListener('visibilitychange',()=>{if(document.hidden)stop();});
  window.addEventListener('pagehide',stop);

  model.investigations.forEach((r,i)=>{const b=button('',()=>{state.mode='investigate';select(r.target);},'obs-investigation');b.append(el('span','obs-investigation-number',String(i+1).padStart(2,'0')),el('strong','',r.title),el('small','',r.evidence));$('obs-investigations').append(b);});
  model.dimensions.forEach(d=>{const row=el('section','obs-dimension');row.append(el('h3','',d.label),el('span','obs-tag',d.state),el('p','',d.detail));$('obs-dimensions').append(row);});
  model.integrations.forEach(i=>{const row=el('div','obs-integration');row.append(el('strong','',i.id),el('span','obs-tag',i.state),el('p','',i.detail));$('obs-integrations').append(row);});
  const inventory=el('details','obs-source-inventory');inventory.append(el('summary','','Inspect dependency & workflow inventory'));
  (report.libraries||[]).forEach(lib=>{const row=el('div','obs-reference');row.append(el('code','',`${lib.name} @ ${lib.version}`),el('small','',`${lib.ecosystem} · ${lib.kind} · root manifest/lock inventory`));inventory.append(row);});
  (report.ci||[]).forEach(workflow=>{const row=el('div','obs-reference');row.append(el('code','',`.github/workflows/${workflow.file}`),el('small','',`${workflow.name} · jobs: ${workflow.jobs.join(', ')} · triggers: ${workflow.triggers.join(', ')}`));inventory.append(row);});
  if(!(report.libraries||[]).length && !(report.ci||[]).length)inventory.append(el('p','obs-muted','No supported root inventory found. This does not establish absence of dependencies or CI.'));
  $('obs-integrations').append(inventory);
  model.limits.forEach(l=>$('obs-limits').append(el('li','',l)));
  $('obs-generated').textContent=`Snapshot generated ${report.generated_at}. ${model.coverage.omitted_files} indexed files omitted from this bounded model. ${model.coverage.edges_omitted} resolved edges omitted.`;
  $('obs-health-button').addEventListener('click',()=>$('obs-evidence-dialog').showModal());
  $('obs-close-evidence').addEventListener('click',()=>$('obs-evidence-dialog').close());$('obs-close-brief').addEventListener('click',()=>$('obs-brief-dialog').close());
  $('obs-copy-brief').addEventListener('click',async()=>{try{await navigator.clipboard.writeText($('obs-brief').value);$('obs-copy-brief').textContent='Copied';}catch{$('obs-brief').select();announce('Clipboard unavailable. Select and copy the brief.');}});
  $('obs-download-brief').addEventListener('click',()=>{const url=URL.createObjectURL(new Blob([$('obs-brief').value],{type:'text/markdown'}));const a=el('a');a.href=url;a.download='observatory-investigation.md';a.click();setTimeout(()=>URL.revokeObjectURL(url),1000);});
  $('obs-send-brief').addEventListener('click',()=>{const id=root.dataset.sessionId;if(!id){announce('Download or copy the brief into your session.');return;}try{const key='beam-agent-desk-draft:'+id;const existing=sessionStorage.getItem(key)||'';sessionStorage.setItem(key,existing+(existing?'\n\n':'')+$('obs-brief').value);location.assign(root.dataset.sessionUrl);}catch{announce('Draft storage unavailable. Copy or download the brief.');}});
  $('obs-coverage').textContent=`${model.coverage.modeled_files}/${model.coverage.indexed_files} files · ${model.edges.length} static links · ${model.coverage.history_commits} sampled commits · partial model`;
  document.title=`${report.workspace_root.split('/').pop()} · Repository Observatory`;
  render();
})();
