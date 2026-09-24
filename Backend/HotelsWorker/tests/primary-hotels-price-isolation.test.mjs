import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
import { HOTEL_PRICE_TTL_MS, HOTEL_PRICE_RETRY_MS } from '../src/hotel-price.js';

const source = fs.readFileSync(new URL('../src/index.js', import.meta.url), 'utf8')
  .replace(/^import .*;\n/gm, '')
  .replace('export default {', 'const workerDefault = {')
  .replace(/export class /g, 'class ');
const primaryView = fs.readFileSync(new URL('../../../Sources/Views/PrimaryHotelsView.swift', import.meta.url), 'utf8');
const syncView = fs.readFileSync(new URL('../../../Sources/Views/HotelPriceMonitoringView.swift', import.meta.url), 'utf8');
const syncAPI = fs.readFileSync(new URL('../../../Sources/Networking/APIClient+HotelSync.swift', import.meta.url), 'utf8');

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
  const now = '2026-09-24T10:00:00.000Z';
  const rows = [
    ['p1','primary-makkah','Primary Makkah','Makkah',5,'Expedia','https://www.expedia.sa/en/Makkah-Hotels-Primary.h111111.Hotel-Information?expediaPropertyId=111111',300],
    ['n1','normal-makkah','Normal Makkah','Makkah',4,'Expedia','https://www.expedia.sa/en/Makkah-Hotels-Normal.h222222.Hotel-Information?expediaPropertyId=222222',140],
    ['n2','normal-madinah','Normal Madinah','Madinah',4,'Booking','https://www.booking.com/hotel/sa/normal-madinah.html',110]
  ];
  for (const [id,slug,name,city,stars,provider,url,price] of rows) {
    db.prepare(`INSERT INTO hotels(id,slug,name,city,stars,status,lifecycle_state,created_at,updated_at) VALUES(?,?,?,?,?,'published','published',?,?)`).run(id,slug,name,city,stars,now,now);
    db.prepare(`INSERT INTO hotel_sources(id,hotel_id,provider,source_url,checked_at) VALUES(?,?,?,?,?)`).run(`s-${id}`,id,provider,url,now);
    db.prepare(`INSERT INTO hotel_price_sources(hotel_id,source_id,provider,source_url,locked_at,updated_at) VALUES(?,?,?,?,?,?)`).run(id,`s-${id}`,provider,url,now,now);
    db.prepare(`INSERT INTO hotel_price_cache(hotel_id,source_id,provider,source_url,amount_original,currency_original,price_basis,nightly_price_usd,quote_total_usd,confidence,method,status,fetched_at,expires_at,last_attempt_at,created_at,updated_at)
                VALUES(?,?,?,?,?,'USD','nightly',?,?,0.99,'fixture','fresh',?,?,?,?,?)`)
      .run(id,`s-${id}`,provider,url,price,price,price,now,'2099-01-01T00:00:00Z',now,now,now);
  }
  db.prepare(`INSERT INTO primary_hotels(city,star_category,position,hotel_id,created_at,updated_at) VALUES('Makkah',5,1,'p1',?,?)`).run(now,now);

  const fn = new Function(
    'WorkflowEntrypoint','HOTEL_PRICE_TTL_MS','HOTEL_PRICE_RETRY_MS',
    `${source}\nreturn { businessChatGPTHotelRows, businessHotelSyncLiveHotels, applyBusinessChatGPTHotelUpdates, publicPrimaryHotels, adminPrimaryHotels, fetchExactHotelSourcePrice, persistImportedHotelPriceSnapshots };`
  );
  const api = fn(class {}, HOTEL_PRICE_TTL_MS, HOTEL_PRICE_RETRY_MS);
  return { db, env:{ HOTELS_DB: bindingFor(db) }, api, rows, now };
}

function postJSON(value) {
  return new Request('https://iumrah.app/test', { method:'POST', headers:{'content-type':'application/json'}, body:JSON.stringify(value) });
}

const user = { login:'owner', role:'superadmin' };

test('Primary Hotels are excluded from ChatGPT and legacy bulk monitoring feeds', async () => {
  const f = fixture();
  const rows = await f.api.businessChatGPTHotelRows(f.env);
  assert.deepEqual(rows.map(x => x.hotel_id).sort(), ['n1','n2']);

  const makkah = await f.api.businessHotelSyncLiveHotels(f.env, 'Makkah', '2026-10-10', '2026-10-11');
  assert.deepEqual(makkah.map(x => x.hotel_id), ['n1']);
});

