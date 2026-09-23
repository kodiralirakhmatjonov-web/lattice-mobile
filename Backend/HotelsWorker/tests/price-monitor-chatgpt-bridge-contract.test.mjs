import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

const worker = fs.readFileSync(new URL('../src/index.js', import.meta.url), 'utf8');
const migration = fs.readFileSync(new URL('../migrations/0041_business_chatgpt_hotel_access.sql', import.meta.url), 'utf8');
const api = fs.readFileSync(new URL('../../../Sources/Networking/APIClient+HotelSync.swift', import.meta.url), 'utf8');
const models = fs.readFileSync(new URL('../../../Sources/Models/HotelSyncModels.swift', import.meta.url), 'utf8');
const hotelsView = fs.readFileSync(new URL('../../../Sources/Views/HotelsView.swift', import.meta.url), 'utf8');
const syncView = fs.readFileSync(new URL('../../../Sources/Views/HotelPriceMonitoringView.swift', import.meta.url), 'utf8');
const flightAPI = fs.readFileSync(new URL('../../../Sources/Networking/APIClient+FlightSync.swift', import.meta.url), 'utf8');

test('ChatGPT hotel access has one global manual switch persisted in D1', () => {
  assert.match(migration, /business_chatgpt_hotel_access/);
  assert.match(migration, /id TEXT PRIMARY KEY CHECK \(id = 'global'\)/);
  assert.match(worker, /setBusinessChatGPTHotelAccess\(env, user, true\)/);
  assert.match(worker, /setBusinessChatGPTHotelAccess\(env, user, false\)/);
  assert.match(syncView, /Открыть доступ ChatGPT/);
  assert.match(syncView, /Закрыть доступ ChatGPT/);
});

test('live internal feed reads HOTELS_DB on every request with no snapshot, date gate, token or TTL', () => {
  assert.match(worker, /async function businessChatGPTHotelRows/);
  assert.match(worker, /source: 'iumrah_business_HOTELS_DB'/);
  assert.match(worker, /snapshot_id: null/);
  assert.match(worker, /date_gate: false/);
  assert.match(worker, /expires_at: null/);
  assert.match(worker, /parts\[0\] === 'chatgpt-hotels'/);
  assert.match(worker, /publicBusinessChatGPTHotelFeed/);
  assert.doesNotMatch(syncView, /DatePicker\(|Скопировать ссылку|accessURL/);
});

test('MCP exposes only read-only internal hotel tools and is gated by the same manual access switch', () => {
  assert.match(worker, /parts\[0\] === 'chatgpt-mcp'/);
  assert.match(worker, /businessChatGPTHotelAccessEnabled\(env\)/);
  for (const tool of ['list_internal_hotel_databases','search_internal_hotels','get_internal_hotel','export_internal_hotel_prices']) {
    assert.match(worker, new RegExp(`'${tool}'`));
  }
  assert.match(worker, /readOnlyHint: true/);
  assert.match(worker, /type: 'oauth2'/);
  assert.match(worker, /scopes: \['hotels\.read'\]/);
  assert.match(worker, /businessChatGPTHotelOAuthWellKnown/);
  assert.match(worker, /client_id_metadata_document_supported: true/);
  assert.match(worker, /BUSINESS_CHATGPT_OAUTH_REFRESH_TTL_SECONDS/);
});

test('v3 returned-price JSON is snapshot-free and server writes only after live hotel/provider/property/old-price checks', () => {
  assert.match(models, /schemaName = "iumrah\.hotel-price-update\.v3"/);
  assert.match(worker, /BUSINESS_CHATGPT_PRICE_UPDATE_SCHEMA = 'iumrah\.hotel-price-update\.v3'/);
  assert.match(worker, /CHATGPT_HOTEL_PRICE_ALREADY_CHANGED/);
  assert.match(worker, /CHATGPT_HOTEL_PROPERTY_MISMATCH/);
  assert.match(worker, /currentProvider !== update\.provider/);
  assert.match(worker, /hotelSyncSameProperty\(source\.source_url, update\.checked_source_url, currentProvider\)/);
  assert.match(worker, /method='chatgpt-json-v3'|method, status, fetched_at/);

  const applyStart = worker.indexOf('async function applyBusinessChatGPTHotelUpdates');
  const applyEnd = worker.indexOf('const BUSINESS_FLIGHT_SYNC_VERSION', applyStart);
  const applyBody = worker.slice(applyStart, applyEnd);
  assert.doesNotMatch(applyBody, /snapshot_id|snapshotID|INVALID_DATES|INVALID_OCCUPANCY/);
  assert.doesNotMatch(api, /hotelSyncURLContainsDates/);
});

test('Business UI accepts ChatGPT v3 JSON and keeps hotel importer plus Flight Sync separate', () => {
  assert.match(syncView, /TextEditor\(text: \$pastedJSON\)/);
  assert.match(syncView, /iumrah\.hotel-price-update\.v3/);
  assert.match(syncView, /Проверить JSON/);
  assert.match(syncView, /Обновить выбранные цены/);
  assert.match(api, /applyHotelChatGPTUpdate/);
  assert.match(hotelsView, /AddHotelView\(\)/);
  assert.match(hotelsView, /Импортировать отель/);
  assert.match(worker, /parts\[0\] === 'flight-sync'/);
  assert.match(flightAPI, /flightSyncStatus/);
  assert.doesNotMatch(flightAPI, /chatGPTHotel/i);
});
