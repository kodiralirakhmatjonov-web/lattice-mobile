import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

const worker = fs.readFileSync(new URL('../src/index.js', import.meta.url), 'utf8');

function createImportJobBody() {
  const start = worker.indexOf('async function createImportJob');
  const end = worker.indexOf('async function', start + 30);
  assert.notEqual(start, -1);
  return worker.slice(start, end === -1 ? undefined : end);
}

test('Hotel Importer does not require an automatically extracted price to publish a complete hotel', () => {
  const body = createImportJobBody();
  assert.doesNotMatch(body, /HOTEL_PRICE_REQUIRED/);
  assert.match(body, /const importedPriceAvailable = hasImportedHotelPrice\(draft\?\.sources\)/);
  assert.match(body, /const canPublish = Boolean\(payload\.value\?\.publishWhenComplete\) && hotelLevelImages\.length > 0 && plausibleRooms\.length > 0;/);
  assert.doesNotMatch(body, /plausibleRooms\.length > 0 && importedPriceAvailable/);
});

