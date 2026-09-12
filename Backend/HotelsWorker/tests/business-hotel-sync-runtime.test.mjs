import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
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
    `${source}\nreturn { rotateBusinessHotelSyncAccess, saveBusinessHotelSyncSnapshot, publicBusinessHotelSyncFeed, businessHotelSyncStatus, applyBusinessHotelSyncUpdates };`
  );
  const api = fn(class {}, HOTEL_PRICE_TTL_MS, HOTEL_PRICE_RETRY_MS);
  return { db, env: { HOTELS_DB: bindingFor(db) }, api, sourceURL };
}

const jsonRequest = value => new Request('https://iumrah.app/test', {
  method: 'POST',
  headers: { 'content-type': 'application/json' },
  body: JSON.stringify(value)
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

  const publicResponse = await f.api.publicBusinessHotelSyncFeed(
    f.env, 'makkah', token, new URL(access.accessURL)
  );
  assert.equal(publicResponse.status, 200);
  assert.equal(publicResponse.headers.get('content-type'), 'text/html; charset=utf-8');
  assert.equal(publicResponse.headers.get('cache-control'), 'no-store, max-age=0');
  assert.equal(publicResponse.headers.get('x-iumrah-hotel-sync-release'), 'hotel-sync-reader-v2-20260912');
  const html = await publicResponse.text();
  assert.match(html, /Open exact provider price for Address Jabal Omar Makkah/);
  assert.match(html, /Machine-readable snapshot and result template/);
  assert.match(html, /iumrah-hotel-sync-release/);

  const jsonResponse = await f.api.publicBusinessHotelSyncFeed(
    f.env, 'makkah', token, new URL(`${access.accessURL}?format=json`)
  );
  assert.equal(jsonResponse.headers.get('content-type'), 'application/json; charset=utf-8');
  const feed = JSON.parse(await jsonResponse.text());
  assert.equal(feed.source, 'iumrah_business_live_app_state');
  assert.equal(feed.release, 'hotel-sync-reader-v2-20260912');
  assert.equal(feed.snapshot_id, saved.snapshotID);
  assert.equal(feed.check_in, '2026-10-01');
  assert.equal(feed.hotels.length, 1);
  assert.equal(feed.hotels[0].current_nightly_usd, 172.8);
  assert.match(feed.hotels[0].monitoring_url, /chkin=2026-10-01/);
  assert.match(feed.hotels[0].monitoring_url, /chkout=2026-10-02/);
  assert.doesNotMatch(feed.hotels[0].monitoring_url, /deep_link_value|shortlink|source_caller|af_/i);

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
  assert.equal(row.method, 'chatgpt-admin-exact-source');
});

test('hotel sync refuses a price verified on the wrong dates', async () => {
  const f = fixture();
  const user = { login: 'owner' };
  await f.api.rotateBusinessHotelSyncAccess(f.env, user, 'Makkah');
  const saved = await (await f.api.saveBusinessHotelSyncSnapshot(jsonRequest({
    version: 2, city: 'Makkah', generated_at: '2026-09-11T18:01:00Z',
    check_in: '2026-10-01', check_out: '2026-10-02', rooms: 1, adults: 2, children: 0, currency: 'USD',
    hotels: [{ hotel_id:'h1', hotel_name:'Address Jabal Omar Makkah', city:'Makkah', stars:5, current_nightly_usd:172.8, currency:'USD', catalog_status:'published', price_status:'fresh', is_manual_override:false, provider:'Expedia', source_url:f.sourceURL }]
  }), f.env, user, 'Makkah')).json();

  const wrongURL = `${f.sourceURL}&chkin=2026-10-06&chkout=2026-10-07`;
  const result = {
    schema:'iumrah.hotel-price-update.v2', version:2, snapshot_id:saved.snapshotID, city:'Makkah',
    check_in:'2026-10-01', check_out:'2026-10-02', rooms:1, adults:2, currency:'USD', checked_at:'2026-09-11T18:10:00Z',
    hotels:[{ hotel_id:'h1', status:'changed', old_nightly_usd:172.8, new_nightly_usd:150, provider:'Expedia', source_url:f.sourceURL, checked_source_url:wrongURL, check_in:'2026-10-01', check_out:'2026-10-02', rooms:1, adults:2, currency:'USD', confidence:'high' }]
  };
  const response = await (await f.api.applyBusinessHotelSyncUpdates(jsonRequest({result, hotel_ids:['h1']}), f.env, user)).json();
  assert.equal(response.appliedCount, 0);
  assert.equal(response.rejected[0].error, 'HOTEL_SYNC_CHECKED_SOURCE_DATES_MISMATCH');
  assert.equal(f.db.prepare('SELECT nightly_price_usd FROM hotel_price_cache WHERE hotel_id=?').get('h1').nightly_price_usd, 172.8);
});
