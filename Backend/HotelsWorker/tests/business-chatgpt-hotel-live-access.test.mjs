import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
import { HOTEL_PRICE_TTL_MS, HOTEL_PRICE_RETRY_MS } from '../src/hotel-price.js';

const source = fs.readFileSync(new URL('../src/index.js', import.meta.url), 'utf8')
  .replace(/^import .*;\n/gm, '')
  .replace('export default {', 'const workerDefault = {')
  .replace(/export class /g, 'class ');

function bindingFor(db) {
  const wrap = sql => {
    let values = [];
    return {
      bind(...params) { values = params; return this; },
      async first() { return db.prepare(sql).get(...values) || null; },
      async all() { return { results: db.prepare(sql).all(...values) }; },
      async run() { const result = db.prepare(sql).run(...values); return { ...result, meta: { changes: Number(result.changes || 0) } }; }
    };
  };
  return {
    prepare: wrap,
    async batch(statements) {
      db.exec('BEGIN');
      try {
        const out = [];
        for (const statement of statements) out.push(await statement.run());
        db.exec('COMMIT');
        return out;
      } catch (error) {
        db.exec('ROLLBACK');
        throw error;
      }
    }
  };
}

function fixture() {
  const db = new DatabaseSync(':memory:');
  db.exec('PRAGMA foreign_keys=ON');
  const dir = new URL('../migrations/', import.meta.url);
  for (const name of fs.readdirSync(dir).filter(name => name.endsWith('.sql')).sort()) {
    db.exec(fs.readFileSync(new URL(name, dir), 'utf8'));
  }

  const now = '2026-09-23T07:00:00.000Z';
  const rows = [
    ['h1','address-jabal-omar','Address Jabal Omar Makkah','Makkah',5,'Expedia','https://www.expedia.sa/en/Makkah-Hotels-Address-Jabal-Omar-Makkah.h89778443.Hotel-Information?expediaPropertyId=89778443',172.8],
    ['h2','anwar-al-madinah','Anwar Al Madinah Mövenpick','Madinah',5,'Expedia','https://www.expedia.sa/en/Madinah-Hotels-Anwar-Al-Madinah-Movenpick-Hotel.h2770302.Hotel-Information?expediaPropertyId=2770302',256.73]
  ];
  for (const [id,slug,name,city,stars,provider,url,price] of rows) {
    db.prepare(`INSERT INTO hotels(id,slug,name,city,stars,status,created_at,updated_at) VALUES(?,?,?,?,?,'published',?,?)`).run(id,slug,name,city,stars,now,now);
    db.prepare(`INSERT INTO hotel_sources(id,hotel_id,provider,source_url,checked_at) VALUES(?,?,?,?,?)`).run(`s-${id}`,id,provider,url,now);
    db.prepare(`INSERT INTO hotel_price_sources(hotel_id,source_id,provider,source_url,locked_at,updated_at) VALUES(?,?,?,?,?,?)`).run(id,`s-${id}`,provider,url,now,now);
    db.prepare(`INSERT INTO hotel_price_cache(hotel_id,source_id,provider,source_url,amount_original,currency_original,price_basis,nightly_price_usd,quote_total_usd,confidence,method,status,fetched_at,expires_at,last_attempt_at,created_at,updated_at)
                VALUES(?,?,?,?,?,'USD','nightly',?,?,0.99,'fixture','fresh',?,?,?,?,?)`)
      .run(id,`s-${id}`,provider,url,price,price,price,now,'2099-01-01T00:00:00Z',now,now,now);
  }

  const fn = new Function(
    'WorkflowEntrypoint','HOTEL_PRICE_TTL_MS','HOTEL_PRICE_RETRY_MS',
    `${source}\nreturn { businessChatGPTHotelAccessStatus, setBusinessChatGPTHotelAccess, publicBusinessChatGPTHotelFeed, businessChatGPTHotelFeedPayload, businessChatGPTHotelMCP, businessChatGPTHotelOAuthWellKnown, businessChatGPTHotelOAuth, businessChatGPTIssueOAuthTokens, applyBusinessChatGPTHotelUpdates };`
  );
  const api = fn(class {}, HOTEL_PRICE_TTL_MS, HOTEL_PRICE_RETRY_MS);
  return { db, env: { HOTELS_DB: bindingFor(db) }, api, now, rows };
}

