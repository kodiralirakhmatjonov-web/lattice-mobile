import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

const worker = fs.readFileSync(new URL('../src/index.js', import.meta.url), 'utf8');
const importer = fs.readFileSync(new URL('../../../Sources/Hotels/HotelImportCoordinator.swift', import.meta.url), 'utf8');
const hotelDetail = fs.readFileSync(new URL('../../../Sources/Views/HotelAdminDetailView.swift', import.meta.url), 'utf8');
const bookingDetail = fs.readFileSync(new URL('../../../Sources/Views/BookingDetailView.swift', import.meta.url), 'utf8');
const pricingEditor = fs.readFileSync(new URL('../../../Sources/Views/BookingPricingEditorSheet.swift', import.meta.url), 'utf8');

// Expedia is intentionally untouched. Booking first resolves Share-* to the real hotel,
// then uses a separate USD-only quote probe so property parsing and pricing cannot interfere.
test('Booking importer resolves Share first and obtains price only from USD quote context', () => {
  assert.match(importer, /always open the exact URL the user pasted first/);
  assert.match(importer, /recoverBookingPriceInBrowser\(propertyURL: currentURL\)/);
  assert.match(importer, /price\.currency\.uppercased\(\) == "USD"/);
  assert.match(importer, /primeBookingUSDCurrency/);
  assert.match(importer, /cur_curr/);
  assert.match(importer, /bookingUSDCurrencyBootstrapURL/);
  assert.match(importer, /set\("selected_currency", "USD"\)/);
  assert.match(importer, /set\("cur_currency", "USD"\)/);
  assert.match(importer, /set\("lang", "en-us"\)/);
  assert.match(importer, /if provider == \.booking \{ await captureBookingEmbeddedMedia\(\) \}/);
  assert.match(importer, /structuredPropertyImages/);
  assert.match(importer, /provider === 'Booking'/);
});

test('Booking source refresh persists only a device-verified USD price into the existing D1 cache', () => {
  assert.match(worker, /parts\[1\] === 'price' && parts\[2\] === 'browser'/);
  assert.match(worker, /async function saveBrowserHotelPrice/);
  assert.match(worker, /HOTEL_BROWSER_PRICE_BOOKING_ONLY/);
  assert.match(worker, /HOTEL_BROWSER_PRICE_USD_REQUIRED/);
  assert.match(worker, /normalized\.currencyOriginal !== 'USD'/);
  assert.match(worker, /INSERT INTO hotel_price_cache/);
  assert.match(worker, /DELETE FROM hotel_price_overrides WHERE hotel_id=\?/);
  assert.match(hotelDetail, /BookingLivePriceReader/);
  assert.match(hotelDetail, /price\.currency\.uppercased\(\) == "USD"/);
  assert.match(hotelDetail, /APIClient.shared.refreshHotelPrice/);
  assert.match(hotelDetail, /Цена проверена в источнике и подтверждена/);
});

test('Booking and Expedia source refresh share the server price reader', () => {
  assert.match(worker, /obtainHotelPrice\(env, priceURL, provider\)/);
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
    components: [1296, 246, 90.94, 240, 180, 300, 300, 100, 100, 0].map(supplierCostUsd => ({ supplierCostUsd })),
    totals: { markupRate: 0.5, paymentFeeRate: 0.02 }
  };
  const lines = helpers.flattenPricingLines(snapshot);
  const labels = lines.filter(line => line.group === 'Компоненты').map(line => line.label);
  assert.deepEqual(labels, [
    'Авиабилет', 'Отель в Мекке', 'Отель в Медине', 'Виза', 'Питание',
    'Трансфер', 'Гид', 'Зиярат в Мекке', 'Зиярат в Медине', 'iumrah Care'
  ]);
  assert.equal(lines.some(line => /Ставка (наценки|комиссии)/.test(line.label)), false);
});

test('Business pricing editor changes money components while package percentage rates stay locked', () => {
  assert.match(pricingEditor, /Изменяйте себестоимость каждого компонента в USD/);
  assert.match(pricingEditor, /fixedPercentRow\("Наценка", rate: markupRate\)/);
  assert.match(pricingEditor, /fixedPercentRow\("Комиссия оплаты", rate: feeRate\)/);
  assert.match(pricingEditor, /Image\(systemName: "lock\.fill"\)/);
  assert.doesNotMatch(pricingEditor, /TextField\("0", text: \$markupPercent\)/);
  assert.doesNotMatch(pricingEditor, /TextField\("0", text: \$feePercent\)/);
  assert.match(worker, /const markupRate = Number\(report\?\.totals\?\.markupRate\)/);
  assert.match(worker, /const paymentFeeRate = Number\(report\?\.totals\?\.paymentFeeRate\)/);
});

test('persisted complete pricing snapshot can be edited even if an older booking lacks quoteId', () => {
  const start = worker.indexOf('async function generatorPricingReportForBooking');
  const end = worker.indexOf('function normalizeSecurityName', start);
  const implementation = worker.slice(start, end);
  assert.match(implementation, /Array\.isArray\(item\?\.components\)/);
  assert.match(implementation, /item\?\.context/);
  assert.match(implementation, /item\?\.selectedPricingInputs/);
  assert.match(implementation, /quoteId: cleanText\(directPricing\.quoteId, 180\) \|\| `booking-\$\{bookingID\}`/);
  assert.match(worker, /pricingReport: reportWithPricingOverride\(await generatorPricingReportForBooking\(env, bookingID, pricingReportSource\)/);
});
