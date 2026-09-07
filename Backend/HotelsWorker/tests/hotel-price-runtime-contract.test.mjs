import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

const worker = fs.readFileSync(new URL('../src/index.js', import.meta.url), 'utf8');

test('Hotels Worker exposes manual hotel price refresh route', () => {
  assert.match(worker, /parts\[1\]\s*===\s*'price'\s*&&\s*parts\[2\]\s*===\s*'refresh'/);
  assert.match(worker, /refreshHotelPriceResponse\(env,\s*hotelID/);
});

test('Hotels Worker has scheduled price maintenance handler', () => {
  assert.match(worker, /async scheduled\(controller,\s*env,\s*ctx\)/);
  assert.match(worker, /runHotelPriceMaintenance\(env/);
  assert.match(worker, /HOTEL_PRICE_TTL_MS/);
});

test('imported WKWebView price is persisted into hotel_price_cache', () => {
  assert.match(worker, /persistImportedHotelPriceSnapshots\(env,\s*id,\s*sources\)/);
  assert.match(worker, /INSERT INTO hotel_price_cache/);
  assert.match(worker, /importedPriceAvailable/);
  assert.match(worker, /HOTEL_PRICE_REQUIRED/);
});

test('hotel list returns cached price fields to iumrah Business', () => {
  assert.match(worker, /LEFT JOIN hotel_price_cache hp ON hp\.hotel_id = h\.id/);
  assert.match(worker, /price_nightly_price_usd/);
  assert.match(worker, /price:\s*hotelPriceFromRow\(row\)/);
});

test('failed refresh preserves last known price and schedules retry', () => {
  assert.match(worker, /status=CASE WHEN hotel_price_cache\.nightly_price_usd IS NOT NULL THEN 'stale' ELSE 'failed' END/);
  assert.match(worker, /HOTEL_PRICE_RETRY_MS/);
});

test('large hotel price jumps are staged instead of replacing the accepted price immediately', () => {
  assert.match(worker, /PRICE_CHANGE_AWAITING_CONFIRMATION/);
  assert.match(worker, /pending_nightly_price_usd/);
  assert.match(worker, /pending_seen_count/);
  assert.match(worker, /hotelPriceMoveNeedsConfirmation/);
});


test('price refresh is exact-source only and has no alternate URL or static fallback', () => {
  assert.match(worker, /ensureHotelPriceSourceLock\(env, hotelID\)/);
  assert.match(worker, /readExactHotelSourcePage\(env, sourceURL\)/);

  // Scope the negative contract to price refresh. Room recovery is a separate
  // admin utility and may probe availability dates without being used for price.
  const start = worker.indexOf('async function fetchExactHotelSourcePrice');
  const end = worker.indexOf('async function health', start);
  const refreshImplementation = worker.slice(start, end);
  assert.doesNotMatch(refreshImplementation, /buildHotelPriceProbeURLs/);
  assert.doesNotMatch(refreshImplementation, /staticHotelHTML\(/);
  assert.doesNotMatch(refreshImplementation, /roomRecoveryProbeURLs/);
  assert.doesNotMatch(refreshImplementation, /source-rooms/);
});

test('hotel list exposes locked source URL only to Business admin summaries', () => {
  assert.match(worker, /LEFT JOIN hotel_price_sources hps ON hps\.hotel_id = h\.id/);
  assert.match(worker, /sourceProvider:\s*includeSource/);
  assert.match(worker, /sourceURL:\s*includeSource/);
});


test('manual hotel price override is returned by both admin and client hotel summaries', () => {
  assert.match(worker, /LEFT JOIN hotel_price_overrides hpo ON hpo\.hotel_id = h\.id/);
  assert.match(worker, /const effectiveNightly = hasManual \? manualNightly : sourceNightly/);
  assert.match(worker, /nightlyUSD:\s*effectiveNightly/);
  assert.match(worker, /const sourceStatus = hasManual \? 'manual' : row\.price_status/);
});

test('successful source refresh removes the manual hotel price override only after a real source price is persisted', () => {
  const start = worker.indexOf('async function fetchExactHotelSourcePrice');
  const end = worker.indexOf('async function refreshHotelPriceResponse', start);
  const implementation = worker.slice(start, end);
  const persistAt = implementation.indexOf('INSERT INTO hotel_price_cache');
  const clearAt = implementation.indexOf("DELETE FROM hotel_price_overrides WHERE hotel_id=?");
  assert.ok(persistAt >= 0, 'source price cache write is missing');
  assert.ok(clearAt > persistAt, 'manual override must only be cleared after a successful source cache write');
});


test('scheduled maintenance actively refreshes due published hotel prices and preserves manual overrides', () => {
  const start = worker.indexOf('async function runHotelPriceMaintenance');
  const end = worker.indexOf('async function setManualHotelPrice', start);
  const implementation = worker.slice(start, end);
  assert.match(implementation, /JOIN hotel_price_sources hps ON hps\.hotel_id=h\.id/);
  assert.match(implementation, /LIMIT 3/);
  assert.match(implementation, /fetchExactHotelSourcePrice\(env, hotelID, \{ clearManualOverride: false \}\)/);
  assert.match(implementation, /markHotelPriceRefreshFailure\(env, hotelID, code\)/);
});

test('public catalog keeps a last-known stale or manual price usable for package generation', () => {
  assert.match(worker, /options\.publicUsable === true/);
  assert.match(worker, /publicStatus = publicUsable && \(hasManual \|\| usingFallback\) \? 'fresh' : sourceStatus/);
  assert.match(worker, /fallbackPrice: usingFallback/);
  assert.match(worker, /hotelSummary\(row, !publishedOnly, \{ publicUsablePrice: publishedOnly \}\)/);
});

test('public Primary Hotels include the same price cache and manual override as the main catalog', () => {
  const start = worker.indexOf('async function publicPrimaryHotels');
  const end = worker.indexOf('async function handleClientOperations', start);
  const implementation = worker.slice(start, end);
  assert.match(implementation, /LEFT JOIN hotel_price_cache hp ON hp\.hotel_id=h\.id/);
  assert.match(implementation, /LEFT JOIN hotel_price_overrides hpo ON hpo\.hotel_id=h\.id/);
  assert.match(implementation, /HOTEL_PRICE_SELECT/);
  assert.match(implementation, /publicUsablePrice: true/);
});

test('Business team photo endpoint supports authenticated read, upload and delete', () => {
  assert.match(worker, /parts\[2\] === 'photo'/);
  assert.match(worker, /request\.method === 'GET'\) return serveAdminTeamMemberPhoto/);
  assert.match(worker, /request\.method === 'POST'\) return uploadTeamMemberPhoto/);
  assert.match(worker, /request\.method === 'DELETE'\) return deleteTeamMemberPhoto/);
  assert.match(worker, /team-photos\/\$\{memberID\}/);
});

test('eSIM Access Business routes are permanent Worker endpoints rather than deploy-time data', () => {
  assert.match(worker, /parts\[0\] === 'esim-access'/);
  assert.match(worker, /adminEsimAccessBalance\(env\)/);
  assert.match(worker, /adminEsimAccessPackages\(env, url\)/);
  assert.match(worker, /adminEsimAccessInventory\(env\)/);
  assert.match(worker, /api\.esimaccess\.com\/api\/v1\/open/);
});

test('Ignav usage endpoint reads the shared monthly counter without exposing the Ignav API key to iOS', () => {
  assert.match(worker, /parts\[0\] === 'ignav-usage'/);
  assert.match(worker, /FROM ignav_api_usage_monthly/);
  assert.match(worker, /IGNAV_MONTHLY_REQUEST_BUDGET/);
});
