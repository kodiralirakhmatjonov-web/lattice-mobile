import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

const source = fs.readFileSync(new URL('../src/index.js', import.meta.url), 'utf8');
const migration = fs.readFileSync(new URL('../migrations/0038_booking_lifecycle_timers.sql', import.meta.url), 'utf8');

test('trip API exposes every canonical booking lifecycle timestamp', () => {
  for (const field of [
    'availabilityStartedAt', 'availabilityDeadlineAt',
    'priceLockStartedAt', 'priceLockExpiresAt',
    'paymentReceivedAt', 'paymentConfirmationDeadlineAt',
    'documentsStartedAt', 'documentsDeadlineAt'
  ]) {
    assert.match(source, new RegExp(`${field}:row\\.`));
  }
});

test('status transitions start server-owned countdown windows', () => {
  assert.match(source, /lifecycleFieldsForStatus\(nextStatus, now\)/);
  assert.match(source, /nextStatus === 'availability_check'/);
  assert.match(source, /nextStatus === 'payment_pending'/);
  assert.match(source, /nextStatus === 'booking_confirmed'/);
  assert.match(source, /availability_started_at=\?/);
  assert.match(source, /price_lock_started_at=\?/);
  assert.match(source, /documents_started_at=\?/);
});

test('payment receipt starts the payment confirmation timer', () => {
  assert.match(source, /payment_received_at=COALESCE\(payment_received_at,\?\)/);
  assert.match(source, /payment_confirmation_deadline_at=COALESCE\(payment_confirmation_deadline_at,\?\)/);
});

test('client receives status history and Business can restart an expired price lock', () => {
  assert.match(source, /async function bookingStatusHistory/);
  assert.match(source, /statusHistory/);
  assert.match(source, /parts\[2\] === 'price-lock'.*parts\[3\] === 'restart'/);
  assert.match(source, /async function restartBookingPriceLock/);
});

test('migration owns the eight lifecycle timer columns and backfill', () => {
  for (const column of [
    'availability_started_at', 'availability_deadline_at',
    'price_lock_started_at', 'price_lock_expires_at',
    'payment_received_at', 'payment_confirmation_deadline_at',
    'documents_started_at', 'documents_deadline_at'
  ]) {
    assert.match(migration, new RegExp(column));
  }
});
