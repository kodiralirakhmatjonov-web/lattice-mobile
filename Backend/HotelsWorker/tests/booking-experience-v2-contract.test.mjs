import assert from 'node:assert/strict';
import fs from 'node:fs';
import test from 'node:test';

const worker = fs.readFileSync(new URL('../src/index.js', import.meta.url), 'utf8');
const migration = fs.readFileSync(new URL('../migrations/0040_booking_experience_v2.sql', import.meta.url), 'utf8');

test('client trip payload exposes every lifecycle timer and status history', () => {
  for (const field of [
    'availabilityStartedAt',
    'availabilityDeadlineAt',
    'priceLockStartedAt',
    'priceLockExpiresAt',
    'paymentReceivedAt',
    'paymentConfirmationDeadlineAt',
    'documentsStartedAt',
    'documentsDeadlineAt'
  ]) {
    assert.match(worker, new RegExp(`${field}:row\\.`));
  }
  assert.match(worker, /statusHistory:await clientStatusHistory\(env,bookingID\)/);
  assert.match(worker, /ORDER BY created_at ASC LIMIT 100/);
});

test('availability state accepts early traveler and passport completion', () => {
  const availabilityGate = /\['availability_check','payment_pending'\]\.includes\(normalizedTripStatus\(auth\.trip\?\.status\)\)/g;
  assert.equal([...worker.matchAll(availabilityGate)].length, 2);
  assert.match(worker, /function travelerComplete\(v,hasPassport\).*v\.passportIssuingCountry&&hasPassport/);
  assert.doesNotMatch(worker.match(/function travelerComplete[\s\S]*?\nasync function saveTravelerForm/)?.[0] ?? '', /emergencyPhone/);
});

test('payment receipt starts ten-minute confirmation timer and remains downloadable', () => {
  assert.match(worker, /payment_received_at=COALESCE\(payment_received_at,\?\)/);
  assert.match(worker, /lifecycleISOAfter\(now,10\*60_000\)/);
  assert.match(worker, /mediaID\.startsWith\('receipt-'\)/);
  assert.match(worker, /url:`\/api\/catalog\/hotels\/client\/trips\/\$\{encodeURIComponent\(bookingID\)\}\/media\/receipt-/);
});

test('travel documents persist supplier booking references', () => {
  assert.match(migration, /ADD COLUMN booking_reference TEXT NOT NULL DEFAULT ''/);
  assert.match(worker, /const reference=safeHumanText\(url\.searchParams\.get\('reference'\),180\)/);
  assert.match(worker, /bookingReference:d\.booking_reference\|\|null/);
});

test('migration adds family relationship and recalculates only required fulfillment fields', () => {
  assert.match(migration, /ADD COLUMN relationship TEXT NOT NULL DEFAULT 'other'/);
  assert.match(migration, /WHEN position = 1 THEN 'self'/);
  assert.match(migration, /passport_object_key IS NOT NULL/);
  assert.doesNotMatch(migration, /emergency_phone/);
  assert.doesNotMatch(migration, /residence_country/);
});
