import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

const exchange = fs.readFileSync(new URL('../src/price-json.js', import.meta.url), 'utf8');
const worker = fs.readFileSync(new URL('../src/index.js', import.meta.url), 'utf8');
const wrangler = fs.readFileSync(new URL('../wrangler.template.jsonc', import.meta.url), 'utf8');
const api = fs.readFileSync(new URL('../../../Sources/Networking/APIClient.swift', import.meta.url), 'utf8');
const hotelsView = fs.readFileSync(new URL('../../../Sources/Views/HotelsView.swift', import.meta.url), 'utf8');
const exchangeView = fs.readFileSync(new URL('../../../Sources/Views/HotelPriceMonitoringView.swift', import.meta.url), 'utf8');
const detailView = fs.readFileSync(new URL('../../../Sources/Views/HotelAdminDetailView.swift', import.meta.url), 'utf8');

test('old ChatGPT link and Cloudflare monitoring UI are removed from the active architecture', () => {
  assert.doesNotMatch(worker, /handleChatGPTPublic|handlePriceMonitorAdmin|HOTEL_PRICE_MONITOR_WORKFLOW/);
  assert.doesNotMatch(worker, /\/api\/iumrah\/chatgpt\//);
  assert.doesNotMatch(wrangler, /iumrah\.app\/api\/iumrah\/chatgpt/);
  assert.doesNotMatch(wrangler, /HOTEL_PRICE_MONITOR_WORKFLOW|HOTEL_PRICE_MONITOR_ITEM_WORKFLOW/);
  assert.doesNotMatch(wrangler, /"triggers"/);
  assert.doesNotMatch(exchangeView, /Скопировать доступ к каталогу для ChatGPT|Запустить мониторинг цен/);
  assert.doesNotMatch(detailView, /Обновить из источника/);
});

test('JSON exchange exports Makkah and Madinah with stable hotel ids and exact source URLs', () => {
  assert.match(exchange, /iumrah\.hotel-monitor\.v1/);
  assert.match(exchange, /iumrah\.hotel-price-update\.v1/);
  assert.match(exchange, /currentNightlyUSD/);
  assert.match(exchange, /sourceURL/);
  assert.match(exchange, /preferredDateOffsetsDays: \[20, 25, 30\]/);
  assert.match(exchange, /Use the supplied sourceURL for the exact hotel/);
  assert.match(api, /func hotelPriceJSONExport\(city:/);
  assert.match(hotelsView, /Экспорт JSON → ChatGPT → импорт результата/);
  assert.match(exchangeView, /Makkah/);
  assert.match(exchangeView, /Madinah/);
  assert.match(exchangeView, /Экспорт JSON/);
});

test('import is preview-first and production prices require explicit selected apply', () => {
  const previewStart = exchange.indexOf("parts[0] === 'preview'");
  const applyStart = exchange.indexOf("parts[0] === 'apply'");
  assert.ok(previewStart >= 0 && applyStart > previewStart);
  assert.match(exchange, /PRICE_CHANGED_AFTER_EXPORT/);
  assert.match(exchange, /SOURCE_CHANGED/);
  assert.match(exchange, /LOW_CONFIDENCE/);
  assert.match(exchange, /DELETE FROM hotel_price_overrides WHERE hotel_id=\?/);
  assert.match(exchange, /chatgpt-json-import:/);
  assert.match(exchangeView, /Ничего ещё не опубликовано/);
  assert.match(exchangeView, /Обновить выбранные цены/);
  assert.match(api, /func previewHotelPriceJSON/);
  assert.match(api, /func applyHotelPriceJSON/);
});

test('the hotel importer remains present for adding hotels', () => {
  assert.match(hotelsView, /AddHotelView\(\)/);
  assert.match(hotelsView, /Импортировать отель/);
});
