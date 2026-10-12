import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { createHash, webcrypto } from 'node:crypto';

const workerFile = path.resolve(import.meta.dirname, '../src/index.js');
const source = fs.readFileSync(workerFile, 'utf8');
const start = source.indexOf('const BUSINESS_FLIGHT_SYNC_VERSION = 1;');
const end = source.indexOf('const FLIGHT_DIRECTIONS = new Set(', start);
assert.ok(start >= 0 && end > start);
const fragment = source.slice(start, end);

function mockEnv() {
  const rows = new Map();
  const db = {
    prepare(sql) {
      const values = [];
      const statement = {
        bind(...args) { values.push(...args); return statement; },
        async first() {
          if (/WHERE token_hash=\? AND enabled=1/.test(sql)) {
            return [...rows.values()].find(r => r.token_hash === values[0] && r.enabled === 1) || null;
          }
          if (/WHERE owner_login=\? AND enabled=1/.test(sql)) {
            const row = rows.get(values[0]);
            return row?.enabled === 1 ? {...row} : null;
          }
          if (/WHERE owner_login=\? LIMIT 1/.test(sql)) {
            return rows.get(values[0]) || null;
          }
          throw new Error('Unknown .first query: '+sql);
        },
        async all() {
          if (/SELECT owner_login FROM business_flight_sync_feeds WHERE enabled=1/.test(sql)) {
            return {results:[...rows.values()].filter(r=>r.enabled===1).map(r=>({owner_login:r.owner_login}))};
          }
          throw new Error('Unknown .all query: '+sql);
        },
        async run() {
          if (/INSERT INTO business_flight_sync_feeds/.test(sql)) {
            const [owner,tokenHash,createdAt,updatedAt] = values;
            if (rows.has(owner)) Object.assign(rows.get(owner),{token_hash:tokenHash, enabled:1, updated_at:updatedAt});
            else rows.set(owner,{owner_login:owner,token_hash:tokenHash,enabled:1,
              snapshot_json:'{"version":1,"flights":[]}', flight_count:0, snapshot_updated_at:null,
              created_at:createdAt,updated_at:updatedAt});
            return;
          }
          if (/SET snapshot_json=\?/.test(sql)) {
            const [snapshotJSON,count,updatedAt,updatedAt2,owner] = values;
            Object.assign(rows.get(owner),{snapshot_json:snapshotJSON,flight_count:count,
              snapshot_updated_at:updatedAt,updated_at:updatedAt2});
            return;
          }
          if (/SET enabled=0/.test(sql)) {const [updatedAt,owner]=values;
            Object.assign(rows.get(owner),{enabled:0,updated_at:updatedAt});return;}
          throw new Error('Unknown .run query: '+sql);
        }
      };
      return statement;
    }
  };
  return {HOTELS_DB:db,rows};
}
function createSubject() {
  const sandbox = {
    crypto:webcrypto, TextEncoder, Response, Request, URL, console,
    validLocalDate(v) {return /^\d{4}-\d{2}-\d{2}$/.test(String(v)) ? String(v) : '';},
    cleanText(v,max=1000) {return String(v??'').trim().slice(0,max)||null;},
    businessStaffLogin(user) {return user?.owner;},
    safeHumanText(v,max=1000) {return String(v??'').trim().slice(0,max)||null;},
    randomToken() {return 'server-token-should-not-change-'+Math.random();},
    async sha256Hex(v) {return createHash('sha256').update(v).digest('hex');},
    pathParts(pathname,prefix) {const s=pathname.slice(prefix.length).replace(/^\/+|\/+$/g,'');return s?s.split('/').map(decodeURIComponent):[];},
    json(value,status=200) {return new Response(JSON.stringify(value),{status,headers:{'content-type':'application/json'}});}
  };
  vm.createContext(sandbox);
  vm.runInContext(fragment+'\nthis.subject = { rotateBusinessFlightSyncAccess, revokeBusinessFlightSyncAccess, businessFlightSyncStatus, saveBusinessFlightSyncSnapshot, publicBusinessFlightSyncStableFeed, publicBusinessFlightSyncFeed, businessFlightSyncStableURL };', sandbox);
  return sandbox.subject;
}

