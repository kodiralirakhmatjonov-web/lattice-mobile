import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

const monitor = fs.readFileSync(new URL('../src/price-monitor.js', import.meta.url), 'utf8');
const worker = fs.readFileSync(new URL('../src/index.js', import.meta.url), 'utf8');
const migration = fs.readFileSync(new URL('../migrations/0035_price_monitor_chatgpt_bridge.sql', import.meta.url), 'utf8');
const wrangler = fs.readFileSync(new URL('../wrangler.template.jsonc', import.meta.url), 'utf8');
const api = fs.readFileSync(new URL('../../../Sources/Networking/APIClient.swift', import.meta.url), 'utf8');
const hotelsView = fs.readFileSync(new URL('../../../Sources/Views/HotelsView.swift', import.meta.url), 'utf8');
const monitorView = fs.readFileSync(new URL('../../../Sources/Views/HotelPriceMonitoringView.swift', import.meta.url), 'utf8');

test('price monitoring is staged and production price cache is only written by explicit publish', () => {
  const probeStart = monitor.indexOf('async function probeHotelPrice');
  const publishStart = monitor.indexOf('async function publishMonitorItem');
  assert.ok(probeStart >= 0 && publishStart > probeStart);
  const probeSection = monitor.slice(probeStart, publishStart);
  assert.doesNotMatch(probeSection, /INSERT INTO hotel_price_cache/i);
  assert.doesNotMatch(probeSection, /UPDATE hotel_price_cache/i);

  const publishSection = monitor.slice(publishStart, monitor.indexOf('async function refreshRunCounters'));
  assert.match(publishSection, /INSERT INTO hotel_price_cache/i);
  assert.match(monitor, /parts\[1\] === 'publish'/);
  assert.match(monitor, /NO_HOTELS_SELECTED/);
});

test('ChatGPT bridge uses short-lived hashed read-only links instead of staff credentials', () => {
  assert.match(migration, /token_hash TEXT NOT NULL UNIQUE/);
  assert.doesNotMatch(migration, /token TEXT NOT NULL/i);
  assert.match(monitor, /crypto\.subtle\.digest\('SHA-256'/);
  assert.match(monitor, /30 \* 60 \* 1000/);
  assert.match(monitor, /readOnly: true/);
  assert.match(monitor, /request\.method !== 'GET'/);
  assert.match(worker, /\/api\/iumrah\/chatgpt\//);
  assert.match(wrangler, /iumrah\.app\/api\/iumrah\/chatgpt\*/);
  assert.match(monitor, /function chatgptText/);
  assert.match(monitor, /'content-type': 'text\/plain; charset=utf-8'/);
  const publicStart = monitor.indexOf('export async function handleChatGPTPublic');
  const publicEnd = monitor.indexOf('export async function runHotelPriceMonitorWorkflow', publicStart);
  const publicSection = monitor.slice(publicStart, publicEnd);
  assert.match(publicSection, /return chatgptText\(/);
  assert.doesNotMatch(publicSection, /return json\(/);
});

test('Cloudflare Workflow and iumrah Business UI expose review and selective publishing', () => {
  assert.match(wrangler, /HOTEL_PRICE_MONITOR_WORKFLOW/);
  assert.match(worker, /class HotelPriceMonitorWorkflow extends WorkflowEntrypoint/);
  assert.match(api, /func startPriceMonitor\(\)/);
  assert.match(api, /func publishPriceMonitor\(runID:/);
  assert.match(api, /func createChatGPTAccessLink\(runID:/);
  assert.match(hotelsView, /HotelPriceMonitoringView\(\)/);
  assert.match(monitorView, /Опубликовать выбранные цены/);
  assert.match(monitorView, /Скопировать доступ к каталогу для ChatGPT/);
  assert.match(monitorView, /Скопировать результаты для ChatGPT/);
});
