import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

const worker = fs.readFileSync(new URL('../src/index.js', import.meta.url), 'utf8');
const wrangler = fs.readFileSync(new URL('../wrangler.template.jsonc', import.meta.url), 'utf8');
const migration = fs.readFileSync(new URL('../migrations/0038_business_hotel_sync_feeds.sql', import.meta.url), 'utf8');
const api = fs.readFileSync(new URL('../../../Sources/Networking/APIClient+HotelSync.swift', import.meta.url), 'utf8');
const models = fs.readFileSync(new URL('../../../Sources/Models/HotelSyncModels.swift', import.meta.url), 'utf8');
const hotelsView = fs.readFileSync(new URL('../../../Sources/Views/HotelsView.swift', import.meta.url), 'utf8');
const syncView = fs.readFileSync(new URL('../../../Sources/Views/HotelPriceMonitoringView.swift', import.meta.url), 'utf8');
const detailView = fs.readFileSync(new URL('../../../Sources/Views/HotelAdminDetailView.swift', import.meta.url), 'utf8');
const flightAPI = fs.readFileSync(new URL('../../../Sources/Networking/APIClient+FlightSync.swift', import.meta.url), 'utf8');

test('legacy Cloudflare hotel price monitor and old public ChatGPT bridge are removed from active routing', () => {
  assert.doesNotMatch(worker, /handleChatGPTPublic|handlePriceMonitorAdmin|handleChatGPTLinksAdmin|runHotelPriceMonitorWorkflow/);
  assert.doesNotMatch(worker, /\/api\/iumrah\/chatgpt\//);
  assert.doesNotMatch(wrangler, /HOTEL_PRICE_MONITOR_WORKFLOW|HOTEL_PRICE_MONITOR_ITEM_WORKFLOW/);
  assert.doesNotMatch(wrangler, /"triggers"/);
  assert.doesNotMatch(syncView, /Экспорт JSON|fileExporter|fileImporter/);
  assert.doesNotMatch(detailView, /Обновить из источника/);
});

test('hotel snapshot comes from the already-loaded Business app list and is never rebuilt by the public feed', () => {
  assert.match(api, /saveHotelSyncSnapshot\(city:\s*String,\s*checkIn:\s*Date,\s*hotels:\s*\[HotelListItem\]\)/);
  assert.match(api, /let selected = hotels/);
  const saveStart = api.indexOf('func saveHotelSyncSnapshot');
  const previewStart = api.indexOf('func previewHotelChatGPTUpdate', saveStart);
  const saveBody = api.slice(saveStart, previewStart);
  assert.doesNotMatch(saveBody, /try await hotels\(\)/);
  assert.match(worker, /source:\s*'iumrah_business_live_app_state'/);
  assert.match(worker, /snapshot_json/);
  assert.match(migration, /business_hotel_sync_feeds/);
  assert.match(migration, /PRIMARY KEY \(owner_login, city\)/);
});

test('Makkah and Madinah use separate durable secret links and the public body copies the proven Flight Sync transport contract', () => {
  assert.match(worker, /businessHotelSyncPublicURL\(city, token\)/);
  assert.match(worker, /hotel-sync\/\$\{hotelSyncCitySlug\(city\)\}\/\$\{encodeURIComponent\(token\)\}/);
  assert.match(worker, /publicBusinessHotelSyncFeed\(env, parts\[1\], parts\[2\]\)/);
  assert.match(worker, /WHERE token_hash=\? AND city=\? AND enabled=1/);
  assert.match(worker, /monitoring_url/);
  assert.match(worker, /url\.searchParams\.set\('checkin', checkIn\)/);
  assert.match(worker, /url\.searchParams\.set\('chkin', checkIn\)/);
  assert.match(worker, /Never use a Google\/search-result price snippet as a verified price/);

  const hotelFeedStart = worker.indexOf('async function publicBusinessHotelSyncFeed');
  const hotelFeedEnd = worker.indexOf('function normalizedHotelSyncUpdateItem', hotelFeedStart);
  const hotelFeed = worker.slice(hotelFeedStart, hotelFeedEnd);
  assert.match(hotelFeed, /'content-type': 'text\/plain; charset=utf-8'/);
  assert.match(hotelFeed, /'x-content-type-options': 'nosniff'/);
  assert.match(hotelFeed, /'cache-control': 'no-store, max-age=0'/);
  assert.doesNotMatch(hotelFeed, /'content-type': 'text\/html|cache-control': 'public/i);

  const flightFeedStart = worker.indexOf('async function publicBusinessFlightSyncFeed');
  const flightFeedEnd = worker.indexOf('const FLIGHT_DIRECTIONS', flightFeedStart);
  const flightFeed = worker.slice(flightFeedStart, flightFeedEnd);
  for (const header of ["'content-type': 'text/plain; charset=utf-8'", "'x-content-type-options': 'nosniff'", "'cache-control': 'no-store, max-age=0'"]) {
    assert.ok(hotelFeed.includes(header), `hotel feed missing ${header}`);
    assert.ok(flightFeed.includes(header), `flight feed missing ${header}`);
  }
});

test('old v4 Keychain links self-heal once when the durable feed is first used', () => {
  assert.match(syncView, /let serverStatus = try\? await APIClient\.shared\.hotelSyncStatus/);
  assert.match(syncView, /accessURL == nil \|\| serverStatus\?\.enabled != true/);
  assert.match(syncView, /rotateHotelSyncAccess/);
  assert.match(syncView, /setHotelSyncAccessURL/);
});

test('ChatGPT result is pasted as v2 JSON, exact-date previewed, then explicitly batch-applied', () => {
  assert.match(models, /schemaName = "iumrah\.hotel-price-update\.v2"/);
  assert.match(syncView, /TextEditor\(text: \$pastedJSON\)/);
  assert.match(syncView, /Проверить JSON/);
  assert.match(syncView, /Обновить выбранные цены/);
  assert.match(api, /CHECKED_SOURCE_DATES_NOT_VERIFIED/);
  assert.match(api, /PRICE_CHANGED_AFTER_SNAPSHOT/);
  assert.match(api, /hotelSyncSameProperty/);
  assert.match(api, /hotelSyncURLContainsDates/);
  assert.match(api, /applyHotelChatGPTUpdate/);
  assert.match(worker, /HOTEL_SYNC_CHECKED_SOURCE_DATES_MISMATCH/);
  assert.match(worker, /HOTEL_SYNC_PROPERTY_MISMATCH/);
  assert.match(worker, /HOTEL_SYNC_PRICE_CHANGED_AFTER_SNAPSHOT/);
  assert.match(worker, /chatgpt-admin-exact-source/);
});

test('hotel importer stays available and Flight Sync files remain separate from Hotel Sync', () => {
  assert.match(hotelsView, /AddHotelView\(\)/);
  assert.match(hotelsView, /Импортировать отель/);
  assert.match(worker, /parts\[0\] === 'flight-sync'/);
  assert.match(flightAPI, /flightSyncStatus/);
  assert.doesNotMatch(flightAPI, /hotelSync/i);
});
