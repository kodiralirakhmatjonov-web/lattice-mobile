import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';

const root = path.resolve(import.meta.dirname, '..');
const source = fs.readFileSync(path.join(root, 'src/index.js'), 'utf8');
const migration = fs.readFileSync(path.join(root, 'migrations/0036_business_flight_sync.sql'), 'utf8');

test('flight sync is read-only publicly and authenticated for snapshot writes', () => {
  assert.match(source, /parts\[0\] === 'flight-sync'/);
  assert.match(source, /publicBusinessFlightSyncFeed\(env, parts\[1\]\)/);
  assert.match(source, /saveBusinessFlightSyncSnapshot\(request, env, user\)/);
  assert.match(source, /rotateBusinessFlightSyncAccess\(env, user\)/);
  assert.match(source, /revokeBusinessFlightSyncAccess\(env, user\)/);
  assert.match(source, /read_only:\s*true/);
  assert.match(source, /cache-control': 'no-store, max-age=0'/);
});

test('flight sync token is stored only as a hash and snapshot is isolated in D1', () => {
  assert.match(migration, /token_hash TEXT NOT NULL UNIQUE/);
  assert.match(migration, /snapshot_json TEXT NOT NULL/);
  assert.match(migration, /owner_login TEXT PRIMARY KEY/);
  assert.match(source, /const tokenHash = await sha256Hex\(token\)/);
  assert.match(source, /WHERE token_hash=\? AND enabled=1/);
});

test('flight sync feed exports a stable comparison key and current fare', () => {
  assert.match(source, /comparison_key/);
  assert.match(source, /price:\s*\{ amount:/);
  assert.match(source, /FLIGHT_SYNC_INVALID_FLIGHT/);
  assert.match(source, /BUSINESS_FLIGHT_SYNC_MAX_FLIGHTS = 500/);
});
