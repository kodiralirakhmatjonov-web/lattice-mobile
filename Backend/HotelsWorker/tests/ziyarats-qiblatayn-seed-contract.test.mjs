import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const workerRoot = path.resolve(here, '..');
const migration = fs.readFileSync(path.join(workerRoot, 'migrations', '0031_qiblatayn_ziyarat.sql'), 'utf8');
const indexSource = fs.readFileSync(path.join(workerRoot, 'src', 'index.js'), 'utf8');
const renderer = fs.readFileSync(path.join(workerRoot, 'scripts', 'render-config.mjs'), 'utf8');

test('Qiblatayn is seeded as Medina stop #2 with an exact coordinate', () => {
  assert.match(migration, /'qiblatayn-mosque'/);
  assert.match(migration, /24\.484087, 39\.578907/);
  assert.match(migration, /'Masjid Al-Qiblatayn · exact point', 2, 'published'/);
  assert.match(migration, /'مسجد القبلتين'/);
});

test('Qiblatayn ships five HD gallery rows and all four client locales', () => {
  for (let index = 1; index <= 5; index += 1) {
    assert.match(migration, new RegExp(`qiblatayn-${index}\\.jpg`));
    assert.ok(fs.existsSync(path.join(workerRoot, 'seed', 'ziyarats', 'qiblatayn-mosque', `qiblatayn-${index}.jpg`)));
  }
  for (const locale of ['ru', 'uz', 'uz-cyrl', 'en']) {
    assert.match(migration, new RegExp(`'qiblatayn-mosque', '${locale}'`));
  }
});

test('Worker exposes Ziyarats admin/catalog routes and deploy seeder handles later places', () => {
  assert.match(indexSource, /handleZiyaratAdmin/);
  assert.match(indexSource, /\/api\/admin\/ziyarats/);
  assert.match(indexSource, /\/api\/catalog\/ziyarats/);
  assert.match(renderer, /readdirSync\(seedRoot, \{ withFileTypes: true \}\)/);
  assert.match(renderer, /ziyarats\/\$\{placeID\}\/\$\{name\}/);
});
