import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

const source = fs.readFileSync(new URL('../../../Sources/Views/HotelPriceMonitoringView.swift', import.meta.url), 'utf8');
const api = fs.readFileSync(new URL('../../../Sources/Networking/APIClient+HotelSync.swift', import.meta.url), 'utf8');

function syncAndCopyBody() {
  const start = source.indexOf('private func syncAndCopy(city: String, date: Date) async');
  const end = source.indexOf('\n    @MainActor\n    private func revoke(city: String)', start);
  assert.notEqual(start, -1, 'syncAndCopy must exist');
  assert.notEqual(end, -1, 'revoke boundary must exist');
  return source.slice(start, end);
}

test('hotel sync keeps Flight Sync fresh-access -> snapshot flow and copies the resulting JSON body', () => {
  const body = syncAndCopyBody();
  const rotate = body.indexOf('rotateHotelSyncAccess(city: city)');
  const save = body.indexOf('saveHotelSyncSnapshot(city: city, checkIn: date, hotels: hotels)');
  const readBody = body.indexOf('hotelSyncReadOnlyBody(from: accessURL)');
  const copy = body.indexOf('UIPasteboard.general.string = jsonBody');

  assert.ok(rotate >= 0, 'must rotate/create a fresh access URL');
  assert.ok(save > rotate, 'must save snapshot after receiving the fresh access URL');
  assert.ok(readBody > save, 'must read the public feed only after snapshot save succeeds');
  assert.ok(copy > readBody, 'must copy the exact JSON body returned by the fresh read-only feed');
});

test('hotel sync button never reuses a stale Keychain URL or gates rotation on server status', () => {
  const body = syncAndCopyBody();
  assert.doesNotMatch(body, /BusinessSessionVault\.hotelSyncAccessURL\(city: city\)/);
  assert.doesNotMatch(body, /serverStatus/);
  assert.match(body, /setHotelSyncAccessURL\(accessURL, city: city\)/);
});

test('hotel sync copies JSON before any non-critical status refresh', () => {
  const body = syncAndCopyBody();
  const copy = body.indexOf('UIPasteboard.general.string = jsonBody');
  const optionalStatus = body.indexOf('try? await APIClient.shared.hotelSyncStatus(city: city)');
  assert.ok(copy >= 0, 'fresh JSON body must be copied');
  assert.ok(optionalStatus > copy, 'status refresh must run only after clipboard copy');
});

test('read-only Hotel Sync JSON is fetched without mutating the feed', () => {
  assert.match(api, /func hotelSyncReadOnlyBody\(from accessURL: URL\)/);
  assert.match(api, /URLSession\.shared\.data\(for: request\)/);
  assert.match(api, /String\(data: data, encoding: \.utf8\)/);
  assert.doesNotMatch(api, /withJSONObject: object/);
});

test('Hotel Sync JSON editor can dismiss the keyboard without leaving the screen', () => {
  assert.match(source, /@FocusState private var jsonEditorFocused: Bool/);
  assert.match(source, /ToolbarItemGroup\(placement: \.keyboard\)/);
  assert.match(source, /Button\("Готово"\) \{ jsonEditorFocused = false \}/);
  assert.match(source, /scrollDismissesKeyboard\(\.interactively\)/);
  assert.match(source, /Label\("Скрыть клавиатуру", systemImage: "keyboard\.chevron\.compact\.down"\)/);
});
