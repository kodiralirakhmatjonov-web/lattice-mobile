import { extractHotelPriceFromHTML, quoteContextFromProbeURL } from './hotel-price.js';

const DAY = 86400000;
export function priceSourceURL(value, provider) {
  const url = new URL(value);
  const host = url.hostname.toLowerCase();
  const allowed = provider === 'Booking'
    ? /(^|\.)booking\.com$/.test(host)
    : provider === 'Expedia' && /(^|\.)expedia\.(com|co\.uk|ca|de|fr|it|es|com\.au|co\.jp|co\.in|com\.sa|ae)$/.test(host);
  if (!allowed || url.protocol !== 'https:' || url.username || url.password || (url.port && url.port !== '443')) {
    throw new Error('HOTEL_PRICE_SOURCE_REDIRECT_MISMATCH');
  }
  return url;
}

export function propertyKey(value, provider) {
  const url = priceSourceURL(value, provider);
  if (provider === 'Booking') {
    const match = url.pathname.match(/^\/hotel\/([^/]+)\/([^/]+?)(?:\.[a-z]{2}(?:-[a-z]{2})?)?\.html\/?$/i);
    return match ? `${match[1]}/${match[2]}`.toLowerCase() : null;
  }
  return /\.h(\d+)\.Hotel-Information/i.exec(url.pathname)?.[1] || null;
}

// A catalogue rate is a benchmark for one room / two adults, not a trip quote.
// Preserve valid future source dates. Missing/expired dates roll to tomorrow for
// one night. Never alter the immutable imported link in hotel_price_sources.
export function preparePriceURL(value, provider, now = Date.now()) {
  const url = priceSourceURL(value, provider);
  if (!propertyKey(url, provider)) return url.toString(); // Resolve Share before adding parameters.
  const p = url.searchParams;
  const inKey = provider === 'Booking' ? 'checkin' : 'chkin';
  const outKey = provider === 'Booking' ? 'checkout' : 'chkout';
  const validDate = value => /^\d{4}-\d{2}-\d{2}$/.test(value || '') &&
    Number.isFinite(Date.parse(value)) && new Date(value).toISOString().slice(0, 10) === value;
  const start = p.get(inKey), end = p.get(outKey);
  const today = new Date(now).toISOString().slice(0, 10);
  if (!validDate(start) || !validDate(end) || start <= today || end <= start || Date.parse(end) - Date.parse(start) > 30 * DAY) {
    p.set(inKey, new Date(now + DAY).toISOString().slice(0, 10));
    p.set(outKey, new Date(now + 2 * DAY).toISOString().slice(0, 10));
  }
  if (provider === 'Booking') {
    for (const [key, value] of Object.entries({ selected_currency: 'USD', cur_currency: 'USD', lang: 'en-us', group_adults: '2', req_adults: '2', group_children: '0', req_children: '0', no_rooms: '1', room1: 'A,A' })) p.set(key, value);
    for (const key of ['age', 'req_age', 'checkin_year', 'checkin_month', 'checkin_monthday', 'checkout_year', 'checkout_month', 'checkout_monthday']) p.delete(key);
  } else {
    for (const key of [...p.keys()]) if (/^rm\d+$/.test(key)) p.delete(key);
    for (const [key, value] of Object.entries({ rm1: 'a2', adults: '2', rooms: '1', currency: 'USD', langid: '1033', useRewards: 'false' })) p.set(key, value);
    p.delete('children');
  }
  url.hash = '';
  return url.toString();
}

function challenge(html) {
  return /<title[^>]*>[^<]*(?:access denied|just a moment|robot|captcha)|verify you are human|enable javascript and cookies to continue|px-captcha|awsWafCookieDomainList|AwsWafIntegration/i.test(html);
}

function quoteContextMatches(expectedValue, actualValue, provider) {
  try {
    const expected = expectedValue instanceof URL ? expectedValue : new URL(String(expectedValue));
    const actual = actualValue instanceof URL ? actualValue : new URL(String(actualValue));
    const expectedQuote = quoteContextFromProbeURL(expected, provider);
    const actualQuote = quoteContextFromProbeURL(actual, provider);

    if (!expectedQuote.checkIn || !expectedQuote.checkOut || !actualQuote.checkIn || !actualQuote.checkOut) return false;
    if (expectedQuote.checkIn !== actualQuote.checkIn || expectedQuote.checkOut !== actualQuote.checkOut) return false;

    // Providers may normalize or remove redundant occupancy/currency params after
    // navigation. If they preserve them, they must still describe the same quote.
    if (provider === 'Booking') {
      const actualAdults = actual.searchParams.get('group_adults');
      const actualRooms = actual.searchParams.get('no_rooms');
      if (actualAdults && Number(actualAdults) !== expectedQuote.adults) return false;
      if (actualRooms && Number(actualRooms) !== expectedQuote.rooms) return false;
    } else {
      const actualRooms = actual.searchParams.get('rooms');
      const actualRm1 = actual.searchParams.get('rm1');
      if (actualRooms && Number(actualRooms) !== expectedQuote.rooms) return false;
      if (actualRm1) {
        const adultMatch = /a(\d+)/i.exec(actualRm1);
        if (adultMatch && Number(adultMatch[1]) !== expectedQuote.adults) return false;
      }
    }
    return true;
  } catch (_) {
    return false;
  }
}

