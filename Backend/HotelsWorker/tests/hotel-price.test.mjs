import test from 'node:test';
import assert from 'node:assert/strict';
import {
  HOTEL_PRICE_QUOTE_NIGHTS,
  buildHotelPriceProbeURLs,
  extractHotelPriceFromHTML,
  quoteContextFromProbeURL,
  normalizeImportedHotelPriceSnapshot
} from '../src/hotel-price.js';

const padding = '<div>' + 'hotel property content '.repeat(30) + '</div>';

test('Booking explicit stay total normalizes to nightly USD', () => {
  const html = `<html><body>${padding}<div data-testid="price-for-x-nights"><span>US$ 320</span><span>2 nights, 2 adults</span></div></body></html>`;
  const price = extractHotelPriceFromHTML(html, 'Booking', 2);
  assert.equal(price?.currency, 'USD');
  assert.equal(price?.priceBasis, 'stay_total');
  assert.equal(price?.stayTotalUSD, 320);
  assert.equal(price?.nightlyUSD, 160);
});

test('Expedia explicit per-night price stays nightly', () => {
  const html = `<html><body>${padding}<div class="uitk-lockup-price">$180 per night</div></body></html>`;
  const price = extractHotelPriceFromHTML(html, 'Expedia', 2);
  assert.equal(price?.priceBasis, 'nightly');
  assert.equal(price?.nightlyUSD, 180);
  assert.equal(price?.stayTotalUSD, 360);
});

test('SAR price is normalized using the Saudi peg', () => {
  const html = `<html><body>${padding}<div data-testid="price-for-x-nights"><span>SAR 750</span><span>2 nights</span></div></body></html>`;
  const price = extractHotelPriceFromHTML(html, 'Booking', 2);
  assert.equal(price?.currency, 'SAR');
  assert.equal(price?.stayTotalUSD, 200);
  assert.equal(price?.nightlyUSD, 100);
});

test('ambiguous currency numbers are rejected instead of guessed', () => {
  const html = `<html><body>${padding}<div>Rating 9.4 · 1200 reviews · breakfast 45</div></body></html>`;
  assert.equal(extractHotelPriceFromHTML(html, 'Booking', 2), null);
});

test('recommendation prices after property boundary are ignored', () => {
  const html = `<html><body>${padding}<div data-testid="price-for-x-nights">US$ 600 · 2 nights</div><h2>You may also like</h2><div data-testid="price-for-x-nights">US$ 40 · 2 nights</div></body></html>`;
  const price = extractHotelPriceFromHTML(html, 'Booking', 2);
  assert.equal(price?.stayTotalUSD, 600);
});

test('Booking probe URL has deterministic benchmark context and USD currency', () => {
  const now = Date.UTC(2026, 8, 3, 0, 0, 0);
  const [url] = buildHotelPriceProbeURLs('https://www.booking.com/hotel/sa/example.html', 'Booking', now);
  const parsed = new URL(url);
  assert.equal(parsed.searchParams.get('checkin'), '2026-09-17');
  assert.equal(parsed.searchParams.get('checkout'), '2026-09-18');
  assert.equal(parsed.searchParams.get('group_adults'), '2');
  assert.equal(parsed.searchParams.get('no_rooms'), '1');
  assert.equal(parsed.searchParams.get('selected_currency'), 'USD');
  const context = quoteContextFromProbeURL(url, 'Booking');
  assert.equal(context.nights, HOTEL_PRICE_QUOTE_NIGHTS);
  assert.equal(context.adults, 2);
  assert.equal(context.rooms, 1);
});

test('Expedia probe keeps exact path and adds dates', () => {
  const now = Date.UTC(2026, 8, 3, 0, 0, 0);
  const urls = buildHotelPriceProbeURLs('https://www.expedia.com/Makkah-Hotels-Test.h123456.Hotel-Information', 'Expedia', now);
  assert.ok(urls.length >= 2);
  for (const value of urls) {
    const url = new URL(value);
    assert.match(url.pathname, /\.h123456\.Hotel-Information$/i);
    assert.ok(['2026-09-17', '2026-10-18'].includes(url.searchParams.get('chkin')));
    assert.ok(['2026-09-18', '2026-10-19'].includes(url.searchParams.get('chkout')));
    assert.equal(url.searchParams.get('currency'), 'USD');
  }
});

test('Booking discounted-price token without stay/night basis is rejected', () => {
  const html = `<html><body>${padding}<span data-testid="price-and-discounted-price">US$ 240</span><div>Great location · 9.1 rating</div></body></html>`;
  assert.equal(extractHotelPriceFromHTML(html, 'Booking', 2), null);
});


test('Booking one-night first visible room price is accepted as nightly', () => {
  const html = `<html><body>${padding}<div data-testid="property-card"><span data-testid="price-and-discounted-price">SAR 315</span><span>Double Room</span></div></body></html>`;
  const price = extractHotelPriceFromHTML(html, 'Booking', 1);
  assert.equal(price?.currency, 'SAR');
  assert.equal(price?.priceBasis, 'nightly');
  assert.equal(price?.nightlyUSD, 84);
  assert.equal(price?.stayTotalUSD, 84);
});

test('Expedia one-night price lockup keeps first displayed price as nightly', () => {
  const html = `<html><body>${padding}<div class="uitk-lockup-price">SAR 315 <span>SAR 380 total</span></div></body></html>`;
  const price = extractHotelPriceFromHTML(html, 'Expedia', 1);
  assert.equal(price?.currency, 'SAR');
  assert.equal(price?.priceBasis, 'nightly');
  assert.equal(price?.nightlyUSD, 84);
});


test('live iOS importer price is normalized for D1 cache without another provider request', () => {
  const price = normalizeImportedHotelPriceSnapshot({
    amount: 315,
    currency: 'SAR',
    totalAmount: 380,
    totalCurrency: 'SAR',
    priceBasis: 'nightly',
    checkIn: '2026-09-17',
    checkOut: '2026-09-18',
    nights: 1,
    adults: 2,
    rooms: 1,
    roomName: 'Double Room',
    method: 'expedia-dom-price',
    confidence: 0.98
  });
  assert.equal(price?.currencyOriginal, 'SAR');
  assert.equal(price?.nightlyUSD, 84);
  assert.equal(price?.stayTotalUSD, 101.33);
  assert.equal(price?.nights, 1);
  assert.equal(price?.method, 'expedia-dom-price');
});

test('imported stay total is divided by exact nights once', () => {
  const price = normalizeImportedHotelPriceSnapshot({
    amount: 750,
    currency: 'SAR',
    priceBasis: 'stay_total',
    nights: 2,
    adults: 2,
    rooms: 1,
    method: 'booking-price-for-x-nights',
    confidence: 0.99
  });
  assert.equal(price?.nightlyUSD, 100);
  assert.equal(price?.stayTotalUSD, 200);
});