function postJSON(url, value, token = null) {
  const headers = { 'content-type':'application/json' };
  if (token) headers.authorization = `Bearer ${token}`;
  return new Request(url, { method: 'POST', headers, body: JSON.stringify(value) });
}

const user = { login: 'owner', role: 'superadmin' };

test('ChatGPT hotel access is off by default and opens/closes manually with no token or snapshot', async () => {
  const f = fixture();
  let status = await (await f.api.businessChatGPTHotelAccessStatus(f.env)).json();
  assert.equal(status.enabled, false);
  assert.equal(status.hotelCount, 2);

  let response = await f.api.publicBusinessChatGPTHotelFeed(f.env, new URL('https://iumrah.app/api/catalog/hotels/chatgpt-hotels'));
  assert.equal(response.status, 403);

  status = await (await f.api.setBusinessChatGPTHotelAccess(f.env, user, true)).json();
  assert.equal(status.enabled, true);
  assert.equal(status.makkahCount, 1);
  assert.equal(status.madinahCount, 1);

  response = await f.api.publicBusinessChatGPTHotelFeed(f.env, new URL('https://iumrah.app/api/catalog/hotels/chatgpt-hotels'));
  assert.equal(response.status, 200);
  const feed = await response.json();
  assert.equal(feed.schema, 'iumrah.business-hotels.live.v1');
  assert.equal(feed.live, true);
  assert.equal(feed.snapshot_id, null);
  assert.equal(feed.date_gate, false);
  assert.equal(feed.expires_at, null);
  assert.equal(feed.hotel_count, 2);
  assert.equal(feed.monitoring_rules.result_schema, 'iumrah.hotel-price-update.v3');
  assert.equal('check_in' in feed, false);
  assert.equal('check_out' in feed, false);

  status = await (await f.api.setBusinessChatGPTHotelAccess(f.env, user, false)).json();
  assert.equal(status.enabled, false);
  response = await f.api.publicBusinessChatGPTHotelFeed(f.env, new URL('https://iumrah.app/api/catalog/hotels/chatgpt-hotels'));
  assert.equal(response.status, 403);
});

test('MCP exposes live database tools and reads both cities without snapshot/date gating', async () => {
  const f = fixture();
  await f.api.setBusinessChatGPTHotelAccess(f.env, user, true);

  const metadata = await f.api.businessChatGPTHotelOAuthWellKnown(new Request('https://iumrah.app/.well-known/oauth-authorization-server'), f.env, new URL('https://iumrah.app/.well-known/oauth-authorization-server'));
  assert.equal(metadata.status, 200);
  assert.equal((await metadata.json()).authorization_endpoint, 'https://iumrah.app/api/catalog/hotels/chatgpt-mcp/oauth/authorize');

  const tokenPayload = await f.api.businessChatGPTIssueOAuthTokens(f.env, {
    clientID:'https://chatgpt.com/oauth/client.json',
    resource:'https://iumrah.app/api/catalog/hotels/chatgpt-mcp',
    scopes:['hotels.read','offline_access']
  });
  const token = tokenPayload.access_token;

  const init = await f.api.businessChatGPTHotelMCP(postJSON('https://iumrah.app/api/catalog/hotels/chatgpt-mcp', {
    jsonrpc:'2.0', id:1, method:'initialize', params:{ protocolVersion:'2025-06-18', capabilities:{}, clientInfo:{name:'test',version:'1'} }
  }, token), f.env);
  assert.equal(init.status, 200);
  assert.equal((await init.json()).result.serverInfo.name, 'Iumrah Business Hotels');

  const list = await f.api.businessChatGPTHotelMCP(postJSON('https://iumrah.app/api/catalog/hotels/chatgpt-mcp', {
    jsonrpc:'2.0', id:2, method:'tools/list', params:{}
  }, token), f.env);
  const tools = (await list.json()).result.tools;
  assert.deepEqual(tools.map(x => x.name), ['list_internal_hotel_databases','search_internal_hotels','get_internal_hotel','export_internal_hotel_prices']);
  assert.ok(tools.every(x => x.annotations.readOnlyHint === true));
  assert.ok(tools.every(x => x.securitySchemes[0].type === 'oauth2'));
  assert.ok(tools.every(x => x.securitySchemes[0].scopes.includes('hotels.read')));

  const search = await f.api.businessChatGPTHotelMCP(postJSON('https://iumrah.app/api/catalog/hotels/chatgpt-mcp', {
    jsonrpc:'2.0', id:3, method:'tools/call', params:{ name:'search_internal_hotels', arguments:{ city:'Madinah', has_price:true } }
  }, token), f.env);
  const result = (await search.json()).result.structuredContent;
  assert.equal(result.count, 1);
  assert.equal(result.hotels[0].hotel_id, 'h2');
  assert.equal(result.hotels[0].current_nightly_usd, 256.73);
});


