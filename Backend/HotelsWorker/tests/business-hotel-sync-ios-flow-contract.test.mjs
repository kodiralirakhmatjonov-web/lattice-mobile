import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

const source = fs.readFileSync(new URL('../../../Sources/Views/HotelPriceMonitoringView.swift', import.meta.url), 'utf8');
const api = fs.readFileSync(new URL('../../../Sources/Networking/APIClient+HotelSync.swift', import.meta.url), 'utf8');
const models = fs.readFileSync(new URL('../../../Sources/Models/HotelSyncModels.swift', import.meta.url), 'utf8');

test('Hotel Sync is a single manual ChatGPT access switch with no links, snapshot or date picker', () => {
  assert.match(source, /Открыть доступ ChatGPT/);
  assert.match(source, /Закрыть доступ ChatGPT/);
  assert.match(source, /setChatGPTHotelAccess\(enabled: enabled\)/);
  assert.match(source, /Доступ постоянный до ручного отключения/);
  assert.doesNotMatch(source, /DatePicker\(/);
  assert.doesNotMatch(source, /Скопировать ссылку/);
  assert.doesNotMatch(source, /makkahURL|madinahURL|snapshotID|checkIn|checkOut/);
});

test('Business app reads and toggles one server-backed live access state', () => {
  assert.match(api, /func chatGPTHotelAccessStatus\(\)/);
  assert.match(api, /\/api\/admin\/hotels\/operations\/chatgpt-hotels/);
  assert.match(api, /func setChatGPTHotelAccess\(enabled: Bool\)/);
  assert.match(api, /request\.httpMethod = enabled \? "POST" : "DELETE"/);
  assert.doesNotMatch(api, /ensureHotelSyncAccess|updateHotelSyncSettings|saveHotelSyncSnapshot/);
});

test('ChatGPT price result is v3 and has no snapshot/date/occupancy document gate', () => {
  assert.match(models, /schemaName = "iumrah\.hotel-price-update\.v3"/);
  const documentStart = models.indexOf('struct BusinessHotelPriceUpdateDocument');
  const previewStart = models.indexOf('struct BusinessHotelPricePreviewItem', documentStart);
  const document = models.slice(documentStart, previewStart);
  assert.doesNotMatch(document, /snapshotID|checkIn|checkOut|rooms|adults|currency/);
  assert.match(api, /PRICE_ALREADY_CHANGED/);
  assert.match(api, /chatGPTHotelSameProperty/);
  assert.match(api, /\/api\/admin\/hotels\/operations\/chatgpt-hotels\/apply/);
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
  const applyBody = source.slice(applyStart, source.indexOf('\n    private func canonicalCity', applyStart));
  const clearPreview = applyBody.indexOf('preview = nil');
  const requestScroll = applyBody.indexOf('scrollToTopRequest &+= 1');
  assert.ok(clearPreview >= 0, 'successful apply must clear preview');
  assert.ok(requestScroll > clearPreview, 'scroll reset must happen after the tall preview is removed');
});
