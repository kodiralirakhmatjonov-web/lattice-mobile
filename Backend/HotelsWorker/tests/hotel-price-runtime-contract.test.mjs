import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

const worker = fs.readFileSync(new URL('../src/index.js', import.meta.url), 'utf8');

test('Hotels Worker exposes manual hotel price refresh route', () => {
  assert.match(worker, /parts\[1\]\s*===\s*'price'\s*&&\s*parts\[2\]\s*===\s*'refresh'/);
  assert.match(worker, /refreshHotelPriceResponse\(env,\s*hotelID/);
});

test('Hotels Worker has scheduled price maintenance handler', () => {
  assert.match(worker, /async scheduled\(controller,\s*env,\s*ctx\)/);
  assert.match(worker, /runHotelPriceMaintenance\(env/);
  assert.match(worker, /HOTEL_PRICE_TTL_MS/);
});

test('imported WKWebView price is persisted into hotel_price_cache', () => {
  assert.match(worker, /persistImportedHotelPriceSnapshots\(env,\s*id,\s*sources\)/);
  assert.match(worker, /INSERT INTO hotel_price_cache/);
  assert.match(worker, /importedPriceAvailable/);
  assert.match(worker, /HOTEL_PRICE_REQUIRED/);
});

test('hotel list returns cached price fields to iumrah Business', () => {
  assert.match(worker, /LEFT JOIN hotel_price_cache hp ON hp\.hotel_id = h\.id/);
  assert.match(worker, /price_nightly_price_usd/);
  assert.match(worker, /price:\s*hotelPriceFromRow\(row\)/);
});

test('failed refresh preserves last known price and schedules retry', () => {
  assert.match(worker, /status=CASE WHEN hotel_price_cache\.nightly_price_usd IS NOT NULL THEN 'stale' ELSE 'failed' END/);
  assert.match(worker, /HOTEL_PRICE_RETRY_MS/);
});
