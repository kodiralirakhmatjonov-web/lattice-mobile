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

test('hotel sync uses the server-backed permanent URL and only ensures access when missing', () => {
  const body = syncBody();
  assert.match(body, /let existingURL = city == "Makkah" \? makkahURL : madinahURL/);
  assert.match(body, /if existingStatus\?\.enabled != true \|\| accessURL == nil/);
  assert.match(body, /ensureHotelSyncAccess\(city: city\)/);
  assert.match(body, /existingStatus\?\.accessURL/);
  assert.match(body, /saveHotelSyncSnapshot\(city: city, checkIn: date, hotels: hotels\)/);
  assert.doesNotMatch(body, /revokeHotelSyncAccess\(city: city\)/);
  assert.match(body, /must never revoke or rotate an existing public link/);
});

test('daily hotel sync saves the snapshot before refreshing backup JSON', () => {
  const body = syncBody();
  const save = body.indexOf('saveHotelSyncSnapshot(city: city, checkIn: date, hotels: hotels)');
  const readBody = body.indexOf('hotelSyncBody(city: city)');
  assert.ok(save >= 0, 'snapshot save must exist');
  assert.ok(readBody > save, 'admin JSON body must be read only after snapshot save');
  assert.doesNotMatch(body, /hotelSyncReadOnlyBody\(from:/);
});

test('hotel sync UI exposes separate copy-link and copy-JSON controls for each city card', () => {
  assert.match(source, /Label\("Скопировать ссылку", systemImage: "link"\)/);
  assert.match(source, /UIPasteboard\.general\.string = url\.absoluteString/);
  assert.match(source, /Label\("Скопировать JSON", systemImage: "doc\.text"\)/);
  assert.match(source, /UIPasteboard\.general\.string = jsonBody/);
  assert.match(source, /citySyncCard\(\s*city: "Makkah"/);
  assert.match(source, /citySyncCard\(\s*city: "Madinah"/);
});

test('stale hotel sync state is visibly distinguished from the current catalog/date', () => {
  assert.match(source, /let syncIsCurrent = status\?\.enabled == true/);
  assert.match(source, /status\?\.checkIn == selectedCheckIn/);
  assert.match(source, /status\?\.hotelCount == cityHotels\.count/);
  assert.match(source, /Text\(syncIsCurrent \? "Hotel Sync актуален" : "Предыдущая синхронизация"\)/);
  assert.match(source, /Постоянная ссылка остаётся доступной/);
  assert.doesNotMatch(source, /\.disabled\(!syncIsCurrent\)/);
});

test('backup Hotel Sync JSON is fetched through authenticated admin route', () => {
  assert.match(api, /func hotelSyncBody\(city: String\)/);
  assert.match(api, /hotel-sync\/\\\(canonical\.lowercased\(\)\)\/body/);
  assert.match(api, /let \(data, response\) = try await perform\(from: url\)/);
  assert.doesNotMatch(syncBody(), /URLSession\.shared\.data/);
});

test('Hotel Sync JSON editor can dismiss the keyboard without leaving the screen', () => {
  assert.match(source, /@FocusState private var jsonEditorFocused: Bool/);
  assert.match(source, /ToolbarItemGroup\(placement: \.keyboard\)/);
  assert.match(source, /Button\("Готово"\) \{ jsonEditorFocused = false \}/);
  assert.match(source, /scrollDismissesKeyboard\(\.interactively\)/);
  assert.match(source, /Label\("Скрыть клавиатуру", systemImage: "keyboard\.chevron\.compact\.down"\)/);
});

test('Hotel Sync returns to the top after applying prices so content shrink cannot leave a blank screen', () => {
  assert.match(source, /ScrollViewReader \{ proxy in/);
  assert.match(source, /\.id\("hotel-sync-top"\)/);
  assert.match(source, /@State private var scrollToTopRequest = 0/);
  assert.match(source, /proxy\.scrollTo\("hotel-sync-top", anchor: \.top\)/);

  const applyStart = source.indexOf('private func applySelected() async');
  assert.notEqual(applyStart, -1, 'applySelected must exist');
  const applyBody = source.slice(applyStart, source.indexOf('\n    private func hotelsForCity', applyStart));
  const clearPreview = applyBody.indexOf('preview = nil');
  const requestScroll = applyBody.indexOf('scrollToTopRequest &+= 1');
  assert.ok(clearPreview >= 0, 'successful apply must clear preview');
  assert.ok(requestScroll > clearPreview, 'scroll reset must happen after the tall preview is removed');
});
