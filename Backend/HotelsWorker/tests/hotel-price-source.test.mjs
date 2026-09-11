import test from 'node:test';
import assert from 'node:assert/strict';
import { obtainHotelPrice, preparePriceURL, propertyKey, priceSourceURL, expediaPriceProbeURLs } from '../src/hotel-price-source.js';
import { extractHotelPriceFromHTML } from '../src/hotel-price.js';
const now = Date.parse('2026-09-09T12:00:00Z');
const booking = 'https://www.booking.com/hotel/sa/example.en-gb.html';
const expedia = 'https://www.expedia.com/Medina-Hotels-Example.h1234.Hotel-Information';
const html = content => `<html><body><h1>Example hotel</h1>${content}<p>${'description '.repeat(40)}</p></body></html>`;
const bookingHTML = html('<table id="hprt-table"><tr><td><span class="bui-price-display__value">US$ 120</span></td></tr></table>');
const expediaHTML = html('<div class="uitk-lockup-price">SAR 450 per night</div>');

test('opaque Share URL is resolved before dates are appended', () => {
  assert.equal(preparePriceURL('https://www.booking.com/Share-kDKgaGY', 'Booking', now), 'https://www.booking.com/Share-kDKgaGY');
  assert.equal(propertyKey(booking, 'Booking'), 'sa/example');
  assert.equal(propertyKey(booking.replace('.en-gb', '.ru'), 'Booking'), 'sa/example');
});

test('expired, absent, reversed or impossible dates become one night tomorrow for both providers', () => {
  for (const [provider, base, a, b] of [['Booking', booking, 'checkin', 'checkout'], ['Expedia', expedia, 'chkin', 'chkout']]) {
    for (const dates of ['', `?${a}=2026-01-01&${b}=2026-01-05`, `?${a}=2027-02-30&${b}=2027-03-04`, `?${a}=2026-10-04&${b}=2026-10-01`]) {
      const url = new URL(preparePriceURL(base + dates, provider, now));
      assert.equal(url.searchParams.get(a), '2026-09-10');
      assert.equal(url.searchParams.get(b), '2026-09-11');
    }
  }
});

test('future stay dates persist and source is not mutated; occupancy is normalized', () => {
  const source = `${expedia}?chkin=2026-10-10&chkout=2026-10-13&rm1=a4&rm2=a3&children=4`;
  const url = new URL(preparePriceURL(source, 'Expedia', now));
  assert.equal(url.searchParams.get('chkout'), '2026-10-13');
  assert.equal(url.searchParams.get('rm1'), 'a2');
  assert.equal(url.searchParams.has('rm2'), false);
  assert.equal(url.searchParams.has('children'), false);
  assert.ok(source.includes('rm2=a3'));
});

test('fresh direct Expedia source converts SAR without launching browser', async () => {
  const result = await obtainHotelPrice({}, expedia, 'Expedia', { now,
    fetcher: async () => new Response(expediaHTML), render: () => assert.fail('browser unnecessary') });
  assert.equal(result.extracted.nightlyUSD, 120);
  assert.equal(result.quote.nights, 1);
  assert.equal(result.transport, 'http');
});

test('share redirect loses query: canonical property is fetched again with dates', async () => {
  const requested = [];
  const result = await obtainHotelPrice({}, 'https://www.booking.com/Share-kDKgaGY', 'Booking', { now,
    fetcher: async url => {
      requested.push(url);
      if (url.includes('Share-')) return new Response(null, { status: 302, headers: { location: booking } });
      return new Response(url.includes('checkin=') ? bookingHTML : html('Select dates'));
    }, render: () => assert.fail('direct canonical price exists') });
  assert.equal(requested.length, 3);
  assert.equal(result.quote.checkIn, '2026-09-10');
  assert.equal(result.extracted.nightlyUSD, 120);
});

test('JavaScript-only source invokes browser and extracts rendered price', async () => {
  let calls = 0;
  const result = await obtainHotelPrice({}, booking, 'Booking', { now,
    fetcher: async () => new Response(html('Loading availability')),
    render: async (env, url) => { calls++; return { html: bookingHTML, finalURL: url, httpStatus: 200, transport: 'browser' }; }
  });
  assert.equal(calls, 1);
  assert.equal(result.transport, 'browser');
  assert.equal(result.extracted.nightlyUSD, 120);
});

test('trusted browser renderer accepts Booking SPA canonicalization after verified quote navigation', async () => {
  const result = await obtainHotelPrice({}, booking, 'Booking', { now,
    fetcher: async () => new Response(html('Loading availability')),
    render: async (env, url) => ({
      html: bookingHTML,
      finalURL: booking,
      quoteURL: url,
      httpStatus: 200,
      transport: 'browser',
      contextVerified: true
    })
  });
  assert.equal(result.quote.checkIn, '2026-09-10');
  assert.equal(result.quote.checkOut, '2026-09-11');
  assert.equal(result.extracted.nightlyUSD, 120);
});