test('Primary public/admin pricing ignores provider cache and uses only manual override', async () => {
  const f = fixture();
  let admin = await (await f.api.adminPrimaryHotels(f.env, new URL('https://iumrah.app/api/admin/hotels/operations/primary-hotels?city=Makkah'))).json();
  assert.equal(admin.manualPricingOnly, true);
  assert.equal(admin.assignments.length, 1);
  assert.equal(admin.assignments[0].hotel.price, null);

  let pub = await (await f.api.publicPrimaryHotels(f.env, new URL('https://iumrah.app/api/catalog/hotels/primary?city=Makkah&stars=5'))).json();
  assert.equal(pub.manualPricingOnly, true);
  assert.equal(pub.hotels[0].price, null);

  f.db.prepare(`INSERT INTO hotel_price_overrides(hotel_id,nightly_price_usd,updated_by,created_at,updated_at) VALUES('p1',188,'owner',?,?)`).run(f.now,f.now);
  admin = await (await f.api.adminPrimaryHotels(f.env, new URL('https://iumrah.app/api/admin/hotels/operations/primary-hotels?city=Makkah'))).json();
  assert.equal(admin.assignments[0].hotel.price.nightlyUSD, 188);
  assert.equal(admin.assignments[0].hotel.price.sourceNightlyUSD, null);
  assert.equal(admin.assignments[0].hotel.price.provider, null);

  pub = await (await f.api.publicPrimaryHotels(f.env, new URL('https://iumrah.app/api/catalog/hotels/primary?city=Makkah&stars=5'))).json();
  assert.equal(pub.hotels[0].price.nightlyUSD, 188);
  assert.equal(pub.hotels[0].price.sourceNightlyUSD, null);
});

test('mass ChatGPT JSON cannot change a Primary Hotel', async () => {
  const f = fixture();
  const sourceURL = f.rows[0][6];
  const result = {
    schema:'iumrah.hotel-price-update.v3', version:3,
    hotels:[{ hotel_id:'p1', hotel_name:'Primary Makkah', city:'Makkah', status:'changed', old_nightly_usd:300, new_nightly_usd:250, provider:'Expedia', source_url:sourceURL, checked_source_url:sourceURL, confidence:'high' }]
  };
  const body = await (await f.api.applyBusinessChatGPTHotelUpdates(postJSON({result,hotel_ids:['p1']}), f.env, user)).json();
  assert.equal(body.appliedCount, 0);
  assert.equal(body.rejected[0].error, 'PRIMARY_HOTEL_MANUAL_PRICE_ONLY');
  assert.equal(f.db.prepare(`SELECT nightly_price_usd FROM hotel_price_cache WHERE hotel_id='p1'`).get().nightly_price_usd, 300);
});

test('automatic/import source price paths stop for Primary Hotels', async () => {
  const f = fixture();
  await assert.rejects(() => f.api.fetchExactHotelSourcePrice(f.env, 'p1'), /PRIMARY_HOTEL_MANUAL_PRICE_ONLY/);
  const saved = await f.api.persistImportedHotelPriceSnapshots(f.env, 'p1', [{ provider:'Expedia', sourceURL:f.rows[0][6], price:{ nightlyUSD:999, currencyOriginal:'USD' } }]);
  assert.equal(saved, false);
  assert.equal(f.db.prepare(`SELECT nightly_price_usd FROM hotel_price_cache WHERE hotel_id='p1'`).get().nightly_price_usd, 300);
});

test('Business UI makes Primary manual pricing explicit and blocks Primary JSON preview', () => {
  assert.match(primaryView, /Ручные цены Primary Hotels/);
  assert.match(primaryView, /setManualHotelPrice/);
  assert.match(primaryView, /исключены из ChatGPT/);
  assert.match(syncView, /Primary Hotels полностью исключены/);
  assert.match(syncAPI, /primaryHotelIDs: Set<String>/);
  assert.match(syncAPI, /PRIMARY_HOTEL_MANUAL_PRICE_ONLY/);

  assert.match(source, /NOT EXISTS \(SELECT 1 FROM primary_hotels p WHERE p\.hotel_id=h\.id\)/);
  assert.match(source, /hotel_id NOT IN \(SELECT hotel_id FROM primary_hotels\)/);
  assert.match(source, /manualOnlyPrice: true/);
});
