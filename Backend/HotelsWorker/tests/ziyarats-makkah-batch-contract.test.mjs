import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const workerRoot = path.resolve(here, '..');
const migration = fs.readFileSync(path.join(workerRoot, 'migrations', '0033_makkah_ziyarats.sql'), 'utf8');
const ziyarats = fs.readFileSync(path.join(workerRoot, 'src', 'ziyarats.js'), 'utf8');

const stops = [
  { id: 'jabal-thawr', coordinate: /21\.3768194, 39\.8500389/, prefix: 'thawr', count: 5, order: 1 },
  { id: 'arafat-jabal-rahmah', coordinate: /21\.3548311, 39\.9838861/, prefix: 'arafat', count: 5, order: 2 },
  { id: 'muzdalifah', coordinate: /21\.3862222, 39\.9124722/, prefix: 'muzdalifah', count: 5, order: 3 },
  { id: 'mina-holy-site', coordinate: /21\.4133333, 39\.8933333/, prefix: 'mina', count: 5, order: 4 },
  { id: 'jamarat-complex', coordinate: /21\.4213889, 39\.8728056/, prefix: 'jamarat', count: 5, order: 5 },
  { id: 'masjid-al-haram', coordinate: /21\.4225, 39\.8261667/, prefix: 'haram', count: 6, order: 6 },
];

test('Makkah route contains six published stops with explicit coordinates and order', () => {
  assert.match(migration, /'makkah-main'/);
  assert.match(migration, /'Makkah Ziyarat'/);
  for (const stop of stops) {
    assert.match(migration, new RegExp(`'${stop.id}'`));
    assert.match(migration, stop.coordinate);
    assert.match(migration, new RegExp(`, ${stop.order}, 'published', 'seed'`));
  }
});

test('Makkah batch ships every supplied HD image, including six for Al-Masjid al-Haram', () => {
  for (const stop of stops) {
    for (let index = 1; index <= stop.count; index += 1) {
      const name = `${stop.prefix}-${index}.jpg`;
      const file = path.join(workerRoot, 'seed', 'ziyarats', stop.id, name);
      assert.ok(fs.existsSync(file), `${file} must exist`);
      assert.ok(fs.statSync(file).size > 250_000, `${name} should remain an HD-quality asset`);
      assert.match(migration, new RegExp(name.replace('.', '\\.')));
    }
  }
});

test('Each Makkah stop ships all four client translations', () => {
  for (const stop of stops) {
    for (const locale of ['ru', 'uz', 'uz-cyrl', 'en']) {
      assert.match(migration, new RegExp(`'${stop.id}', '${locale}'`));
    }
  }
});

test('Ziyarat image count is unrestricted at API/catalog level', () => {
  assert.doesNotMatch(ziyarats, /ZIYARAT_IMAGE_LIMIT/);
  assert.doesNotMatch(ziyarats, /ORDER BY position ASC, created_at ASC LIMIT 5/);
  assert.match(ziyarats, /requestedPosition/);
  assert.doesNotMatch(ziyarats, /1_000_000/);
});
