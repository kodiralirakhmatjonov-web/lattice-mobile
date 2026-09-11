import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
import * as price from '../src/hotel-price.js';
import { propertyKey, safePropertyKey } from '../src/hotel-price-source.js';

// Execute the actual Worker functions and SQL against SQLite, not text patterns.
const source = fs.readFileSync(new URL('../src/index.js', import.meta.url), 'utf8')
  .replace(/^import .*;\n/gm, '').replace('export default {', 'const workerDefault = {')
  .replace(/export class /g, 'class ');
function fixture(obtain) {
  const db = new DatabaseSync(':memory:');
  db.exec(`PRAGMA foreign_keys=ON;
    CREATE TABLE hotels(id TEXT PRIMARY KEY, status TEXT, updated_at TEXT);
    CREATE TABLE hotel_sources(id TEXT PRIMARY KEY, hotel_id TEXT REFERENCES hotels(id), provider TEXT, source_url TEXT, checked_at TEXT, canonical_url TEXT);
    INSERT INTO hotels VALUES ('h1','published','2026-01-01');
    INSERT INTO hotel_sources VALUES ('s1','h1','Booking','https://www.booking.com/hotel/sa/example.html','2026-01-01',NULL);`);
  for (const prefix of ['0020_', '0023_', '0024_', '0025_', '0033_']) {
    const dir = new URL('../migrations/', import.meta.url);
    const name = fs.readdirSync(dir).find(name => name.startsWith(prefix));
    db.exec(fs.readFileSync(new URL(name, dir), 'utf8'));
  }
  const binding = { prepare(sql) {
    let values = [];
    return { bind(...params) { values = params; return this; },
      async first() { return db.prepare(sql).get(...values) || null; },
      async all() { return { results: db.prepare(sql).all(...values) }; },
      async run() { return db.prepare(sql).run(...values); } };
  }};
  const fn = new Function('WorkflowEntrypoint', 'obtainHotelPrice', 'propertyKey', 'safePropertyKey', ...Object.keys(price), `${source}\nreturn {fetchExactHotelSourcePrice,runHotelPriceMaintenance,refreshHotelPriceResponse};`);
  const api = fn(class {}, obtain, propertyKey, safePropertyKey, ...Object.values(price));
  return { db, env: { HOTELS_DB: binding }, ...api };
}
const quote = () => ({ finalURL: 'https://www.booking.com/hotel/sa/example.html?checkin=2026-10-01&checkout=2026-10-02',
  httpStatus: 200, transport: 'browser', quote: { checkIn: '2026-10-01', checkOut: '2026-10-02', nights: 1, adults: 2, rooms: 1 },
  extracted: { amount: 450, currency: 'SAR', priceBasis: 'nightly', nightlyUSD: 120, stayTotalUSD: 120, confidence: .99, method: 'fixture' } });

test('successful refresh writes actual SQL parameters and 48h expiry; manual button bypasses fresh cache', async () => {
  let calls = 0;
  const f = fixture(async () => { calls++; return quote(); });
  await f.fetchExactHotelSourcePrice(f.env, 'h1');
  await f.fetchExactHotelSourcePrice(f.env, 'h1', { clearManualOverride: true });
  const row = f.db.prepare('SELECT * FROM hotel_price_cache').get();
  assert.equal(calls, 2);
  assert.equal(row.nightly_price_usd, 120);
  assert.equal(row.currency_original, 'SAR');
  assert.equal(Date.parse(row.expires_at) - Date.parse(row.fetched_at), price.HOTEL_PRICE_TTL_MS);
  assert.equal(f.db.prepare('SELECT COUNT(*) AS n FROM hotel_price_refresh_leases').get().n, 0);
});

test('cron skips fresh rows, refreshes expired rows, and respects error retry time', async () => {
  let calls = 0;
  const f = fixture(async () => { calls++; return quote(); });
  await f.runHotelPriceMaintenance(f.env);
  assert.equal(calls, 1);
  await f.runHotelPriceMaintenance(f.env);
  assert.equal(calls, 1);
  f.db.exec("UPDATE hotel_price_cache SET expires_at='2020-01-01'");
  await f.runHotelPriceMaintenance(f.env);
  assert.equal(calls, 2);
  f.db.exec("UPDATE hotel_price_cache SET status='failed',next_retry_at='2099-01-01'");
  await f.runHotelPriceMaintenance(f.env);
  assert.equal(calls, 2);
});

