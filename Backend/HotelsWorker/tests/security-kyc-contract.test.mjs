import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

const worker = fs.readFileSync(new URL('../src/index.js', import.meta.url), 'utf8');
const migration = fs.readFileSync(new URL('../migrations/0022_iumrah_security_kyc.sql', import.meta.url), 'utf8');
const businessDesign = fs.readFileSync(new URL('../../../Sources/Core/Design.swift', import.meta.url), 'utf8');
const adminCard = fs.readFileSync(new URL('../../../Sources/Views/BookingSecurityAdminCard.swift', import.meta.url), 'utf8');

test('client KYC is a manual-review submission available only at payment pending', () => {
  assert.match(worker, /normalizedTripStatus\(auth\?\.trip\?\.status\) !== 'payment_pending'/);
  assert.match(worker, /status='submitted'/);
  assert.match(worker, /iumrah_security_submissions/);
});

test('passport photo is kept in private R2 media and served with no-store', () => {
  assert.match(worker, /privateImageUpload\(request, env, `security-passports\/\$\{bookingID\}`\)/);
  assert.match(worker, /HOTELS_MEDIA\.get\(row\.passport_object_key\)/);
  assert.match(worker, /'cache-control': 'private, no-store'/);
});

test('only Business manual approval writes a confirmed identity registry row', () => {
  assert.match(worker, /'confirmed','business_manual_passport_review'/);
  assert.match(worker, /reviewSecuritySubmission/);
  assert.match(migration, /Final anti-fraud identity registry/);
});

test('repeat passport can be KYC-confirmed for another trip', () => {
  assert.doesNotMatch(worker, /SECURITY_IDENTITY_ALREADY_CONFIRMED/);
  assert.match(worker, /duplicateBookingID/);
});

test('full passport number is removed from the review queue after approval', () => {
  assert.match(worker, /status='confirmed',passport_number=''/);
  assert.match(worker, /UPDATE booking_travelers SET[\s\S]*passport_number=\?/);
});


test('Business KYC actions use native interactive Liquid Glass grouping', () => {
  assert.match(businessDesign, /glassEffect\(\.regular\.interactive\(\), in: shape\)/);
  assert.match(businessDesign, /GlassEffectContainer/);
  assert.match(adminCard, /BusinessGlassGroup/);
  assert.doesNotMatch(businessDesign, /ultraThinMaterial/);
});

test('manual approval promotes traveler data, identity registry and review status in one D1 batch', () => {
  assert.match(worker, /await ensureTravelerRows\(env, bookingID, tripForSecurity\)/);
  assert.match(worker, /await env\.HOTELS_DB\.batch\(\[/);
  assert.match(worker, /UPDATE booking_travelers SET[\s\S]*INSERT INTO iumrah_identity_confirmations[\s\S]*UPDATE iumrah_security_submissions SET/);
});

test('replacing a traveler passport does not delete the Security review image still referenced by KYC', () => {
  assert.match(worker, /SELECT passport_object_key FROM iumrah_security_submissions WHERE booking_id=\? LIMIT 1/);
  assert.match(worker, /securityPhoto\?\.passport_object_key!==row\.passport_object_key/);
});
