import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

const source = fs.readFileSync(new URL('../../../Sources/Views/HotelPriceMonitoringView.swift', import.meta.url), 'utf8');
const api = fs.readFileSync(new URL('../../../Sources/Networking/APIClient+HotelSync.swift', import.meta.url), 'utf8');

function syncBody() {
  const start = source.indexOf('private func syncAndCopy(city: String, date: Date) async');
  const end = source.indexOf('\n    @MainActor\n    private func revoke(city: String)', start);
  assert.notEqual(start, -1, 'sync function must exist');
  assert.notEqual(end, -1, 'revoke boundary must exist');
  return source.slice(start, end);
}

test('hotel sync keeps Flight Sync fresh-access -> snapshot flow and prepares both URL and JSON', () => {
  const body = syncBody();
  const rotate = body.indexOf('rotateHotelSyncAccess(city: city)');
  const save = body.indexOf('saveHotelSyncSnapshot(city: city, checkIn: date, hotels: hotels)');
  const readBody = body.indexOf('try? await APIClient.shared.hotelSyncReadOnlyBody(from: accessURL)');
  assert.ok(rotate >= 0, 'must rotate/create a fresh access URL');
  assert.ok(save > rotate, 'must save snapshot after receiving fresh access');
  assert.ok(readBody > save, 'JSON body may be fetched only after snapshot save');
  assert.match(body, /makkahURL = accessURL/);
  assert.match(body, /makkahJSON = jsonBody/);
  assert.doesNotMatch(body, /UIPasteboard\.general\.string/);
});

test('hotel sync UI exposes separate copy-link and copy-JSON controls for each city card', () => {
  assert.match(source, /Label\("Скопировать ссылку", systemImage: "link"\)/);
  assert.match(source, /UIPasteboard\.general\.string = url\.absoluteString/);
  assert.match(source, /Label\("Скопировать JSON", systemImage: "doc\.text"\)/);
  assert.match(source, /UIPasteboard\.general\.string = jsonBody/);
  assert.match(source, /citySyncCard\(\s*city: "Makkah"/);
  assert.match(source, /citySyncCard\(\s*city: "Madinah"/);
});

test('JSON body fetch is best-effort and cannot invalidate a working read-only URL', () => {
  const body = syncBody();
  assert.match(body, /let jsonBody = try\? await APIClient\.shared\.hotelSyncReadOnlyBody\(from: accessURL\)/);
  const setURL = body.indexOf('makkahURL = accessURL');
  const setJSON = body.indexOf('makkahJSON = jsonBody');
  assert.ok(setURL >= 0 && setJSON > setURL);
});

test('hotel sync button never reuses a stale Keychain URL or gates rotation on server status', () => {
  const body = syncBody();
  assert.doesNotMatch(body, /BusinessSessionVault\.hotelSyncAccessURL\(city: city\)/);
  assert.doesNotMatch(body, /serverStatus/);
  assert.match(body, /setHotelSyncAccessURL\(accessURL, city: city\)/);
});

test('read-only Hotel Sync JSON is fetched without mutating the feed', () => {
  assert.match(api, /func hotelSyncReadOnlyBody\(from accessURL: URL\)/);
  assert.match(api, /URLSession\.shared\.data\(for: request\)/);
  assert.match(api, /String\(data: data, encoding: \.utf8\)/);
});

test('Hotel Sync JSON editor can dismiss the keyboard without leaving the screen', () => {
  assert.match(source, /@FocusState private var jsonEditorFocused: Bool/);
  assert.match(source, /ToolbarItemGroup\(placement: \.keyboard\)/);
  assert.match(source, /Button\("Готово"\) \{ jsonEditorFocused = false \}/);
  assert.match(source, /scrollDismissesKeyboard\(\.interactively\)/);
  assert.match(source, /Label\("Скрыть клавиатуру", systemImage: "keyboard\.chevron\.compact\.down"\)/);
});
