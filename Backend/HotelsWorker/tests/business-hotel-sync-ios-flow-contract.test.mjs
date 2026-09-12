import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

const source = fs.readFileSync(new URL('../../../Sources/Views/HotelPriceMonitoringView.swift', import.meta.url), 'utf8');

function syncAndCopyBody() {
  const start = source.indexOf('private func syncAndCopy(city: String, date: Date) async');
  const end = source.indexOf('\n    @MainActor\n    private func revoke(city: String)', start);
  assert.notEqual(start, -1, 'syncAndCopy must exist');
  assert.notEqual(end, -1, 'revoke boundary must exist');
  return source.slice(start, end);
}

test('hotel sync button mirrors Flight Sync create-access -> snapshot -> clipboard flow', () => {
  const body = syncAndCopyBody();
  const rotate = body.indexOf('rotateHotelSyncAccess(city: city)');
  const save = body.indexOf('saveHotelSyncSnapshot(city: city, checkIn: date, hotels: hotels)');
  const copy = body.indexOf('UIPasteboard.general.string = accessURL.absoluteString');

  assert.ok(rotate >= 0, 'must rotate/create a fresh access URL');
  assert.ok(save > rotate, 'must save snapshot after receiving the fresh access URL');
  assert.ok(copy > save, 'must copy exactly that URL only after snapshot save succeeds');
});

test('hotel sync button never reuses a stale Keychain URL or gates rotation on server status', () => {
  const body = syncAndCopyBody();
  assert.doesNotMatch(body, /BusinessSessionVault\.hotelSyncAccessURL\(city: city\)/);
  assert.doesNotMatch(body, /serverStatus/);
  assert.match(body, /setHotelSyncAccessURL\(accessURL, city: city\)/);
});

test('hotel sync copies the fresh URL before any non-critical status refresh', () => {
  const body = syncAndCopyBody();
  const copy = body.indexOf('UIPasteboard.general.string = accessURL.absoluteString');
  const optionalStatus = body.indexOf('try? await APIClient.shared.hotelSyncStatus(city: city)');
  assert.ok(copy >= 0, 'fresh access URL must be copied');
  assert.ok(optionalStatus > copy, 'status refresh must run only after clipboard copy');
});