test('cron preserves manual override; successful button returns to source', async () => {
  const f = fixture(async () => quote());
  f.db.exec("INSERT INTO hotel_price_overrides(hotel_id,nightly_price_usd,updated_at) VALUES ('h1',150,'2020-01-01')");
  await f.runHotelPriceMaintenance(f.env);
  assert.equal(f.db.prepare('SELECT nightly_price_usd FROM hotel_price_overrides').get().nightly_price_usd, 150);
  const response = await f.refreshHotelPriceResponse(f.env, 'h1');
  const body = await response.json();
  assert.equal(body.ok, true);
  assert.equal(body.refreshed, true);
  assert.equal(body.price.nightlyUSD, 120);
  assert.equal(body.price.isManualOverride, false);
});

test('failed source preserves last price and manual override with a 6h retry; manual retry ignores backoff', async () => {
  let fail = false, calls = 0;
  const f = fixture(async () => { calls++; if (fail) throw new Error('HOTEL_PRICE_SOURCE_CHALLENGE'); return quote(); });
  await f.fetchExactHotelSourcePrice(f.env, 'h1');
  f.db.exec("INSERT INTO hotel_price_overrides(hotel_id,nightly_price_usd) VALUES ('h1',180)");
  fail = true;
  const response = await f.refreshHotelPriceResponse(f.env, 'h1');
  const body = await response.json();
  assert.equal(body.ok, false);
  assert.equal(body.refreshed, false);
  assert.equal(body.error, 'HOTEL_PRICE_SOURCE_CHALLENGE');
  assert.equal(body.price.nightlyUSD, 180);
  const row = f.db.prepare('SELECT * FROM hotel_price_cache').get();
  assert.equal(row.status, 'stale');
  assert.equal(row.nightly_price_usd, 120);
  assert.equal(Date.parse(row.next_retry_at) - Date.parse(row.last_attempt_at), price.HOTEL_PRICE_RETRY_MS);
  fail = false;
  await f.refreshHotelPriceResponse(f.env, 'h1');
  assert.equal(calls, 3);
});

test('overlapping requests use one provider call and do not mark an active job failed', async () => {
  let release, calls = 0;
  const f = fixture(async () => { calls++; await new Promise(resolve => { release = resolve; }); return quote(); });
  const first = f.fetchExactHotelSourcePrice(f.env, 'h1');
  while (!release) await new Promise(resolve => setImmediate(resolve));
  const response = await f.refreshHotelPriceResponse(f.env, 'h1');
  assert.equal(response.status, 409);
  assert.equal((await response.json()).error, 'HOTEL_PRICE_REFRESH_IN_PROGRESS');
  release();
  await first;
  assert.equal(calls, 1);
  assert.equal(f.db.prepare('SELECT status FROM hotel_price_cache').get().status, 'fresh');
});

test('manual edit during a provider read survives completion', async () => {
  const f = fixture(async () => {
    f.db.prepare('INSERT INTO hotel_price_overrides(hotel_id,nightly_price_usd,updated_at) VALUES (?,?,?)').run('h1',199,new Date(Date.now()+1000).toISOString());
    return quote();
  });
  await f.fetchExactHotelSourcePrice(f.env, 'h1', { clearManualOverride: true });
  assert.equal(f.db.prepare('SELECT nightly_price_usd FROM hotel_price_overrides').get().nightly_price_usd, 199);
});

test('missing locks are repaired and existing locks are preserved by migration', () => {
  const f = fixture(async () => quote());
  f.db.exec("INSERT INTO hotels VALUES('h2','published','2026-01-01'); INSERT INTO hotel_sources VALUES('s2','h2','Expedia','https://www.expedia.com/A.h2.Hotel-Information','2026-01-01',NULL)");
  f.db.exec(fs.readFileSync(new URL('../migrations/0033_hotel_price_refresh_leases.sql', import.meta.url),'utf8'));
  assert.equal(f.db.prepare('SELECT source_id FROM hotel_price_sources WHERE hotel_id=?').get('h2').source_id, 's2');
  assert.equal(f.db.prepare('SELECT source_id FROM hotel_price_sources WHERE hotel_id=?').get('h1').source_id, 's1');
});