function extractPage(page, provider, expectedKey, now) {
  const finalURL = priceSourceURL(page.finalURL, provider);
  if (challenge(page.html)) throw new Error('HOTEL_PRICE_SOURCE_CHALLENGE');
  const key = propertyKey(finalURL, provider);
  if (!key || (expectedKey && expectedKey !== key)) throw new Error('HOTEL_PRICE_SOURCE_PROPERTY_MISMATCH');

  // The quote context is the URL we intentionally requested, not the literal URL
  // left in the address bar after Booking/Expedia canonicalize their SPA route.
  // Direct HTTP reads still have to preserve dates in the final URL; browser reads
  // are allowed to rewrite the visible URL because the rendered price is collected
  // from the page opened with quoteURL.
  const quoteURL = priceSourceURL(page.quoteURL || page.finalURL, provider);
  const quoteKey = propertyKey(quoteURL, provider);
  if (!quoteKey || quoteKey !== key) throw new Error('HOTEL_PRICE_SOURCE_PROPERTY_MISMATCH');
  if (preparePriceURL(quoteURL, provider, now) !== quoteURL.toString()) throw new Error('HOTEL_PRICE_QUOTE_CONTEXT_MISMATCH');
  const finalContextMatches = quoteContextMatches(quoteURL, finalURL, provider);
  if (page.transport === 'browser') {
    // Booking/Expedia may canonicalize the visible SPA URL and drop quote params.
    // Only our own browser renderer may explicitly attest that the rendered DOM
    // was collected after navigating the prepared quote URL. A generic/custom
    // renderer still has to preserve the quote context in its final URL.
    if (!finalContextMatches && page.contextVerified !== true) {
      throw new Error('HOTEL_PRICE_QUOTE_CONTEXT_MISMATCH');
    }
  } else if (!finalContextMatches) {
    throw new Error('HOTEL_PRICE_QUOTE_CONTEXT_MISMATCH');
  }

  const quote = quoteContextFromProbeURL(quoteURL, provider);
  const extracted = extractHotelPriceFromHTML(page.html, provider, quote.nights);
  if (!extracted) throw new Error('HOTEL_PRICE_NOT_FOUND_ON_SOURCE');
  return { ...page, quote, extracted };
}

async function directPage(url, provider, fetcher) {
  let current = priceSourceURL(url, provider).toString();
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 12000);
  try {
    for (let hop = 0; hop < 6; hop++) {
      const response = await fetcher(current, {
        headers: { accept: 'text/html', 'accept-language': 'en-US,en;q=0.9', 'cache-control': 'no-cache' },
        redirect: 'manual', signal: controller.signal, cf: { cacheTtl: 0, cacheEverything: false }
      });
      if ([301, 302, 303, 307, 308].includes(response.status)) {
        const location = response.headers.get('location');
        if (!location) throw new Error('HOTEL_PRICE_SOURCE_BAD_REDIRECT');
        await response.body?.cancel();
        current = priceSourceURL(new URL(location, current), provider).toString();
        continue;
      }
      if (!response.ok) throw new Error(`HOTEL_PRICE_SOURCE_HTTP_${response.status}`);
      const html = await response.text();
      if (html.length > 8_000_000) throw new Error('HOTEL_PRICE_SOURCE_PAGE_TOO_LARGE');
      return { finalURL: current, html, httpStatus: response.status, transport: 'http' };
    }
    throw new Error('HOTEL_PRICE_SOURCE_BAD_REDIRECT');
  } finally { clearTimeout(timeout); }
}

