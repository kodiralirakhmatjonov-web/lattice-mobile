import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

const worker = fs.readFileSync(new URL('../src/index.js', import.meta.url), 'utf8');
const ziyarats = fs.readFileSync(new URL('../src/ziyarats.js', import.meta.url), 'utf8');
const migration = fs.readFileSync(new URL('../migrations/0029_ziyarats.sql', import.meta.url), 'utf8');
const renderer = fs.readFileSync(new URL('../scripts/render-config.mjs', import.meta.url), 'utf8');

test('Ziyarats exposes authenticated admin and public catalog routes', () => {
  assert.match(worker, /startsWith\('\/api\/admin\/ziyarats'\)/);
  assert.match(worker, /requireStaff\(request, env\)/);
  assert.match(worker, /startsWith\('\/api\/catalog\/ziyarats'\)/);
  assert.match(ziyarats, /handleZiyaratAdmin/);
  assert.match(ziyarats, /handleZiyaratCatalog/);
});

test('Ziyarats stores exact coordinates and supports an admin-managed five-photo gallery', () => {
  assert.match(migration, /latitude REAL NOT NULL/);
  assert.match(migration, /longitude REAL NOT NULL/);
  assert.match(ziyarats, />= 5/);
  assert.match(ziyarats, /HOTELS_MEDIA\.put\(objectKey/);
  assert.match(ziyarats, /HOTELS_MEDIA\.delete/);
});

test('Quba Mosque is the first published Madinah seed with five deterministic media rows', () => {
  assert.match(migration, /'quba-mosque'/);
  assert.match(migration, /24\.43917, 39\.61722/);
  assert.match(migration, /'enter', 40/);
  const imageRows = [...migration.matchAll(/\('quba-[1-5]', 'quba-mosque'/g)];
  assert.equal(imageRows.length, 5);
});

test('Ziyarat images are optimized before R2 storage and the root ZIP deploy path seeds Quba media', () => {
  assert.match(ziyarats, /quality: 92/);
  assert.match(ziyarats, /format: 'image\/webp'/);
  assert.match(ziyarats, /fit: 'scale-down'/);
  assert.match(renderer, /seedZiyaratMedia/);
  assert.match(renderer, /wrangler', 'r2', 'object', 'put'/);
  assert.match(renderer, /Quba seed rows are not present in D1/);
});