test('Expedia v2 migration prefers Expedia and makes the preserved price due immediately', () => {
  const f = fixture(async () => quote());
  f.db.exec(`
    INSERT INTO hotel_sources(id,hotel_id,provider,source_url,checked_at,canonical_url)
    VALUES('e1','h1','Expedia','https://www.expedia.com/Medina-Hotels-Example.h1234.Hotel-Information','2026-09-10','https://www.expedia.com/Medina-Hotels-Example.h1234.Hotel-Information');
    INSERT INTO hotel_price_cache(hotel_id,provider,source_url,nightly_price_usd,status,fetched_at,expires_at)
    VALUES('h1','Booking','https://www.booking.com/hotel/sa/example.html',154,'fresh','2026-09-05T10:00:00Z','2099-01-01T00:00:00Z')
    ON CONFLICT(hotel_id) DO UPDATE SET provider=excluded.provider,source_url=excluded.source_url,nightly_price_usd=excluded.nightly_price_usd,status=excluded.status,fetched_at=excluded.fetched_at,expires_at=excluded.expires_at;
  `);
  f.db.exec(fs.readFileSync(new URL('../migrations/0034_expedia_price_refresh_v2.sql', import.meta.url),'utf8'));
  const lock = f.db.prepare('SELECT source_id,provider,source_url FROM hotel_price_sources WHERE hotel_id=?').get('h1');
  const cache = f.db.prepare('SELECT nightly_price_usd,status,next_retry_at,error FROM hotel_price_cache WHERE hotel_id=?').get('h1');
  assert.equal(lock.source_id, 'e1');
  assert.equal(lock.provider, 'Expedia');
  assert.match(lock.source_url, /\.h1234\.Hotel-Information/);
  assert.equal(cache.nightly_price_usd, 154);
  assert.equal(cache.status, 'stale');
  assert.ok(cache.next_retry_at);
  assert.equal(cache.error, null);
});

test('large source movement requires a second matching read and leaves manual price until confirmed', async () => {
  let amount = 120;
  const f = fixture(async () => { const q = quote(); q.extracted.nightlyUSD = amount; return q; });
  await f.fetchExactHotelSourcePrice(f.env, 'h1');
  f.db.exec("INSERT INTO hotel_price_overrides(hotel_id,nightly_price_usd,updated_at) VALUES ('h1',150,'2020-01-01')");
  amount = 300;
  const first = await (await f.refreshHotelPriceResponse(f.env, 'h1')).json();
  assert.equal(first.ok, false);
  assert.equal(first.refreshed, false);
  assert.equal(first.error, 'PRICE_CHANGE_AWAITING_CONFIRMATION');
  assert.equal(first.price.nightlyUSD, 150);
  const second = await (await f.refreshHotelPriceResponse(f.env, 'h1')).json();
  assert.equal(second.ok, true);
  assert.equal(second.refreshed, true);
  assert.equal(second.changed, true);
  assert.equal(second.error, null);
  assert.equal(second.price.nightlyUSD, 300);
  assert.equal(second.price.isManualOverride, false);
});

test('hotel imported after migration is picked up by cron even before source lock exists', async () => {
  const f = fixture(async () => quote());
  f.db.exec("INSERT INTO hotels VALUES('h2','published','2026-01-01'); INSERT INTO hotel_sources VALUES('s2','h2','Booking','https://www.booking.com/hotel/sa/example.html','2026-01-01',NULL)");
  assert.equal(f.db.prepare('SELECT COUNT(*) AS n FROM hotel_price_sources WHERE hotel_id=?').get('h2').n, 0);
  await f.runHotelPriceMaintenance(f.env);
  assert.equal(f.db.prepare('SELECT nightly_price_usd FROM hotel_price_cache WHERE hotel_id=?').get('h2').nightly_price_usd, 120);
});
