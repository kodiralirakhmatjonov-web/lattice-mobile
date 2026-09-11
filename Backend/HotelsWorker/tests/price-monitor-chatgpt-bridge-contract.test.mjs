import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

const worker = fs.readFileSync(new URL('../src/index.js', import.meta.url), 'utf8');
const migration = fs.readFileSync(new URL('../migrations/0037_business_hotel_sync.sql', import.meta.url), 'utf8');
const api = fs.readFileSync(new URL('../../../Sources/Networking/APIClient.swift', import.meta.url), 'utf8');
const hotelSyncAPI = fs.readFileSync(new URL('../../../Sources/Networking/APIClient+HotelSync.swift', import.meta.url), 'utf8');
const hotelsView = fs.readFileSync(new URL('../../../Sources/Views/HotelsView.swift', import.meta.url), 'utf8');
const exchangeView = fs.readFileSync(new URL('../../../Sources/Views/HotelPriceMonitoringView.swift', import.meta.url), 'utf8');
const detailView = fs.readFileSync(new URL('../../../Sources/Views/HotelAdminDetailView.swift', import.meta.url), 'utf8');
const flightAPI = fs.readFileSync(new URL('../../../Sources/Networking/APIClient+FlightSync.swift', import.meta.url), 'utf8');

test('old Cloudflare hotel monitor and temporary ChatGPT bridge are removed from active routes', () => {
  assert.doesNotMatch(worker, /handleChatGPTPublic|handlePriceMonitorAdmin|runHotelPriceMonitorWorkflow/);
  assert.doesNotMatch(worker, /\/api\/iumrah\/chatgpt\//);
  assert.doesNotMatch(worker, /async scheduled\(controller,\s*env,\s*ctx\)/);
  assert.doesNotMatch(exchangeView, /Экспорт JSON|fileExporter|fileImporter/);
  assert.doesNotMatch(detailView, /Обновить из источника/);
});

test('Makkah and Madinah have separate durable read-only hotel sync feeds', () => {
  assert.match(worker, /parts\[0\] === 'hotel-sync'/);
  assert.match(worker, /publicBusinessHotelSyncFeed/);
  assert.match(worker, /businessHotelSyncStatus/);
  assert.match(worker, /rotateBusinessHotelSyncAccess/);
  assert.match(worker, /saveBusinessHotelSyncSnapshot/);
  assert.match(worker, /businessHotelSyncCity/);
  assert.match(migration, /PRIMARY KEY \(owner_login, city\)/);
  assert.match(migration, /token_hash TEXT NOT NULL UNIQUE/);
  assert.match(worker, /sha256Hex\(token\)/);
  assert.match(exchangeView, /Makkah/);
  assert.match(exchangeView, /Madinah/);
  assert.match(exchangeView, /отдельная read-only ссылка/);
});

test('hotel feed instructs ChatGPT to use direct dated provider pages and not search snippets', () => {
  assert.match(worker, /hotel\.monitoringURL/);
  assert.match(worker, /Google\/open web search may only help locate the same provider property page/);
  assert.match(worker, /Do not use a search snippet or a different property as final price evidence/);
  assert.match(worker, /status unverified/);
  assert.match(worker, /iumrah\.hotel-price-update\.v2/);
  assert.match(hotelSyncAPI, /checkin/);
  assert.match(hotelSyncAPI, /checkout/);
  assert.match(hotelSyncAPI, /chkin/);
  assert.match(hotelSyncAPI, /chkout/);
  assert.match(hotelSyncAPI, /selected_currency/);
  assert.match(hotelSyncAPI, /top_cur/);
});

test('paste JSON preview requires snapshot, exact dates and direct high-confidence source', () => {
  assert.match(exchangeView, /TextEditor\(text: \$jsonText\)/);
  assert.match(exchangeView, /Вставьте результат проверки сюда/);
  assert.match(api, /HOTEL_SYNC_SNAPSHOT_CHANGED/);
  assert.match(api, /HOTEL_SYNC_DATES_CHANGED/);
  assert.match(api, /DATES_NOT_VERIFIED/);
  assert.match(api, /DIRECT_SOURCE_NOT_VERIFIED/);
  assert.match(api, /CHECKED_SOURCE_DATES_NOT_VERIFIED/);
  assert.match(worker, /hotelSyncCheckedURLMatchesDates/);
  assert.match(worker, /CHECKED_SOURCE_DATES_NOT_VERIFIED/);
  assert.match(api, /confidence\.label == "high"/);
  assert.match(api, /iumrah\.hotel-price-update\.v2/);
  assert.match(exchangeView, /Обновить выбранные цены/);
});

test('approved ChatGPT price writes the source cache rather than a manual override', () => {
  assert.match(worker, /parts\[2\] === 'verified'/);
  assert.match(worker, /saveVerifiedChatGPTHotelPrice/);
  const start = worker.indexOf('async function saveVerifiedChatGPTHotelPrice');
  const end = worker.indexOf('async function setManualHotelPrice', start);
  const implementation = worker.slice(start, end);
  assert.match(implementation, /INSERT INTO hotel_price_cache/);
  assert.match(implementation, /chatgpt-direct-source-v2/);
  assert.match(implementation, /DELETE FROM hotel_price_overrides WHERE hotel_id=\?/);
  assert.match(implementation, /safePropertyKey/);
});

test('hotel importer remains present and flight sync architecture is untouched', () => {
  assert.match(hotelsView, /AddHotelView\(\)/);
  assert.match(hotelsView, /Импортировать отель/);
  assert.match(flightAPI, /flightSyncStatus/);
  assert.match(flightAPI, /rotateFlightSyncAccess/);
  assert.match(flightAPI, /saveFlightSyncSnapshot/);
  assert.match(worker, /publicBusinessFlightSyncFeed/);
});
