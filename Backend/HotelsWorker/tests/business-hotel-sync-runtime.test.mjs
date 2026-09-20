import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
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
      async run() { return db.prepare(sql).run(...values); }
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
  const migrations = fs.readdirSync(dir).filter(name => name.endsWith('.sql')).sort();
  for (const name of migrations) db.exec(fs.readFileSync(new URL(name, dir), 'utf8'));

  const now = '2026-09-11T18:00:00.000Z';
  db.prepare(`INSERT INTO hotels(id,slug,name,city,stars,status,created_at,updated_at) VALUES(?,?,?,?,?,'published',?,?)`)
    .run('h1','address-jabal-omar','Address Jabal Omar Makkah','Makkah',5,now,now);
  const sourceURL = 'https://www.expedia.sa/en/Makkah-Hotels-Address-Jabal-Omar-Makkah.h89778443.Hotel-Information?expediaPropertyId=89778443';
  db.prepare(`INSERT INTO hotel_sources(id,hotel_id,provider,source_url,checked_at) VALUES(?,?,?,?,?)`)
    .run('s1','h1','Expedia',sourceURL,now);
  db.prepare(`INSERT INTO hotel_price_sources(hotel_id,source_id,provider,source_url,locked_at,updated_at) VALUES(?,?,?,?,?,?)`)
    .run('h1','s1','Expedia',sourceURL,now,now);
  db.prepare(`INSERT INTO hotel_price_cache(hotel_id,source_id,provider,source_url,amount_original,currency_original,price_basis,nightly_price_usd,quote_total_usd,confidence,method,status,fetched_at,expires_at,last_attempt_at,created_at,updated_at)
              VALUES(?,?,?,?,?,'USD','nightly',?,?,0.99,'fixture','fresh',?,?,?,?,?)`)
    .run('h1','s1','Expedia',sourceURL,172.8,172.8,172.8,now,'2099-01-01T00:00:00Z',now,now,now);

  const fn = new Function(
    'WorkflowEntrypoint', 'HOTEL_PRICE_TTL_MS', 'HOTEL_PRICE_RETRY_MS',
    `${source}\nreturn { ensureBusinessHotelSyncAccess, rotateBusinessHotelSyncAccess, saveBusinessHotelSyncSnapshot, publicBusinessHotelSyncFeed, businessHotelSyncBody, businessHotelSyncStatus, applyBusinessHotelSyncUpdates };`
  );
  const api = fn(class {}, HOTEL_PRICE_TTL_MS, HOTEL_PRICE_RETRY_MS);
  return { db, env: { HOTELS_DB: bindingFor(db) }, api, sourceURL };
}

const jsonRequest = value => new Request('https://iumrah.app/test', {
  method: 'POST',
  headers: { 'content-type': 'application/json' },
  body: JSON.stringify(value)
});

test('hotel sync access is permanent, recoverable from status, and reusable for unlimited reads', async () => {
  const f = fixture();
  const user = { login: 'Owner' };

  const first = await (await f.api.ensureBusinessHotelSyncAccess(f.env, user, 'Makkah')).json();
  const second = await (await f.api.ensureBusinessHotelSyncAccess(f.env, user, 'Makkah')).json();
  assert.equal(first.accessURL, second.accessURL);
  assert.equal(second.reused, true);
  assert.equal(second.unlimitedReads, true);

  const status = await (await f.api.businessHotelSyncStatus(f.env, user, 'Makkah')).json();
  assert.equal(status.accessURL, first.accessURL);

  const saved = await f.api.saveBusinessHotelSyncSnapshot(jsonRequest({
    version: 2, city: 'Makkah', generated_at: '2026-09-16T07:00:00Z',
    check_in: '2026-10-06', check_out: '2026-10-07', rooms: 1, adults: 2, children: 0, currency: 'USD',
    hotels: [{ hotel_id:'h1', hotel_name:'Address Jabal Omar Makkah', city:'Makkah', stars:5, current_nightly_usd:172.8, currency:'USD', catalog_status:'published', price_status:'fresh', is_manual_override:false, provider:'Expedia', source_url:f.sourceURL }]
  }), f.env, user, 'Makkah');
  assert.equal(saved.status, 200);

  const token = new URL(first.accessURL).pathname.split('/').at(-1);
  for (let i = 0; i < 4; i += 1) {
    const response = await f.api.publicBusinessHotelSyncFeed(f.env, 'makkah', token);
    assert.equal(response.status, 200);
    const feed = JSON.parse(await response.text());
    assert.equal(feed.hotel_count, 1);
  }
});