test('OAuth handshake auto-grants only while manual ChatGPT access is open and supports long-lived refresh', async () => {
  const f = fixture();
  await f.api.setBusinessChatGPTHotelAccess(f.env, user, true);

  const verifier = 'iumrah-chatgpt-pkce-verifier-abcdefghijklmnopqrstuvwxyz0123456789';
  const digest = new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(verifier)));
  let binary = '';
  for (const byte of digest) binary += String.fromCharCode(byte);
  const challenge = btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/g, '');
  const authorizeURL = new URL('https://iumrah.app/api/catalog/hotels/chatgpt-mcp/oauth/authorize');
  authorizeURL.searchParams.set('response_type', 'code');
  authorizeURL.searchParams.set('client_id', 'https://chatgpt.com/oauth/client.json');
  authorizeURL.searchParams.set('redirect_uri', 'https://chatgpt.com/connector_platform_oauth_redirect');
  authorizeURL.searchParams.set('resource', 'https://iumrah.app/api/catalog/hotels/chatgpt-mcp');
  authorizeURL.searchParams.set('scope', 'hotels.read offline_access');
  authorizeURL.searchParams.set('state', 'state-1');
  authorizeURL.searchParams.set('code_challenge', challenge);
  authorizeURL.searchParams.set('code_challenge_method', 'S256');

  const authResponse = await f.api.businessChatGPTHotelOAuth(new Request(authorizeURL), f.env, authorizeURL, ['authorize']);
  assert.equal(authResponse.status, 302);
  const callback = new URL(authResponse.headers.get('location'));
  assert.equal(callback.hostname, 'chatgpt.com');
  assert.equal(callback.searchParams.get('state'), 'state-1');
  assert.ok(callback.searchParams.get('code'));

  const tokenForm = new URLSearchParams({
    grant_type: 'authorization_code',
    code: callback.searchParams.get('code'),
    client_id: 'https://chatgpt.com/oauth/client.json',
    redirect_uri: 'https://chatgpt.com/connector_platform_oauth_redirect',
    resource: 'https://iumrah.app/api/catalog/hotels/chatgpt-mcp',
    code_verifier: verifier
  });
  const tokenResponse = await f.api.businessChatGPTHotelOAuth(new Request('https://iumrah.app/api/catalog/hotels/chatgpt-mcp/oauth/token', {
    method: 'POST', headers: { 'content-type':'application/x-www-form-urlencoded' }, body: tokenForm.toString()
  }), f.env, new URL('https://iumrah.app/api/catalog/hotels/chatgpt-mcp/oauth/token'), ['token']);
  assert.equal(tokenResponse.status, 200);
  const tokens = await tokenResponse.json();
  assert.equal(tokens.token_type, 'Bearer');
  assert.ok(tokens.access_token);
  assert.ok(tokens.refresh_token);
  assert.equal(tokens.expires_in, 30 * 24 * 60 * 60);

  const refreshForm = new URLSearchParams({
    grant_type: 'refresh_token',
    refresh_token: tokens.refresh_token,
    client_id: 'https://chatgpt.com/oauth/client.json',
    resource: 'https://iumrah.app/api/catalog/hotels/chatgpt-mcp'
  });
  const refreshResponse = await f.api.businessChatGPTHotelOAuth(new Request('https://iumrah.app/api/catalog/hotels/chatgpt-mcp/oauth/token', {
    method: 'POST', headers: { 'content-type':'application/x-www-form-urlencoded' }, body: refreshForm.toString()
  }), f.env, new URL('https://iumrah.app/api/catalog/hotels/chatgpt-mcp/oauth/token'), ['token']);
  assert.equal(refreshResponse.status, 200);
  const refreshed = await refreshResponse.json();
  assert.ok(refreshed.access_token);

  await f.api.setBusinessChatGPTHotelAccess(f.env, user, false);
  const closed = await f.api.businessChatGPTHotelMCP(postJSON('https://iumrah.app/api/catalog/hotels/chatgpt-mcp', {
    jsonrpc:'2.0', id:99, method:'ping', params:{}
  }, refreshed.access_token), f.env);
  assert.equal(closed.status, 403);
});