test('permanent public URL survives repeated provisioning and serves live saved flights on HTML and JSON URLs', async () => {
  const s=createSubject();const env=mockEnv(); const user={owner:'the-business-owner'};
  const a=await (await s.rotateBusinessFlightSyncAccess(env,user)).json();
  assert.match(a.accessURL,/^https:\/\/iumrah\.app\/flights-feed\/[a-f0-9]{64}$/);
  assert.equal(a.readOnly,true);
  const originalTokenHash=env.rows.get(user.owner).token_hash;
  const b=await (await s.rotateBusinessFlightSyncAccess(env,user)).json();
  assert.equal(b.accessURL,a.accessURL);
  assert.equal(env.rows.get(user.owner).token_hash,originalTokenHash);
  const status=await (await s.businessFlightSyncStatus(env,user)).json();
  assert.equal(status.accessURL,a.accessURL);
  const update={flights:[{
    id:'t1', comparison_key:'TAS-JED-C6321-2026-10-20', from:'TAS',to:'JED',date:'2026-10-20',
    price:{amount:400,currency:'USD'}, flight_numbers:['C6321'], airline_codes:['C6'],
    legs:[{origin:'TAS',destination:'JED',flight_number:'C6321',airline:'Centrum Air',stops:0}]
  }]};
  const snapshot=await (await s.saveBusinessFlightSyncSnapshot(new Request('https://iumrah.app',{method:'POST',body:JSON.stringify(update)}),env,user)).json();
  assert.equal(snapshot.flightCount,1);
  const html=await s.publicBusinessFlightSyncStableFeed(env,new URL(a.accessURL));
  assert.equal(html.status,200);
  assert.match(html.headers.get('content-type'),/text\/html/);
  assert.match(html.headers.get('cache-control'),/no-store/);
  assert.match(await html.text(),/TAS-JED-C6321-2026-10-20/);
  const raw=await s.publicBusinessFlightSyncStableFeed(env,new URL(a.accessURL+'.json'));
  const payload=await raw.json();
  assert.equal(payload.flight_count,1);
  assert.equal(payload.flights[0].price.amount,400);
  assert.equal(payload.read_only,true);
  const head=await s.publicBusinessFlightSyncStableFeed(env,new URL(a.accessURL),'HEAD');
  assert.equal(await head.text(),'');
  const legacyToken = 'legacy-previously-shared-readonly-token-12345';
  env.rows.get(user.owner).token_hash = createHash('sha256').update(legacyToken).digest('hex');
  const legacyHTML = await s.publicBusinessFlightSyncStableFeed(env,new URL('https://iumrah.app/flights-feed/'+legacyToken));
  assert.equal(legacyHTML.status,200);
  assert.match(await legacyHTML.text(),new RegExp(a.accessURL.replace(/\//g,'\\/')));
});

test('the permanent feed escapes HTML, isolates owners, and stops when manually revoked', async () => {
  const s=createSubject(),env=mockEnv(); const alice={owner:'alice'}, bob={owner:'bob'};
  const first=await (await s.rotateBusinessFlightSyncAccess(env,alice)).json();
  const second=await (await s.rotateBusinessFlightSyncAccess(env,bob)).json();
  const malicious='C6<script>alert(1)</script>';
  env.rows.get(alice.owner).snapshot_json=JSON.stringify({version:1,flights:[{flight_numbers:[malicious], price:{amount:20,currency:'USD'}}]});
  const html=await (await s.publicBusinessFlightSyncStableFeed(env,new URL(first.accessURL))).text();
  assert.ok(html.includes('&lt;script&gt;'));
  assert.ok(!html.includes('<script>alert(1)</script>'));
  const bobFeed=await (await s.publicBusinessFlightSyncStableFeed(env,new URL(second.accessURL+'.json'))).json();
  assert.equal(bobFeed.flight_count,0);
  await s.revokeBusinessFlightSyncAccess(env,alice);
  const revoked=await s.publicBusinessFlightSyncStableFeed(env,new URL(first.accessURL));
  assert.equal(revoked.status,404);
  const unknown=await s.publicBusinessFlightSyncStableFeed(env,new URL('https://iumrah.app/flights-feed/'+'0'.repeat(64)));
  assert.equal(unknown.status,404);
});

test('worker deployment exposes a dedicated non-API route and keeps legacy token route',()=>{
 const config=fs.readFileSync(path.resolve(import.meta.dirname,'../wrangler.template.jsonc'),'utf8');
 assert.match(config,/iumrah\.app\/flights-feed\/\*/);
 assert.match(source,/return publicBusinessFlightSyncFeed\(env, parts\[1\]\)/);
 assert.match(source,/publicBusinessFlightSyncStableFeed\(env, url, request\.method\)/);
});
