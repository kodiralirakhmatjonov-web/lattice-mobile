import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

const worker = fs.readFileSync(new URL('../src/index.js', import.meta.url), 'utf8');
const migration = fs.readFileSync(new URL('../migrations/0028_repair_strong_city_hints.sql', import.meta.url), 'utf8');

test('hotel admin PATCH accepts city without requiring stars', () => {
  const start = worker.indexOf('async function updateHotelAdmin');
  const end = worker.indexOf('async function hotelDetail', start);
  const block = worker.slice(start, end);
  assert.match(block, /hasStars/);
  assert.match(block, /hasCity/);
  assert.match(block, /INVALID_HOTEL_CITY/);
  assert.match(block, /UPDATE hotels SET city=\?, updated_at=\?/);
});

test('import city detector understands strong Makkah and Madinah locality hints', () => {
  assert.match(worker, /ajyad\|jabal omar/);
  assert.match(worker, /abi ayoub al ansari/);
});

test('existing strong locality rows are repaired in D1', () => {
  assert.match(migration, /LIKE '%ajyad%'/);
  assert.match(migration, /LIKE '%abi ayoub al ansari%'/);
});

test('manual price can inherit provider/source identity from the locked hotel source', () => {
  assert.match(worker, /row\.price_provider \|\| row\.price_locked_provider/);
  assert.match(worker, /LEFT JOIN hotel_price_sources hps ON hps\.hotel_id=h\.id/);
});