test('v3 JSON applies without snapshot, dates, occupancy, or per-city feed state', async () => {
  const f = fixture();
  const result = {
    schema:'iumrah.hotel-price-update.v3',
    version:3,
    checked_at:'2026-09-23T07:20:00Z',
    hotels:[{
      hotel_id:'h1', hotel_name:'Address Jabal Omar Makkah', city:'Makkah', status:'changed',
      old_nightly_usd:172.8, new_nightly_usd:160,
      provider:'Expedia', source_url:f.rows[0][6], checked_source_url:`${f.rows[0][6]}&chkin=2026-10-20&chkout=2026-10-21`,
      confidence:'high', checked_at:'2026-09-23T07:20:00Z'
    }]
  };
  const response = await f.api.applyBusinessChatGPTHotelUpdates(postJSON('https://iumrah.app/test', { result, hotel_ids:['h1'] }), f.env, user);
  const body = await response.json();
  assert.equal(body.appliedCount, 1);
  assert.equal(body.rejectedCount, 0);
  const row = f.db.prepare('SELECT nightly_price_usd, method, quote_check_in, quote_check_out FROM hotel_price_cache WHERE hotel_id=?').get('h1');
  assert.equal(row.nightly_price_usd, 160);
  assert.equal(row.method, 'chatgpt-json-v3');
  assert.equal(row.quote_check_in, null);
  assert.equal(row.quote_check_out, null);
});

test('v3 JSON rejects wrong property and stale old price per hotel', async () => {
  const f = fixture();
  const wrongProperty = {
    schema:'iumrah.hotel-price-update.v3', version:3,
    hotels:[{ hotel_id:'h1', city:'Makkah', status:'changed', old_nightly_usd:172.8, new_nightly_usd:150, provider:'Expedia', source_url:f.rows[0][6], checked_source_url:'https://www.expedia.sa/en/Makkah-Hotels-Other.h111111.Hotel-Information?expediaPropertyId=111111', confidence:'high' }]
  };
  let body = await (await f.api.applyBusinessChatGPTHotelUpdates(postJSON('https://iumrah.app/test', { result:wrongProperty, hotel_ids:['h1'] }), f.env, user)).json();
  assert.equal(body.appliedCount, 0);
  assert.equal(body.rejected[0].error, 'CHATGPT_HOTEL_PROPERTY_MISMATCH');

  f.db.prepare('UPDATE hotel_price_cache SET nightly_price_usd=180 WHERE hotel_id=?').run('h1');
  const stale = {
    schema:'iumrah.hotel-price-update.v3', version:3,
    hotels:[{ hotel_id:'h1', city:'Makkah', status:'changed', old_nightly_usd:172.8, new_nightly_usd:150, provider:'Expedia', source_url:f.rows[0][6], checked_source_url:f.rows[0][6], confidence:'high' }]
  };
  body = await (await f.api.applyBusinessChatGPTHotelUpdates(postJSON('https://iumrah.app/test', { result:stale, hotel_ids:['h1'] }), f.env, user)).json();
  assert.equal(body.appliedCount, 0);
  assert.equal(body.rejected[0].error, 'CHATGPT_HOTEL_PRICE_ALREADY_CHANGED');
});
