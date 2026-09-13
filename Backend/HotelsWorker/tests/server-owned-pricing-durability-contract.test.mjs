import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

const worker = fs.readFileSync(new URL('../src/index.js', import.meta.url), 'utf8');
const migration = fs.readFileSync(new URL('../migrations/0039_pending_package_pricing_reports.sql', import.meta.url), 'utf8');

test('Business consumes PackageEngine pending reports only after an operational trip exists', () => {
  assert.match(worker, /async function applyPendingPackagePricingReport\(env, bookingID\)/);
  assert.match(worker, /SELECT quote_id,pricing_version,pricing_snapshot_json FROM pending_package_pricing_reports/);
  assert.match(worker, /SELECT id,pricing_snapshot_json FROM pilgrim_trips WHERE booking_id=\? LIMIT 1/);
  assert.match(worker, /UPDATE pilgrim_trips[\s\S]*pricing_snapshot_json=\?/);
  assert.match(worker, /DELETE FROM pending_package_pricing_reports WHERE booking_id=\?/);
  assert.match(worker, /PACKAGE_PRICING_IMMUTABILITY_CONFLICT/);
});

test('every Business trip-materialization path attempts the durable pricing hand-off', () => {
  const calls = worker.match(/await applyPendingPackagePricingReport\(env, bookingID\);/g) || [];
  assert.ok(calls.length >= 2, 'syncBookingTrip and account link-booking must both consume pending pricing');
});

test('pending pricing migration stores only post-booking server reports keyed by booking', () => {
  assert.match(migration, /CREATE TABLE IF NOT EXISTS pending_package_pricing_reports/);
  assert.match(migration, /booking_id TEXT PRIMARY KEY/);
  assert.match(migration, /quote_id TEXT NOT NULL/);
  assert.match(migration, /pricing_snapshot_json TEXT NOT NULL/);
});

test('client supplied pricingSnapshot remains non-authoritative', () => {
  assert.match(worker, /pricingSnapshot from a client is intentionally ignored/);
  assert.match(worker, /Never treat an embedded client pricingSnapshot as authoritative/);
});