test('browser challenge does not become a successful quote', async () => {
  await assert.rejects(obtainHotelPrice({}, booking, 'Booking', { now,
    fetcher: async () => new Response('', { status: 403 }),
    render: async (env, url) => ({ html: '<title>Access denied</title>' + bookingHTML, finalURL: url })
  }), /HOTEL_PRICE_SOURCE_CHALLENGE/);
});

test('different property and off-provider redirect are rejected before follow-up fetch', async () => {
  for (const location of [booking.replace('example', 'another'), 'https://expedia.com.attacker.invalid/a', 'http://127.0.0.1/']) {
    let calls = 0;
    await assert.rejects(obtainHotelPrice({}, booking, 'Booking', { now,
      fetcher: async () => { calls++; return new Response(null, { status: 302, headers: { location } }); },
      render: () => assert.fail('must not render another property')
    }), /MISMATCH|BAD_REDIRECT/);
    if (!location.includes('another')) assert.equal(calls, 1);
  }
  assert.throws(() => priceSourceURL('https://expedia.com.attacker.invalid', 'Expedia'), /MISMATCH/);
});

test('rendered date-less teaser and other property are never accepted', async () => {
  for (const finalURL of [booking, preparePriceURL(booking.replace('example', 'different'), 'Booking', now)]) {
    await assert.rejects(obtainHotelPrice({}, booking, 'Booking', { now,
      fetcher: async () => new Response(html('Loading')),
      render: async () => ({ finalURL, html: bookingHTML })
    }), /MISMATCH/);
  }
});


test('Expedia probe ladder stays on one property and normalizes two-adult USD occupancy', () => {
  const probes = expediaPriceProbeURLs(expedia, now);
  assert.equal(probes.length, 6);
  assert.deepEqual(probes.map(value => new URL(value).searchParams.get('chkin')), [
    '2026-09-10', '2026-09-12', '2026-09-16', '2026-09-23', '2026-09-30', '2026-10-09'
  ]);
  for (const value of probes) {
    const url = new URL(value);
    assert.equal(propertyKey(value, 'Expedia'), '1234');
    assert.equal(url.searchParams.get('rm1'), 'a2');
    assert.equal(url.searchParams.get('rooms'), '1');
    assert.equal(url.searchParams.get('currency'), 'USD');
    assert.equal(url.searchParams.get('top_cur'), 'USD');
  }
});

test('Expedia sold-out first date falls through to a later date for the same hotel before browser rendering', async () => {
  const requested = [];
  const result = await obtainHotelPrice({}, expedia, 'Expedia', {
    now,
    fetcher: async url => {
      requested.push(url);
      const date = new URL(url).searchParams.get('chkin');
      return new Response(date === '2026-09-16' ? expediaHTML : html('No rooms available for these dates'));
    },
    renderMany: () => assert.fail('same-property SSR fallback should avoid browser')
  });
  assert.equal(result.quote.checkIn, '2026-09-16');
  assert.equal(result.extracted.nightlyUSD, 120);
  assert.equal(requested.length, 3);
  assert.ok(requested.every(value => propertyKey(value, 'Expedia') === '1234'));
});

test('Expedia browser fallback receives the bounded same-property date ladder once', async () => {
  let renderManyCalls = 0;
  const result = await obtainHotelPrice({}, expedia, 'Expedia', {
    now,
    fetcher: async () => new Response(html('Availability loads in JavaScript')),
    renderMany: async (env, probes, expectedKey) => {
      renderManyCalls += 1;
      assert.equal(expectedKey, '1234');
      assert.equal(probes.length, 6);
      const quoteURL = probes[1];
      return {
        html: expediaHTML, finalURL: quoteURL, quoteURL, httpStatus: 200, transport: 'browser', contextVerified: true,
        quote: { checkIn: '2026-09-12', checkOut: '2026-09-13', nights: 1, adults: 2, rooms: 1 },
        extracted: extractHotelPriceFromHTML(expediaHTML, 'Expedia', 1)
      };
    }
  });
  assert.equal(renderManyCalls, 1);
  assert.equal(result.extracted.nightlyUSD, 120);
});

test('Booking price element does not consume following tax or neighbouring room prices', () => {
  const result = extractHotelPriceFromHTML(html('<span data-testid="price-and-discounted-price">US$ 120</span><div>US$ 240</div>'), 'Booking', 1);
  assert.equal(result.nightlyUSD, 120);
});

test('Booking AWS WAF on a Share link reports a challenge, never a price', async () => {
  await assert.rejects(obtainHotelPrice({}, 'https://www.booking.com/Share-kDKgaGY', 'Booking', { now,
    fetcher: async () => new Response('<script>window.awsWafCookieDomainList = ["booking.com"];</script>'),
    render: async () => ({ finalURL: 'https://www.booking.com/Share-kDKgaGY', html: '<script>window.awsWafCookieDomainList = ["booking.com"];</script>' })
  }), /HOTEL_PRICE_SOURCE_CHALLENGE/);
});