test('legacy raw hotel-sync links remain valid after permanent canonical URLs are introduced', async () => {
  const f = fixture();
  const rawToken = 'legacy-hotel-sync-token-that-stays-valid-2026';
  const tokenHash = createHash('sha256').update(rawToken).digest('hex');
  const now = '2026-09-16T07:00:00.000Z';
  f.db.prepare(`
    INSERT INTO business_hotel_sync_feeds(
      owner_login, city, token_hash, enabled, snapshot_json, hotel_count,
      snapshot_id, check_in, check_out, snapshot_updated_at, created_at, updated_at
    ) VALUES(?, ?, ?, 1, ?, 1, ?, ?, ?, ?, ?, ?)
  `).run(
    'owner', 'Makkah', tokenHash,
    JSON.stringify({ version:2, snapshot_id:'legacy-snapshot', city:'Makkah', check_in:'2026-10-06', check_out:'2026-10-07', hotels:[] }),
    'legacy-snapshot', '2026-10-06', '2026-10-07', now, now, now
  );

  const legacy = await f.api.publicBusinessHotelSyncFeed(f.env, 'makkah', rawToken);
  assert.equal(legacy.status, 200);

  const status = await (await f.api.businessHotelSyncStatus(f.env, { login:'Owner' }, 'Makkah')).json();
  const canonicalToken = new URL(status.accessURL).pathname.split('/').at(-1);
  assert.equal(canonicalToken, tokenHash);
  const canonical = await f.api.publicBusinessHotelSyncFeed(f.env, 'makkah', canonicalToken);
  assert.equal(canonical.status, 200);
});

