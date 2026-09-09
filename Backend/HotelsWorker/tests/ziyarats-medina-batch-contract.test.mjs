import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const workerRoot = path.resolve(here, '..');
const migration = fs.readFileSync(path.join(workerRoot, 'migrations', '0032_medina_ziyarat_batch.sql'), 'utf8');

const stops = [
  { id: 'mount-uhud', coordinate: /24\.50295, 39\.61132/, prefix: 'uhud', order: 3 },
  { id: 'aliya-date-garden', coordinate: /24\.449811, 39\.627519/, prefix: 'date-garden', order: 4 },
  { id: 'al-baqi', coordinate: /24\.46667, 39\.61633/, prefix: 'baqi', order: 5 },
];

test('Medina batch stores explicit coordinates and route order for stops 3–5', () => {
  for (const stop of stops) {
    assert.match(migration, new RegExp(`'${stop.id}'`));
    assert.match(migration, stop.coordinate);
    assert.match(migration, new RegExp(`, ${stop.order}, 'published', 'seed'`));
  }
});

test('Each new stop has five optimized HD repository images', () => {
  for (const stop of stops) {
    for (let index = 1; index <= 5; index += 1) {
      const name = `${stop.prefix}-${index}.jpg`;
      const file = path.join(workerRoot, 'seed', 'ziyarats', stop.id, name);
      assert.ok(fs.existsSync(file), `${file} must exist`);
      assert.ok(fs.statSync(file).size > 250_000, `${name} should remain a high-quality HD asset`);
      assert.match(migration, new RegExp(name.replace('.', '\\.')));
    }
  }
});

test('Each new stop ships Russian, Uzbek Latin, Uzbek Cyrillic and English content', () => {
  for (const stop of stops) {
    for (const locale of ['ru', 'uz', 'uz-cyrl', 'en']) {
      assert.match(migration, new RegExp(`'${stop.id}', '${locale}'`));
    }
  }
});