export async function renderPricePage(env, sourceURL, provider, expectedKey, now) {
  if (!env.BROWSER) throw new Error('HOTEL_PRICE_BROWSER_UNAVAILABLE');
  const { default: puppeteer } = await import('@cloudflare/puppeteer');
  let browser;
  try {
    browser = await puppeteer.launch(env.BROWSER);
    const page = await browser.newPage();
    await page.setViewport({ width: 1366, height: 900, deviceScaleFactor: 1 });
    await page.setCacheEnabled(false);
    await page.setUserAgent('Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36');
    await page.setExtraHTTPHeaders({ 'Accept-Language': 'en-US,en;q=0.9', 'Cache-Control': 'no-cache' });
    if (provider === 'Booking') {
      await page.setCookie(
        { name: 'selected_currency', value: 'USD', domain: '.booking.com', path: '/', secure: true },
        { name: 'currency', value: 'USD', domain: '.booking.com', path: '/', secure: true },
        { name: 'cur_curr', value: 'USD', domain: '.booking.com', path: '/', secure: true },
        { name: 'b_selected_currency', value: 'USD', domain: '.booking.com', path: '/', secure: true }
      ).catch(() => {});
    }
    await page.setRequestInterception(true);
    page.on('request', request => {
      try {
        if (request.isNavigationRequest() && request.frame() === page.mainFrame()) priceSourceURL(request.url(), provider);
        if (['image', 'media', 'font'].includes(request.resourceType())) { void request.abort().catch(() => {}); return; }
        void request.continue().catch(() => {});
      } catch { void request.abort().catch(() => {}); }
    });
    let response = await page.goto(sourceURL, { waitUntil: 'domcontentloaded', timeout: 18000 });
    let resolved = priceSourceURL(page.url(), provider);
    if (!propertyKey(resolved, provider)) {
      // A Share URL can resolve through client-side navigation after DOM load.
      // Let the site's own JavaScript run; never solve/bypass a CAPTCHA.
      await page.waitForFunction(() => /\/hotel\/.*\.html|\.h\d+\.Hotel-Information/i.test(location.pathname), { timeout: 10000 }).catch(() => {});
      resolved = priceSourceURL(page.url(), provider);
      if (challenge(await page.content())) throw new Error('HOTEL_PRICE_SOURCE_CHALLENGE');
    }
    const key = propertyKey(resolved, provider);
    if (!key || (expectedKey && key !== expectedKey)) throw new Error('HOTEL_PRICE_SOURCE_PROPERTY_MISMATCH');
    const prepared = preparePriceURL(resolved, provider, now);
    if (prepared !== resolved.toString()) response = await page.goto(prepared, { waitUntil: 'domcontentloaded', timeout: 16000 });
    if (response && !response.ok()) throw new Error(`HOTEL_PRICE_SOURCE_HTTP_${response.status()}`);

    // Availability widgets are frequently lazy-rendered. Trigger only the site's
    // ordinary availability controls and then wait for an explicit sellable price.
    await page.evaluate(() => {
      const clean = value => String(value || '').replace(/\s+/g, ' ').trim();
      const action = [...document.querySelectorAll('button,a,[role="button"]')].find(el =>
        /see availability|show prices|check availability|view prices|select room/i.test(clean(`${el.innerText || ''} ${el.getAttribute?.('aria-label') || ''}`))
      );
      try { if (action && action.offsetParent !== null) action.click(); } catch (_) {}
      const target = document.querySelector('#hprt-table, [data-testid="availability-table"], [data-testid*="availability"], [data-stid="property-offers"]');
      try { target?.scrollIntoView({ block: 'center' }); } catch (_) {}
    }).catch(() => {});

    await page.waitForFunction(() => {
      const text = document.body?.innerText || '';
      return /(?:USD|US\$|SAR|AED|\$)\s*[0-9]/.test(text) &&
        !!document.querySelector('[data-testid="price-and-discounted-price"], [data-testid="price-for-x-nights"], .prco-valign-middle-helper, .bui-price-display__value, .uitk-lockup-price, [data-stid*="price-lockup"], [data-stid="price-lockup"]');
    }, { timeout: 8000 }).catch(() => {});
    const result = {
      html: await page.content(),
      finalURL: page.url(),
      quoteURL: prepared,
      httpStatus: response?.status() || 200,
      transport: 'browser',
      contextVerified: true
    };
    if (result.html.length > 8_000_000) throw new Error('HOTEL_PRICE_SOURCE_PAGE_TOO_LARGE');
    return result;
  } finally { if (browser) await browser.close().catch(() => {}); }
}

export async function obtainHotelPrice(env, sourceURL, provider, dependencies = {}) {
  const now = dependencies.now ?? Date.now();
  const expectedKey = propertyKey(sourceURL, provider);
  const probeURL = preparePriceURL(sourceURL, provider, now);
  const fetcher = dependencies.fetcher || fetch;
  const render = dependencies.render || renderPricePage;
  let browserURL = probeURL;
  try {
    let page = await directPage(probeURL, provider, fetcher);
    const key = propertyKey(page.finalURL, provider);
    if (expectedKey && key !== expectedKey) throw new Error('HOTEL_PRICE_SOURCE_PROPERTY_MISMATCH');
    if (key) {
      browserURL = preparePriceURL(page.finalURL, provider, now);
      if (browserURL !== page.finalURL) page = await directPage(browserURL, provider, fetcher);
      page.quoteURL = browserURL;
    }
    return extractPage(page, provider, expectedKey, now);
  } catch (error) {
    if (/MISMATCH|BAD_REDIRECT/.test(error.message) && !/QUOTE_CONTEXT/.test(error.message)) throw error;
    // Browser rendering is a fresh read, never a cached importer snapshot.
    const page = await render(env, browserURL, provider, expectedKey, now);
    if (!page.quoteURL) page.quoteURL = browserURL;
    if (!page.transport) page.transport = 'browser';
    return extractPage(page, provider, expectedKey, now);
  }
}