test('durable hotel sync round-trip matches Flight Sync delivery and safely applies an exact-date update', async () => {
  const f = fixture();
  const user = { login: 'Owner' };

  const access = await (await f.api.rotateBusinessHotelSyncAccess(f.env, user, 'Makkah')).json();
  assert.equal(access.ok, true);
  assert.match(access.accessURL, /^https:\/\/iumrah\.app\/api\/catalog\/hotels\/hotel-sync\/makkah\//);
  const token = access.accessURL.split('/').at(-1);

  const snapshotPayload = {
    version: 2,
    city: 'Makkah',
    generated_at: '2026-09-11T18:01:00Z',
    check_in: '2026-10-01',
    check_out: '2026-10-02',
    rooms: 1,
    adults: 2,
    children: 0,
    currency: 'USD',
    hotels: [{
      hotel_id: 'h1',
      hotel_name: 'Address Jabal Omar Makkah',
      city: 'Makkah',
      stars: 5,
      current_nightly_usd: 172.8,
      currency: 'USD',
      catalog_status: 'published',
      price_status: 'fresh',
      is_manual_override: false,
      provider: 'Expedia',
      source_url: f.sourceURL,
      last_price_fetched_at: '2026-09-11T18:00:00Z'
    }]
  };
  const saved = await (await f.api.saveBusinessHotelSyncSnapshot(jsonRequest(snapshotPayload), f.env, user, 'Makkah')).json();
  assert.equal(saved.ok, true);
  assert.equal(saved.hotelCount, 1);

  const publicResponse = await f.api.publicBusinessHotelSyncFeed(f.env, 'makkah', token);
  assert.equal(publicResponse.status, 200);
  assert.equal(publicResponse.headers.get('content-type'), 'text/plain; charset=utf-8');
  assert.equal(publicResponse.headers.get('cache-control'), 'no-store, max-age=0');
  const feed = JSON.parse(await publicResponse.text());
  assert.equal(feed.source, 'iumrah_business_live_database');

  const adminBodyResponse = await f.api.businessHotelSyncBody(f.env, user, 'Makkah');
  assert.equal(adminBodyResponse.status, 200);
  const adminFeed = JSON.parse(await adminBodyResponse.text());
  assert.equal(adminFeed.snapshot_id, saved.snapshotID);
  assert.deepEqual(adminFeed.hotels, feed.hotels);
  assert.equal(feed.snapshot_id, saved.snapshotID);
  assert.equal(feed.check_in, '2026-10-01');
  assert.equal(feed.hotels.length, 1);
  assert.equal(feed.hotels[0].current_nightly_usd, 172.8);
  assert.match(feed.hotels[0].monitoring_url, /chkin=2026-10-01/);
  assert.match(feed.hotels[0].monitoring_url, /chkout=2026-10-02/);
  assert.doesNotMatch(feed.hotels[0].monitoring_url, /deep_link_value|shortlink|source_caller|af_|startDate|endDate/i);

  const checkedURL = new URL(feed.hotels[0].monitoring_url);
  checkedURL.searchParams.set('currency', 'USD');
  const result = {
    schema: 'iumrah.hotel-price-update.v2',
    version: 2,
    snapshot_id: saved.snapshotID,
    city: 'Makkah',
    check_in: '2026-10-01',
    check_out: '2026-10-02',
    rooms: 1,
    adults: 2,
    currency: 'USD',
    checked_at: '2026-09-11T18:10:00Z',
    hotels: [{
      hotel_id: 'h1', hotel_name: 'Address Jabal Omar Makkah', status: 'changed',
      old_nightly_usd: 172.8, new_nightly_usd: 155.2,
      provider: 'Expedia', source_url: f.sourceURL,
      monitoring_url: feed.hotels[0].monitoring_url,
      checked_source_url: checkedURL.toString(),
      check_in: '2026-10-01', check_out: '2026-10-02', rooms: 1, adults: 2,
      currency: 'USD', confidence: 'high', checked_at: '2026-09-11T18:10:00Z'
    }]
  };
  const applied = await (await f.api.applyBusinessHotelSyncUpdates(jsonRequest({ result, hotel_ids: ['h1'] }), f.env, user)).json();
  assert.equal(applied.ok, true);
  assert.equal(applied.appliedCount, 1);
  assert.equal(applied.rejectedCount, 0);
  const row = f.db.prepare('SELECT nightly_price_usd, quote_check_in, quote_check_out, method FROM hotel_price_cache WHERE hotel_id=?').get('h1');
  assert.equal(row.nightly_price_usd, 155.2);
  assert.equal(row.quote_check_in, '2026-10-01');
  assert.equal(row.quote_check_out, '2026-10-02');
  assert.equal(row.method, 'chatgpt-admin-live-cas');
});

test('hotel sync accepts a verified nearby-date price for the same live property', async () => {
  const f = fixture();
  const user = { login: 'owner' };
  await f.api.rotateBusinessHotelSyncAccess(f.env, user, 'Makkah');
  const saved = await (await f.api.saveBusinessHotelSyncSnapshot(jsonRequest({
    version: 2, city: 'Makkah', generated_at: '2026-09-11T18:01:00Z',
    check_in: '2026-10-01', check_out: '2026-10-02', rooms: 1, adults: 2, children: 0, currency: 'USD',
    hotels: [{ hotel_id:'h1', hotel_name:'Address Jabal Omar Makkah', city:'Makkah', stars:5, current_nightly_usd:172.8, currency:'USD', catalog_status:'published', price_status:'fresh', is_manual_override:false, provider:'Expedia', source_url:f.sourceURL }]
  }), f.env, user, 'Makkah')).json();

  const nearbyURL = `${f.sourceURL}&chkin=2026-10-06&chkout=2026-10-07`;
  const result = {
    schema:'iumrah.hotel-price-update.v2', version:2, snapshot_id:saved.snapshotID, city:'Makkah',
    check_in:'2026-10-01', check_out:'2026-10-02', rooms:1, adults:2, currency:'USD', checked_at:'2026-09-11T18:10:00Z',
    hotels:[{ hotel_id:'h1', status:'changed', old_nightly_usd:172.8, new_nightly_usd:150, provider:'Expedia', source_url:f.sourceURL, checked_source_url:nearbyURL, check_in:'2026-10-01', check_out:'2026-10-02', rooms:1, adults:2, currency:'USD', confidence:'high' }]
  };
  const response = await (await f.api.applyBusinessHotelSyncUpdates(jsonRequest({result, hotel_ids:['h1']}), f.env, user)).json();
  assert.equal(response.appliedCount, 1);
  assert.equal(response.rejectedCount, 0);
  assert.equal(f.db.prepare('SELECT nightly_price_usd FROM hotel_price_cache WHERE hotel_id=?').get('h1').nightly_price_usd, 150);
});

test('hotel sync does not invalidate an older result only because a newer snapshot exists', async () => {
  const f = fixture();
  const user = { login: 'owner' };
  await f.api.rotateBusinessHotelSyncAccess(f.env, user, 'Makkah');
  const payload = generatedAt => ({
    version:2, city:'Makkah', generated_at:generatedAt,
    check_in:'2026-10-01', check_out:'2026-10-02', rooms:1, adults:2, children:0, currency:'USD',
    hotels:[{ hotel_id:'h1', hotel_name:'Address Jabal Omar Makkah', city:'Makkah', stars:5, current_nightly_usd:172.8, currency:'USD', catalog_status:'published', price_status:'fresh', is_manual_override:false, provider:'Expedia', source_url:f.sourceURL }]
  });
  const first = await (await f.api.saveBusinessHotelSyncSnapshot(jsonRequest(payload('2026-09-11T18:01:00Z')), f.env, user, 'Makkah')).json();
  const second = await (await f.api.saveBusinessHotelSyncSnapshot(jsonRequest(payload('2026-09-12T18:01:00Z')), f.env, user, 'Makkah')).json();
  assert.notEqual(first.snapshotID, second.snapshotID);

  const result = {
    schema:'iumrah.hotel-price-update.v2', version:2, snapshot_id:first.snapshotID, city:'Makkah',
    check_in:'2026-10-01', check_out:'2026-10-02', rooms:1, adults:2, currency:'USD', checked_at:'2026-09-12T18:10:00Z',
    hotels:[{ hotel_id:'h1', status:'changed', old_nightly_usd:172.8, new_nightly_usd:160, provider:'Expedia', source_url:f.sourceURL, checked_source_url:`${f.sourceURL}&chkin=2026-10-01&chkout=2026-10-02`, check_in:'2026-10-01', check_out:'2026-10-02', rooms:1, adults:2, currency:'USD', confidence:'high' }]
  };
  const response = await (await f.api.applyBusinessHotelSyncUpdates(jsonRequest({result, hotel_ids:['h1']}), f.env, user)).json();
  assert.equal(response.appliedCount, 1);
  assert.equal(response.rejectedCount, 0);
  assert.equal(f.db.prepare('SELECT nightly_price_usd FROM hotel_price_cache WHERE hotel_id=?').get('h1').nightly_price_usd, 160);
});

test('hotel sync rejects only the hotel whose live old price already changed', async () => {
  const f = fixture();
  const user = { login: 'owner' };
  await f.api.rotateBusinessHotelSyncAccess(f.env, user, 'Makkah');
  const saved = await (await f.api.saveBusinessHotelSyncSnapshot(jsonRequest({
    version:2, city:'Makkah', generated_at:'2026-09-11T18:01:00Z',
    check_in:'2026-10-01', check_out:'2026-10-02', rooms:1, adults:2, children:0, currency:'USD',
    hotels:[{ hotel_id:'h1', hotel_name:'Address Jabal Omar Makkah', city:'Makkah', stars:5, current_nightly_usd:172.8, currency:'USD', catalog_status:'published', price_status:'fresh', is_manual_override:false, provider:'Expedia', source_url:f.sourceURL }]
  }), f.env, user, 'Makkah')).json();
  f.db.prepare('UPDATE hotel_price_cache SET nightly_price_usd=180, quote_total_usd=180 WHERE hotel_id=?').run('h1');

  const result = {
    schema:'iumrah.hotel-price-update.v2', version:2, snapshot_id:saved.snapshotID, city:'Makkah',
    check_in:'2026-10-01', check_out:'2026-10-02', rooms:1, adults:2, currency:'USD', checked_at:'2026-09-11T18:10:00Z',
    hotels:[{ hotel_id:'h1', status:'changed', old_nightly_usd:172.8, new_nightly_usd:150, provider:'Expedia', source_url:f.sourceURL, checked_source_url:`${f.sourceURL}&chkin=2026-10-01&chkout=2026-10-02`, check_in:'2026-10-01', check_out:'2026-10-02', rooms:1, adults:2, currency:'USD', confidence:'high' }]
  };
  const response = await (await f.api.applyBusinessHotelSyncUpdates(jsonRequest({result, hotel_ids:['h1']}), f.env, user)).json();
  assert.equal(response.appliedCount, 0);
  assert.equal(response.rejected[0].error, 'HOTEL_SYNC_PRICE_ALREADY_CHANGED');
  assert.equal(f.db.prepare('SELECT nightly_price_usd FROM hotel_price_cache WHERE hotel_id=?').get('h1').nightly_price_usd, 180);
});

test('one permanent hotel-sync URL reflects live D1 price and catalog changes without a new snapshot or token', async () => {
  const f = fixture();
  const user = { login: 'owner' };
  const access = await (await f.api.ensureBusinessHotelSyncAccess(f.env, user, 'Makkah')).json();
  const token = new URL(access.accessURL).pathname.split('/').at(-1);

  const saved = await (await f.api.saveBusinessHotelSyncSnapshot(jsonRequest({
    version:2, city:'Makkah', generated_at:'2026-09-20T10:00:00Z',
    check_in:'2026-10-10', check_out:'2026-10-11', rooms:1, adults:2, children:0, currency:'USD'
  }), f.env, user, 'Makkah')).json();
  assert.equal(saved.hotelCount, 1);

  const first = JSON.parse(await (await f.api.publicBusinessHotelSyncFeed(f.env, 'makkah', token)).text());
  assert.equal(first.hotels.length, 1);
  assert.equal(first.hotels[0].current_nightly_usd, 172.8);
  assert.equal(first.unlimited_reads, true);
  assert.equal(first.expires_at, null);

  f.db.prepare('UPDATE hotel_price_cache SET nightly_price_usd=199.25, quote_total_usd=199.25, updated_at=? WHERE hotel_id=?')
    .run('2026-09-20T10:05:00Z','h1');
  const now = '2026-09-20T10:05:00Z';
  f.db.prepare(`INSERT INTO hotels(id,slug,name,city,stars,status,created_at,updated_at) VALUES(?,?,?,?,?,'published',?,?)`)
    .run('h-live','live-added','Live Added Hotel','Makkah',4,now,now);
  f.db.prepare(`INSERT INTO hotel_price_overrides(hotel_id,nightly_price_usd,updated_by,created_at,updated_at) VALUES(?,?,?,?,?)`)
    .run('h-live',88,'owner',now,now);

  const second = JSON.parse(await (await f.api.publicBusinessHotelSyncFeed(f.env, 'makkah', token)).text());
  assert.equal(second.hotels.length, 2);
  assert.equal(second.hotels.find(item => item.hotel_id === 'h1').current_nightly_usd, 199.25);
  assert.equal(second.hotels.find(item => item.hotel_id === 'h-live').current_nightly_usd, 88);

  const accessAgain = await (await f.api.ensureBusinessHotelSyncAccess(f.env, user, 'Makkah')).json();
  assert.equal(accessAgain.accessURL, access.accessURL);
});

test('hotel sync keeps hotels without a monitorable provider source instead of failing the whole city snapshot', async () => {
  const f = fixture();
  const user = { login: 'owner' };
  await f.api.rotateBusinessHotelSyncAccess(f.env, user, 'Makkah');

  const now = '2026-09-13T09:00:00.000Z';
  f.db.prepare(`INSERT INTO hotels(id,slug,name,city,stars,status,created_at,updated_at) VALUES(?,?,?,?,?,'published',?,?)`)
    .run('h2','manual-hotel','Manual Hotel Without Provider Link','Makkah',3,now,now);
  f.db.prepare(`INSERT INTO hotel_price_overrides(hotel_id,nightly_price_usd,updated_by,created_at,updated_at) VALUES(?,?,?,?,?)`)
    .run('h2',45,'owner',now,now);

  const savedResponse = await f.api.saveBusinessHotelSyncSnapshot(jsonRequest({
    version: 2,
    city: 'Makkah',
    generated_at: '2026-09-13T09:00:00Z',
    check_in: '2026-10-03',
    check_out: '2026-10-04',
    rooms: 1,
    adults: 2,
    children: 0,
    currency: 'USD',
    hotels: [
      {
        hotel_id: 'h1', hotel_name: 'Address Jabal Omar Makkah', city: 'Makkah', stars: 5,
        current_nightly_usd: 172.8, currency: 'USD', catalog_status: 'published', price_status: 'fresh',
        is_manual_override: false, provider: 'Expedia', source_url: f.sourceURL
      },
      {
        hotel_id: 'h2', hotel_name: 'Manual Hotel Without Provider Link', city: 'Makkah', stars: 3,
        current_nightly_usd: 45, currency: 'USD', catalog_status: 'published', price_status: 'fresh',
        is_manual_override: true, provider: null, source_url: null
      }
    ]
  }), f.env, user, 'Makkah');
  assert.equal(savedResponse.status, 200);
  const saved = await savedResponse.json();
  assert.equal(saved.hotelCount, 2);

  const bodyResponse = await f.api.businessHotelSyncBody(f.env, user, 'Makkah');
  const feed = JSON.parse(await bodyResponse.text());
  assert.equal(feed.hotel_count, 2);
  const manual = feed.hotels.find(item => item.hotel_id === 'h2');
  assert.equal(manual.provider, null);
  assert.equal(manual.source_url, null);
  assert.equal(manual.monitoring_url, null);
  assert.equal(manual.monitoring_status, 'unverified_source');
});
