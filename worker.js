// QD Automatic Fire System — Cloudflare Worker + SQLite Durable Object
// One deployment per customer; all endpoints except /health require X-Network-Key.
const JSON_HEADERS = { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' };
const STATION_TTL = 300, NODE_TTL = 900, EVENT_TTL = 3600;
const BUILDING_TYPES = new Set(['RESIDENTIAL','MULTI_RESIDENTIAL','COMMERCIAL','INDUSTRIAL','INSTITUTIONAL','WILDLAND','OUTDOOR']);
const CALL_TYPES = ['AUTOMATIC_FIRE_ALARM','RESIDENTIAL_FIRE_ALARM','COMMERCIAL_FIRE_ALARM','VEHICLE_FIRE','BRUSH_FIRE'];
function compatible(building, type) {
 if(type==='AUTOMATIC_FIRE_ALARM')return !['OUTDOOR','WILDLAND'].includes(building);
 if(type==='RESIDENTIAL_FIRE_ALARM')return ['RESIDENTIAL','MULTI_RESIDENTIAL'].includes(building);
 if(type==='COMMERCIAL_FIRE_ALARM')return ['COMMERCIAL','INDUSTRIAL','INSTITUTIONAL'].includes(building);
 if(type==='VEHICLE_FIRE')return building==='OUTDOOR';
 if(type==='BRUSH_FIRE')return ['OUTDOOR','WILDLAND'].includes(building);
 return false;
}
const MAX_STATIONS = 150, MAX_NODES = 600, MAX_EVENTS_PER_POLL = 60;
const now = () => Math.floor(Date.now() / 1000);
const reply = (value, status = 200) => new Response(JSON.stringify(value), {status, headers: JSON_HEADERS});
const bad = (message, status = 400) => reply({ok:false,error:message},status);
const clean = (s, max = 100) => String(s ?? '').trim().slice(0,max);
const validId = s => /^[0-9a-f-]{36}$/i.test(s || '');
const positiveInt = (v, max = 999) => Math.max(0,Math.min(max,Number.parseInt(v,10)||0));
const safeJson = s => {try{return JSON.parse(s)}catch{return {}}};
function eq(a,b) { // fixed-work comparison for network key
  const x = new TextEncoder().encode(a), y = new TextEncoder().encode(b);
  let diff = x.length ^ y.length;
  for(let i=0;i<Math.max(x.length,y.length);i++) diff |= (x[i]||0)^(y[i]||0);
  return diff===0;
}
function coords(obj) {
  const x = Number(obj?.x), y = Number(obj?.y);
  if(!Number.isFinite(x)||!Number.isFinite(y)||Math.abs(x)>1e8||Math.abs(y)>1e8) return null;
  return {x,y};
}
function inventory(obj) {
  const out={};
  if(typeof obj === "string") obj=safeJson(obj);
  for(const type of ['ENGINE','LADDER','RESCUE','TANKER','BRUSH','AMBULANCE','COMMAND']) out[type]=positiveInt(obj?.[type],30);
  return out;
}
async function event(db,kind,target,action,data,at=now()) {
  await db.prepare('INSERT INTO events (target_kind,target_id,action,data,created_at) VALUES (?,?,?,?,?)')
    .bind(kind,target,action,JSON.stringify(data),at).run();
}
async function maintain(db,t) {
  // Opportunistic cleanup: avoids paid cron. Old records are never used for dispatch.
  await db.batch([
    db.prepare('DELETE FROM events WHERE created_at < ?').bind(t-EVENT_TTL),
    db.prepare('DELETE FROM nodes WHERE last_seen < ?').bind(t-NODE_TTL*4),
    db.prepare('DELETE FROM stations WHERE last_seen < ?').bind(t-STATION_TTL*4),
    db.prepare('DELETE FROM incidents WHERE created_at < ?').bind(t-86400*14)
  ]);
}
async function advance(db,t) {
  // Transaction-safe state changes: each transition conditional on previous status.
  const rows=(await db.prepare("SELECT * FROM incidents WHERE status='OPEN' AND created_at <= ?").bind(t-150).all()).results;
  for(const i of rows){
    if(t >= i.created_at+300){
      const result=await db.prepare("UPDATE incidents SET status='CANCELLED',updated_at=? WHERE id=? AND status='OPEN'").bind(t,i.id).run();
      if(result.meta.changes) {
        const ids=safeJson(i.notified_stations);
        for(const id of ids) await event(db,'STATION',id,'CANCEL',{incident_id:i.id,reason:'NO_ACK'},t);
      }
    } else if(t>=i.created_at+150 && !i.escalated){
      const changed=await db.prepare("UPDATE incidents SET escalated=1,updated_at=? WHERE id=? AND status='OPEN' AND escalated=0").bind(t,i.id).run();
      if(!changed.meta.changes) continue;
      const all=(await db.prepare('SELECT id,response_regions FROM stations WHERE last_seen >= ?').bind(t-STATION_TTL).all()).results;
      const notified=new Set(safeJson(i.notified_stations));
      const info=safeJson(i.payload);
      for(const s of all) if(eligible(s,info.node_region) && !notified.has(s.id)){
        await event(db,'STATION',s.id,'DISPATCH',{...info,escalated:true},t);
        notified.add(s.id);
      }
      await db.prepare('UPDATE incidents SET notified_stations=? WHERE id=?').bind(JSON.stringify([...notified]),i.id).run();
    }
  }
}
function eligible(station, region) {
  const coverage=String(station.response_regions||'ALL');
  return coverage==='ALL' || coverage.split(',').map(x=>x.trim()).includes(region);
}
function distance(a,b){return Math.hypot(a.x-b.x,a.y-b.y)}
function withinPropagationRadius(a,b){return distance(a,b)<=7 && a.id!==b.id;}
function selectStations(stations,point,minStations,needs){
  // Greedy nearest-first with capability-aware supplement. Static inventory only.
  const sorted=stations.map(s=>({...s,inventory:safeJson(s.inventory),distance:distance(s,point)}))
    .sort((a,b)=>a.distance-b.distance || a.id.localeCompare(b.id));
  const selected=[], used=new Set(), remaining={...needs};
  function add(s){selected.push(s);used.add(s.id);for(const k of Object.keys(remaining))remaining[k]=Math.max(0,remaining[k]-(s.inventory[k]||0));}
  for(const s of sorted){if(selected.length>=minStations)break;add(s)}
  while(Object.values(remaining).some(n=>n>0)){
    const options=sorted.filter(s=>!used.has(s.id));
    options.sort((a,b)=>{
      const ca=Object.keys(remaining).reduce((v,k)=>v+Math.min(remaining[k],a.inventory[k]||0),0);
      const cb=Object.keys(remaining).reduce((v,k)=>v+Math.min(remaining[k],b.inventory[k]||0),0);
      return cb-ca || a.distance-b.distance;
    });
    if(!options.length || !Object.keys(remaining).some(k=>(options[0].inventory[k]||0)>0 && remaining[k]>0))break;
    add(options[0]);
  }
  return {selected,missing:remaining};
}
const dispatchHandler = {
 async fetch(request,env){
  const url=new URL(request.url), path=url.pathname;
  if(path==='/health')return reply({ok:true,service:'QD Automatic Fire System',version:'3.0'});
  if(!env.NETWORK_KEY || !env.DB) return bad('Server not configured',503);
  if(!eq(request.headers.get('X-Network-Key')||'',env.NETWORK_KEY))return bad('Unauthorized',401);
  // Community names are labels, not security credentials. The network key isolates deployments.
  const db=env.DB, t=now();
  try {
   if(path==='/status' && request.method==='GET'){
    const stations=await db.prepare('SELECT COUNT(*) n FROM stations WHERE last_seen>=?').bind(t-STATION_TTL).first();
    const nodes=await db.prepare('SELECT COUNT(*) n FROM nodes WHERE last_seen>=?').bind(t-NODE_TTL).first();
    const open=await db.prepare("SELECT COUNT(*) n FROM incidents WHERE status='OPEN'").first();
    return reply({ok:true,stations:stations.n,nodes:nodes.n,open:open.n});
   }
   if(path==='/stations' && request.method==='GET'){
    const rows=(await db.prepare('SELECT id,name,region,x,y,inventory,response_regions FROM stations WHERE last_seen>=?').bind(t-STATION_TTL).all()).results;
    return reply({ok:true,stations:rows.map(s=>({...s,inventory:safeJson(s.inventory)}))});
   }
   if(path==='/nodes' && request.method==='GET'){
    const rows=(await db.prepare('SELECT id,name,region,x,y,building_type FROM nodes WHERE last_seen>=? LIMIT 600').bind(t-NODE_TTL).all()).results;
    return reply({ok:true,nodes:rows});
   }
   if(path==='/poll' && request.method==='GET'){
    const kind=clean(url.searchParams.get('kind'),10).toUpperCase(), id=clean(url.searchParams.get('id'),100);
    const since=positiveInt(url.searchParams.get('since'),2147483647);
    if(!['STATION','REGION','NODE'].includes(kind) || !id)return bad('Invalid poll target');
    // Clients can recover a cursor by starting from 0; only recent events are returned.
    const rows=(await db.prepare('SELECT id,action,data,created_at FROM events WHERE target_kind=? AND target_id=? AND id>? AND created_at>=? ORDER BY id ASC LIMIT ?')
      .bind(kind,id,since,t-EVENT_TTL,MAX_EVENTS_PER_POLL).all()).results;
    return reply({ok:true,events:rows.map(e=>({id:e.id,action:e.action,data:safeJson(e.data),created_at:e.created_at})),cursor:rows.length?rows[rows.length-1].id:since,server_time:t});
   }
   if(request.method!=='POST')return bad('Not found',404);
   if(Number(request.headers.get('content-length')||0)>16000)return bad('Payload too large',413);
   let body;try{body=await request.json()}catch{return bad('Invalid JSON')}
   if(path==='/station/register'){
    const id=clean(body.id,36), name=clean(body.name,80),region=clean(body.region,80),point=coords(body);
    const coverage=clean(body.response_regions||'ALL',500);
    if(!validId(id)||!name||!region||!point)return bad('Invalid station');
    const count=await db.prepare('SELECT COUNT(*) n FROM stations').first();
    if(count.n>=MAX_STATIONS && !(await db.prepare('SELECT id FROM stations WHERE id=?').bind(id).first()))return bad('Station limit reached',429);
    await db.prepare('INSERT INTO stations(id,name,region,x,y,inventory,response_regions,last_seen) VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET name=excluded.name,region=excluded.region,x=excluded.x,y=excluded.y,inventory=excluded.inventory,response_regions=excluded.response_regions,last_seen=excluded.last_seen')
      .bind(id,name,region,point.x,point.y,JSON.stringify(inventory(body.inventory)),coverage,t).run();
    return reply({ok:true,station_id:id});
   }
   if(path==='/nodes/batch'){
    if(typeof body.nodes==='string')body.nodes=safeJson(body.nodes);
    if(!Array.isArray(body.nodes)||body.nodes.length<1||body.nodes.length>25)return bad('Batch must contain 1–25 nodes');
    const statements=[];
    for(let raw of body.nodes){
      if(typeof raw==='string')raw=safeJson(raw);
      const id=clean(raw.id,36),name=clean(raw.name,80),region=clean(raw.region,80),point=coords(raw),building=clean(raw.building_type||'RESIDENTIAL',40).toUpperCase();
      if(!validId(id)||!name||!region||!point||!BUILDING_TYPES.has(building))return bad('Invalid node in batch');
      statements.push(db.prepare('INSERT INTO nodes(id,name,region,x,y,address_sound,address_duration,last_seen,building_type) VALUES(?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET name=excluded.name,region=excluded.region,x=excluded.x,y=excluded.y,address_sound=excluded.address_sound,address_duration=excluded.address_duration,last_seen=excluded.last_seen,building_type=excluded.building_type')
       .bind(id,name,region,point.x,point.y,clean(raw.address_sound,36),Math.max(0,Math.min(10,Number(raw.address_duration)||0)),t,building));
    }
    await db.batch(statements);
    return reply({ok:true,registered:statements.length});
   }
   if(path==='/node/register'){
    const id=clean(body.id,36),name=clean(body.name,80),region=clean(body.region,80),point=coords(body),building=clean(body.building_type||'RESIDENTIAL',40).toUpperCase();
    if(!validId(id)||!name||!region||!point||!BUILDING_TYPES.has(building))return bad('Invalid node');
    const count=await db.prepare('SELECT COUNT(*) n FROM nodes').first();
    if(count.n>=MAX_NODES && !(await db.prepare('SELECT id FROM nodes WHERE id=?').bind(id).first()))return bad('Node limit reached',429);
    await db.prepare('INSERT INTO nodes(id,name,region,x,y,address_sound,address_duration,last_seen,building_type) VALUES(?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET name=excluded.name,region=excluded.region,x=excluded.x,y=excluded.y,address_sound=excluded.address_sound,address_duration=excluded.address_duration,last_seen=excluded.last_seen,building_type=excluded.building_type')
      .bind(id,name,region,point.x,point.y,clean(body.address_sound,36),Math.max(0,Math.min(10,Number(body.address_duration)||0)),t,building).run();
    return reply({ok:true,node_id:id});
   }
   if(path==='/incident/create'){
    const nodeId=clean(body.node_id,36),type=clean(body.type,60).toUpperCase();
    if(!validId(nodeId)||!CALL_TYPES.includes(type))return bad('Invalid incident');
    const node=await db.prepare('SELECT * FROM nodes WHERE id=? AND last_seen>=?').bind(nodeId,t-NODE_TTL).first();
    if(!node)return bad('Node unavailable',404);
    if(!compatible(node.building_type||'RESIDENTIAL',type))return bad('Call type incompatible with building',409);
    const active=await db.prepare("SELECT id FROM incidents WHERE status='OPEN' LIMIT 1").first();
    if(active)return bad('Another incident is already open',409);
    const all=(await db.prepare('SELECT * FROM stations WHERE last_seen>=?').bind(t-STATION_TTL).all()).results.filter(s=>eligible(s,node.region));
    if(!all.length)return bad('No online stations',409);
    const minStations=Math.max(1,positiveInt(body.min_stations,20));
    const needs=inventory(body.requirements);
    const {selected,missing}=selectStations(all,node,minStations,needs);
    const incidentId=crypto.randomUUID(), ids=selected.map(s=>s.id);
    const info={incident_id:incidentId,node_id:node.id,node_name:node.name,node_region:node.region,
      type,building_type:node.building_type,address_sound:node.address_sound,address_duration:node.address_duration,
      created_at:t,escalated:false,missing_apparatus:missing};
    await db.prepare('INSERT INTO incidents(id,node_id,type,status,created_at,updated_at,escalated,notified_stations,payload) VALUES(?,?,?,?,?,?,?,?,?)')
      .bind(incidentId,node.id,type,'OPEN',t,t,0,JSON.stringify(ids),JSON.stringify(info)).run();
    for(const id of ids)await event(db,'STATION',id,'DISPATCH',info,t);
    return reply({ok:true,incident_id:incidentId,stations:ids,missing_apparatus:missing,created_at:t});
   }
   if(path==='/incident/ack'){
    const id=clean(body.incident_id,36),stationId=clean(body.station_id,36);
    const incident=await db.prepare('SELECT * FROM incidents WHERE id=?').bind(id).first();
    if(!incident)return bad('Incident not found',404);
    if(incident.status!=='OPEN')return bad('Incident already resolved',409);
    if(t>=incident.created_at+300)return bad('Incident expired',409);
    if(!safeJson(incident.notified_stations).includes(stationId))return bad('Station not dispatched',403);
    const station=await db.prepare('SELECT id FROM stations WHERE id=? AND last_seen>=?').bind(stationId,t-STATION_TTL).first();
    if(!station)return bad('Station offline',409);
    const updated=await db.prepare("UPDATE incidents SET status='ACKED',ack_station=?,updated_at=? WHERE id=? AND status='OPEN'").bind(stationId,t,id).run();
    if(!updated.meta.changes)return bad('Already acknowledged',409);
    await event(db,'REGION',(await db.prepare('SELECT region FROM nodes WHERE id=?').bind(incident.node_id).first()).region,'SPAWN',safeJson(incident.payload),t);
    await event(db,'NODE',incident.node_id,'SPAWN',safeJson(incident.payload),t);
    for(const sid of safeJson(incident.notified_stations))await event(db,'STATION',sid,'ACKED',{incident_id:id,station_id:stationId},t);
    return reply({ok:true,incident_id:id});
   }
   if(path==='/incident/outcome'){
    const id=clean(body.incident_id,36),nodeId=clean(body.node_id,36);
    const outcome=clean(body.outcome,20).toUpperCase();
    if(!['FALSE_ALARM','SMALL','MEDIUM','LARGE'].includes(outcome))return bad('Invalid outcome');
    const incident=await db.prepare('SELECT * FROM incidents WHERE id=? AND node_id=?').bind(id,nodeId).first();
    if(!incident)return bad('Incident not found',404);
    if(incident.status==='RESOLVED')return reply({ok:true,duplicate:true});
    if(incident.status!=='ACKED')return bad('Incident not acknowledged',409);
    const updated=await db.prepare("UPDATE incidents SET status='RESOLVED',updated_at=?,outcome=? WHERE id=? AND node_id=? AND status='ACKED'")
      .bind(t,outcome,id,nodeId).run();
    if(!updated.meta.changes)return reply({ok:true,duplicate:true});
    if(outcome==='LARGE'){
      const origin=await db.prepare('SELECT x,y FROM nodes WHERE id=?').bind(nodeId).first();
      if(origin){
       const nearby=(await db.prepare('SELECT id,region FROM nodes WHERE id<>? AND last_seen>=? AND ((x-?)*(x-?)+(y-?)*(y-?))<=49')
        .bind(nodeId,t-NODE_TTL,origin.x,origin.x,origin.y,origin.y).all()).results;
       for(const n of nearby){
        const payload={incident_id:id,node_id:n.id,origin_node_id:nodeId};
        await event(db,'NODE',n.id,'LARGE_NEARBY',payload,t);
        await event(db,'REGION',n.region,'LARGE_NEARBY',payload,t);
       }
      }
    }
    return reply({ok:true,outcome});
   }
   if(path==='/incident/cancel'){
    const id=clean(body.incident_id,36);
    const i=await db.prepare('SELECT * FROM incidents WHERE id=?').bind(id).first();
    if(!i)return bad('Incident not found',404);
    const changed=await db.prepare("UPDATE incidents SET status='CANCELLED',updated_at=? WHERE id=? AND status='OPEN'").bind(t,id).run();
    if(changed.meta.changes)for(const sid of safeJson(i.notified_stations))await event(db,'STATION',sid,'CANCEL',{incident_id:id,reason:'MASTER'},t);
    return reply({ok:true,cancelled:changed.meta.changes>0});
   }
   return bad('Not found',404);
  }catch(e){console.error('Worker error',e);return bad('Server error',500)}
 }
};

// Pure helpers exported for automated tests (not HTTP endpoints).
export {selectStations, inventory, distance, eq, eligible, compatible, withinPropagationRadius};


// SQLite-backed Durable Object: Cloudflare creates the storage automatically on deploy.
// No D1 database, database ID, migrations command, or customer GitHub account needed.
class SqliteAdapter {
  constructor(sql){this.sql=sql;}
  prepare(query){return new Prepared(this.sql,query);}
  async batch(items){const out=[];for(const item of items)out.push(await item.run());return out;}
}
class Prepared {
  constructor(sql,query,args=[]){this.sql=sql;this.query=query;this.args=args;}
  bind(...args){return new Prepared(this.sql,this.query,args);}
  async all(){return {results:Array.from(this.sql.exec(this.query,...this.args))};}
  async first(){return Array.from(this.sql.exec(this.query,...this.args))[0]||null;}
  async run(){this.sql.exec(this.query,...this.args);const row=Array.from(this.sql.exec('SELECT changes() AS n'))[0];return {meta:{changes:row?.n||0}};}
}
const SCHEMA = [
 `CREATE TABLE IF NOT EXISTS stations (id TEXT PRIMARY KEY,name TEXT NOT NULL,region TEXT NOT NULL,x REAL NOT NULL,y REAL NOT NULL,inventory TEXT NOT NULL,response_regions TEXT NOT NULL DEFAULT 'ALL',last_seen INTEGER NOT NULL)`,
 `CREATE INDEX IF NOT EXISTS stations_seen ON stations(last_seen)`,
 `CREATE TABLE IF NOT EXISTS nodes (id TEXT PRIMARY KEY,name TEXT NOT NULL,region TEXT NOT NULL,x REAL NOT NULL,y REAL NOT NULL,address_sound TEXT,address_duration REAL,last_seen INTEGER NOT NULL,building_type TEXT NOT NULL DEFAULT 'RESIDENTIAL')`,
 `CREATE INDEX IF NOT EXISTS nodes_seen ON nodes(last_seen)`,
 `CREATE TABLE IF NOT EXISTS incidents (id TEXT PRIMARY KEY,node_id TEXT NOT NULL,type TEXT NOT NULL,status TEXT NOT NULL,created_at INTEGER NOT NULL,updated_at INTEGER NOT NULL,escalated INTEGER NOT NULL DEFAULT 0,notified_stations TEXT NOT NULL,payload TEXT NOT NULL,ack_station TEXT,outcome TEXT)`,
 `CREATE INDEX IF NOT EXISTS incidents_status ON incidents(status,created_at)`,
 `CREATE TABLE IF NOT EXISTS events (id INTEGER PRIMARY KEY AUTOINCREMENT,target_kind TEXT NOT NULL,target_id TEXT NOT NULL,action TEXT NOT NULL,data TEXT NOT NULL,created_at INTEGER NOT NULL)`,
 `CREATE INDEX IF NOT EXISTS events_target ON events(target_kind,target_id,id)`,
 `CREATE INDEX IF NOT EXISTS events_age ON events(created_at)`,
 `CREATE TABLE IF NOT EXISTS setup (id TEXT PRIMARY KEY,value TEXT NOT NULL)`
];
const escapeHtml=s=>String(s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const setupHtml=(inner)=>new Response(`<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>QD Automatic Fire System Setup</title><style>body{font:17px system-ui;max-width:640px;margin:50px auto;padding:18px;line-height:1.55}button{font:inherit;padding:12px 20px;cursor:pointer}code{display:block;overflow-wrap:anywhere;background:#eee;padding:14px;border-radius:8px}small{color:#555}</style><h1>QD Automatic Fire System</h1>${inner}</html>`,{headers:{'content-type':'text/html; charset=utf-8','cache-control':'no-store'}});
export class DispatchNetwork {
  constructor(state,env){
    this.state=state;this.env=env;this.db=new SqliteAdapter(state.storage.sql);
    state.blockConcurrencyWhile(async()=>{
      for(const statement of SCHEMA)state.storage.sql.exec(statement);
      if(await state.storage.getAlarm()===null)await state.storage.setAlarm(Date.now()+30000);
    });
  }
  async alarm(){
    try {await advance(this.db,now());await maintain(this.db,now());}
    finally {await this.state.storage.setAlarm(Date.now()+30000);}
  }
  async fetch(req){
    const path=new URL(req.url).pathname;
    if(path==='/health')return reply({ok:true,service:'QD Automatic Fire System',storage:'Durable Objects SQLite'});
    const stored=await this.state.storage.get('network_key');
    if(path==='/setup'){
      if(!stored)return setupHtml('<p>Welcome! This is your new private dispatch server.</p><p><strong>Click once to activate your network.</strong> Do this immediately after deploying your Worker.</p><form method="POST" action="/setup/claim"><button>Activate my dispatch network</button></form><p><small>The first visitor to activate this new server becomes its owner. Keep your URL private until activated.</small></p>');
      return setupHtml('<p>Your dispatch server is activated.</p><p>For security, the network key is only displayed when first activated. If you saved it, enter it into your Second Life configuration notecards.</p><p><a href="/health">Check server health</a></p>');
    }
    if(path==='/setup/claim'&&req.method==='POST'){
      if(stored)return setupHtml('<p>Already activated. The network key cannot be displayed again.</p>');
      const key=Array.from(crypto.getRandomValues(new Uint8Array(24)),b=>b.toString(16).padStart(2,'0')).join('');
      await this.state.storage.put('network_key',key);
      return setupHtml(`<h2>Activation successful</h2><p><strong>Copy and save this network key now.</strong> It will not be shown again.</p><code>${escapeHtml(key)}</code><p>Paste it into the NETWORK_KEY line in each Second Life configuration notecard.</p><p>Server URL: <code>${escapeHtml(new URL(req.url).origin)}</code></p><p>Do not share your key publicly.</p>`);
    }
    if(!stored)return bad('Open /setup to activate your network',503);
    return dispatchHandler.fetch(req,{DB:this.db,NETWORK_KEY:stored});
  }
}
export default {
  async fetch(req,env){
    if(!env.DISPATCH)return bad('Durable Object binding missing',503);
    const id=env.DISPATCH.idFromName('primary-network');
    return env.DISPATCH.get(id).fetch(req);
  }
};
