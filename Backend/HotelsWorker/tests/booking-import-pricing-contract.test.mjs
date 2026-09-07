import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

const worker = fs.readFileSync(new URL('../src/index.js', import.meta.url), 'utf8');
const importer = fs.readFileSync(new URL('../../../Sources/Hotels/HotelImportCoordinator.swift', import.meta.url), 'utf8');
const hotelDetail = fs.readFileSync(new URL('../../../Sources/Views/HotelAdminDetailView.swift', import.meta.url), 'utf8');
const bookingDetail = fs.readFileSync(new URL('../../../Sources/Views/BookingDetailView.swift', import.meta.url), 'utf8');

// Expedia is intentionally the untouched branch. Booking gets its own operational URL,
// gallery enrichment and live-browser price refresh without changing Expedia behavior.
test('Booking importer gets Booking-only USD quote context while Expedia keeps original URL', () => {
  assert.match(importer, /let navigationURL = provider == \.booking \? Self\.bookingOperationalURL\(normalized\) : normalized/);
  assert.match(importer, /set\("selected_currency", "USD"\)/);
  assert.match(importer, /if provider == \.booking \{ await captureBookingEmbeddedMedia\(\) \}/);
  assert.match(importer, /structuredPropertyImages/);
  assert.match(importer, /provider === 'Booking'/);
});

test('Booking source refresh can persist a device-verified live price into the existing D1 cache', () => {
  assert.match(worker, /parts\[1\] === 'price' && parts\[2\] === 'browser'/);
  assert.match(worker, /async function saveBrowserHotelPrice/);
  assert.match(worker, /HOTEL_BROWSER_PRICE_BOOKING_ONLY/);
  assert.match(worker, /INSERT INTO hotel_price_cache/);
  assert.match(worker, /DELETE FROM hotel_price_overrides WHERE hotel_id=\?/);
  assert.match(hotelDetail, /BookingLivePriceReader/);
  assert.match(hotelDetail, /saveBrowserHotelPrice/);
  assert.match(hotelDetail, /Последняя рабочая цена остаётся активной/);
});

test('Booking server refresh probes stable USD availability context without changing Expedia source URL', () => {
  assert.match(worker, /function bookingPriceProbeURL/);
  assert.match(worker, /provider === 'Booking' \? bookingPriceProbeURL\(sourceURL\) : sourceURL/);
  assert.match(worker, /selected_currency/);
  assert.match(worker, /group_adults/);
});

test('legacy hood-price component rows use Russian business names instead of JSON paths', () => {
  assert.match(worker, /function legacyPricingComponentLabel/);
  assert.match(worker, /'Авиабилет', 'Отель в Мекке', 'Отель в Медине', 'Виза', 'Питание', 'Трансфер'/);
  assert.match(worker, /label: russianPricingComponentLabel/);
  assert.match(worker, /group: 'Компоненты'/);
  assert.doesNotMatch(bookingDetail, /Text\(component\.label\)\.font\(\.subheadline\)/);
  assert.match(bookingDetail, /russianPricingComponentLabel\(code: component\.code, fallback: component\.label\)/);
});

test('legacy 10-component package is rendered with the original Russian component sequence', () => {
  const start = worker.indexOf('function humanizeFieldKey');
  const end = worker.indexOf('function flattenRequestFields', start);
  assert.ok(start >= 0 && end > start);
  const implementation = worker.slice(start, end);
  const helpers = new Function(`
    function deepScalar(value, keys) {
      for (const key of keys) if (value && value[key] != null) return value[key];
      return null;
    }
    ${implementation}
    return { flattenPricingLines };
  `)();
  const snapshot = {
    currency: 'USD',
    context: { includeMadinah: true },
    selectedPricingInputs: { madinahHotel: { amountUsd: 45.47 } },
    components: [1296, 246, 90.94, 240, 180, 300, 300, 100, 100, 0].map(supplierCostUsd => ({ supplierCostUsd }))
  };
  const labels = helpers.flattenPricingLines(snapshot)
    .filter(line => line.group === 'Компоненты')
    .map(line => line.label);
  assert.deepEqual(labels, [
    'Авиабилет', 'Отель в Мекке', 'Отель в Медине', 'Виза', 'Питание',
    'Трансфер', 'Гид', 'Зиярат в Мекке', 'Зиярат в Медине', 'iumrah Care'
  ]);
});
