import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

const source = fs.readFileSync(new URL('../../../Sources/Hotels/HotelImportCoordinator.swift', import.meta.url), 'utf8');

test('Expedia main import still opens the exact user URL before any room availability probe', () => {
  const start = source.indexOf('func start(sourceURL rawValue: String)');
  const retry = source.indexOf('func retryRoomRecovery()', start);
  const body = source.slice(start, retry);
  assert.match(body, /URLRequest\(url: normalized/);
  assert.doesNotMatch(body, /expediaRoomProbeURLs/);
});

test('room recovery uses a real browser viewport and exact-property availability URLs', () => {
  const start = source.indexOf('private func recoverRoomsInBrowser');
  const end = source.indexOf('private func waitForRoomProbeLoad', start);
  const body = source.slice(start, end);
  assert.match(body, /width: 1366, height: 1100/);
  assert.match(body, /Self\.isSameProperty\(probeURL, as: propertyURL, provider: provider\)/);
  assert.match(body, /Self\.roomProbeURLs\(provider: provider, propertyURL: propertyURL\)/);
  const routerStart = source.indexOf('private static func roomProbeURLs');
  const routerEnd = source.indexOf('private static func expediaRoomProbeURLs', routerStart);
  const router = source.slice(routerStart, routerEnd);
  assert.match(router, /bookingOperationalURLs\(propertyURL\)/);
  assert.match(router, /expediaRoomProbeURLs\(propertyURL\)/);
});

test('Expedia room probe adds live dates and occupancy but strips stale mobile deep-link tracking', () => {
  const start = source.indexOf('private static func expediaRoomProbeURLs');
  const end = source.indexOf('private func waitForRoomProbeLoad', start);
  const body = source.slice(start, end);
  assert.match(body, /set\("chkin"/);
  assert.match(body, /set\("chkout"/);
  assert.match(body, /set\("rm1", "a2"\)/);
  assert.match(body, /set\("currency", "USD"\)/);
  assert.match(body, /"deep_link_value"/);
  assert.match(body, /!name\.hasPrefix\("af_"\)/);
});

test('Expedia nested room state is accepted only inside the exact property subtree', () => {
  assert.match(source, /walkScopedRooms/);
  assert.match(source, /explicitID && explicitID !== expectedPropertyID/);
  assert.match(source, /candidatePropertyID\(root\) === expectedPropertyID/);
});
