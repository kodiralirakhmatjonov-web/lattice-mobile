import { extractHotelPriceFromHTML, normalizeImportedHotelPriceSnapshot, quoteContextFromProbeURL } from './hotel-price.js';

const DAY = 86400000;
const EXPEDIA_PROBE_OFFSETS = [1, 7, 14, 20, 25, 30, 45, 60];
const EXPEDIA_BROWSER_PROBE_LIMIT = 6;

function expediaHostAllowed(host) {
  const value = String(host || '').toLowerCase();
  // Keep the allow-list provider-specific while accepting Expedia regional domains.
  // Examples: expedia.com, expedia.co.uk, expedia.com.au, expedia.com.sa, expedia.ae.
  return /(^|\.)expedia\.(?:com(?:\.[a-z]{2})?|co\.[a-z]{2}|[a-z]{2})$/.test(value);
}

function expediaShareHost(host) {
  const value = String(host || '').toLowerCase();
  return value === 'expe.onelink.me' || value.endsWith('.expe.onelink.me');
}

export function priceSourceURL(value, provider) {
  const url = value instanceof URL ? new URL(value.toString()) : new URL(String(value));
  const host = url.hostname.toLowerCase();
  const allowed = provider === 'Booking'
    ? /(^|\.)booking\.com$/.test(host)
    : provider === 'Expedia' && expediaHostAllowed(host);
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

export function safePropertyKey(value, provider) {
  try { return propertyKey(value, provider); } catch (_) { return null; }
}

function cleanISODate(value) {
  const text = String(value || '').trim();
  if (!/^\d{4}-\d{2}-\d{2}$/.test(text)) return null;
  const ms = Date.parse(`${text}T00:00:00Z`);
  return Number.isFinite(ms) && new Date(ms).toISOString().slice(0, 10) === text ? text : null;
}

function dateAt(now, offsetDays) {
  return new Date(now + offsetDays * DAY).toISOString().slice(0, 10);
}

function normalizeQuoteParams(url, provider) {
  const p = url.searchParams;
  if (provider === 'Booking') {
    for (const [key, value] of Object.entries({
      selected_currency: 'USD', cur_currency: 'USD', lang: 'en-us',
      group_adults: '2', req_adults: '2', group_children: '0', req_children: '0',
      no_rooms: '1', room1: 'A,A'
    })) p.set(key, value);
    for (const key of ['age', 'req_age', 'checkin_year', 'checkin_month', 'checkin_monthday', 'checkout_year', 'checkout_month', 'checkout_monthday']) p.delete(key);
  } else {
    for (const key of [...p.keys()]) if (/^rm\d+$/.test(key)) p.delete(key);
    // Expedia currently understands top_cur more consistently than currency on
    // lodging property pages. Keep both so SSR and the SPA agree on USD.
    for (const [key, value] of Object.entries({
      rm1: 'a2', adults: '2', rooms: '1', currency: 'USD', top_cur: 'USD',
      langid: '1033', locale: 'en_US', useRewards: 'false'
    })) p.set(key, value);
    p.delete('children');
  }
  url.hash = '';
  return url;
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
  const start = cleanISODate(p.get(inKey));
  const end = cleanISODate(p.get(outKey));
  const today = new Date(now).toISOString().slice(0, 10);
  if (!start || !end || start <= today || end <= start || Date.parse(end) - Date.parse(start) > 30 * DAY) {
    p.set(inKey, dateAt(now, 1));
    p.set(outKey, dateAt(now, 2));
  }
  normalizeQuoteParams(url, provider);
  return url.toString();
}

// Expedia refresh is property-bound, not room-bound. The imported URL/property ID
// remains the identity anchor, while availability may move between room types and
// dates. The refresh ignores imported trip dates and probes a sparse rolling horizon.
export function expediaPriceProbeURLs(value, now = Date.now()) {
  const source = priceSourceURL(value, 'Expedia');
  const key = propertyKey(source, 'Expedia');
  if (!key) throw new Error('HOTEL_PRICE_SOURCE_PROPERTY_MISMATCH');

  // Keep the exact Expedia storefront that the admin imported (for example
  // expedia.sa). Regional storefronts can expose different live inventory and
  // pricing, so changing the host here makes the refresh disagree with the
  // source page the admin opens manually. The immutable .h<propertyID> remains
  // the hotel identity boundary.
  const base = new URL(source.toString());
  base.hash = '';

  const output = [];
  const seen = new Set();
  const push = url => {
    normalizeQuoteParams(url, 'Expedia');
    if (propertyKey(url, 'Expedia') !== key) return;
    const text = url.toString();
    if (!seen.has(text)) { seen.add(text); output.push(text); }
  };

  // Refresh dates are always relative to today. Imported trip dates are provenance,
  // not the catalogue benchmark. This prevents a months-old/far-future imported
  // stay from repeatedly winning just because it still has availability.
  for (const offset of EXPEDIA_PROBE_OFFSETS) {
    const probe = new URL(base.toString());
    probe.searchParams.set('chkin', dateAt(now, offset));
    probe.searchParams.set('chkout', dateAt(now, offset + 1));
    push(probe);
  }
  return output;
}

function challenge(html) {
  return /<title[^>]*>[^<]*(?:access denied|just a moment|robot|captcha)|verify you are human|enable javascript and cookies to continue|px-captcha|awsWafCookieDomainList|AwsWafIntegration/i.test(String(html || ''));
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

function extractedFromSnapshot(snapshot) {
  const normalized = normalizeImportedHotelPriceSnapshot(snapshot);
  if (!normalized) return null;
  return {
    amount: normalized.amountOriginal,
    currency: normalized.currencyOriginal,
    priceBasis: normalized.priceBasis,
    nightlyUSD: normalized.nightlyUSD,
    stayTotalUSD: normalized.stayTotalUSD,
    confidence: normalized.confidence,
    method: normalized.method
  };
}

function extractPage(page, provider, expectedKey, now) {
  const finalURL = priceSourceURL(page.finalURL, provider);
  if (challenge(page.html)) throw new Error('HOTEL_PRICE_SOURCE_CHALLENGE');
  const key = propertyKey(finalURL, provider);
  if (!key || (expectedKey && expectedKey !== key)) throw new Error('HOTEL_PRICE_SOURCE_PROPERTY_MISMATCH');

  // The quote context is the URL we intentionally requested, not the literal URL
  // left in the address bar after Booking/Expedia canonicalize their SPA route.
  const quoteURL = priceSourceURL(page.quoteURL || page.finalURL, provider);
  const quoteKey = propertyKey(quoteURL, provider);
  if (!quoteKey || quoteKey !== key) throw new Error('HOTEL_PRICE_SOURCE_PROPERTY_MISMATCH');
  const normalizedQuoteURL = new URL(preparePriceURL(quoteURL, provider, now));
  const actualQuoteURL = new URL(quoteURL.toString());
  normalizedQuoteURL.searchParams.sort();
  actualQuoteURL.searchParams.sort();
  if (normalizedQuoteURL.toString() !== actualQuoteURL.toString()) throw new Error('HOTEL_PRICE_QUOTE_CONTEXT_MISMATCH');
  const finalContextMatches = quoteContextMatches(quoteURL, finalURL, provider);
  if (page.transport === 'browser') {
    if (!finalContextMatches && page.contextVerified !== true) throw new Error('HOTEL_PRICE_QUOTE_CONTEXT_MISMATCH');
  } else if (!finalContextMatches) {
    throw new Error('HOTEL_PRICE_QUOTE_CONTEXT_MISMATCH');
  }

  const quote = quoteContextFromProbeURL(quoteURL, provider);
  const extracted = extractedFromSnapshot(page.priceSnapshot)
    || extractHotelPriceFromHTML(page.html, provider, quote.nights);
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
        headers: {
          accept: 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
          'accept-language': 'en-US,en;q=0.9',
          'cache-control': 'no-cache',
          pragma: 'no-cache',
          'user-agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36'
        },
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

async function configureBrowserPage(page, provider) {
  await page.setViewport({ width: 1366, height: 900, deviceScaleFactor: 1 });
  await page.setCacheEnabled(false);
  await page.setUserAgent('Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36');
  await page.setExtraHTTPHeaders({ 'Accept-Language': 'en-US,en;q=0.9', 'Cache-Control': 'no-cache', Pragma: 'no-cache' });
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
}

async function activateAvailability(page) {
  await page.evaluate(async () => {
    const clean = value => String(value || '').replace(/\s+/g, ' ').trim();
    const actions = [...document.querySelectorAll('button,a,[role="button"]')].filter(el =>
      /see availability|show prices|check availability|view prices|select room|room options|choose your room/i.test(clean(`${el.innerText || ''} ${el.getAttribute?.('aria-label') || ''}`))
    );
    for (const action of actions.slice(0, 2)) {
      try { if (action.offsetParent !== null) action.click(); } catch (_) {}
    }
    const target = document.querySelector('#hprt-table, [data-testid="availability-table"], [data-testid*="availability"], [data-stid="property-offers"], [data-stid*="room"]');
    try { target?.scrollIntoView({ block: 'center' }); } catch (_) {}
    for (let i = 0; i < 4; i += 1) {
      try { window.scrollBy(0, Math.max(500, window.innerHeight * 0.7)); } catch (_) {}
      await new Promise(resolve => setTimeout(resolve, 180));
    }
  }).catch(() => {});
}

async function expediaDOMPriceSnapshot(page, quoteURL) {
  const quote = quoteContextFromProbeURL(quoteURL, 'Expedia');
  const value = await page.evaluate(({ checkIn, checkOut, nights }) => {
    const clean = input => String(input || '').replace(/\s+/g, ' ').trim();
    const currencyOf = input => {
      const token = clean(input).toUpperCase().replace(/\s+/g, '');
      if (token === 'USD' || token === 'US$' || token === '$') return 'USD';
      if (token === 'SAR' || token === 'SR' || token.includes('ر.س')) return 'SAR';
      if (token === 'AED' || token.includes('د.إ')) return 'AED';
      return null;
    };
    const amountOf = input => {
      let text = clean(input).replace(/[\u00a0\u202f\s]/g, '').replace(/[^0-9.,]/g, '');
      if (!text) return null;
      const comma = text.lastIndexOf(',');
      const dot = text.lastIndexOf('.');
      if (comma >= 0 && dot >= 0) text = dot > comma ? text.replace(/,/g, '') : text.replace(/\./g, '').replace(',', '.');
      else if (comma >= 0) {
        const after = text.length - comma - 1;
        text = (after === 1 || after === 2) ? text.replace(',', '.') : text.replace(/,/g, '');
      } else if (dot >= 0) {
        const after = text.length - dot - 1;
        if (after !== 1 && after !== 2) text = text.replace(/\./g, '');
      }
      const amount = Number(text);
      return Number.isFinite(amount) && amount > 0 ? amount : null;
    };
    const moneyValues = input => {
      const text = clean(input);
      const out = [];
      const before = /(?:US\$|USD|\$|SAR|SR|ر\.?س\.?|AED|د\.?إ\.?)\s*([0-9][0-9.,\s]*)/gi;
      const after = /([0-9][0-9.,\s]*)\s*(US\$|USD|\$|SAR|SR|ر\.?س\.?|AED|د\.?إ\.?)/gi;
      let match;
      while ((match = before.exec(text)) !== null && out.length < 12) {
        const token = match[0].slice(0, match[0].indexOf(match[1]));
        const amount = amountOf(match[1]); const currency = currencyOf(token);
        if (amount && currency) out.push({ amount, currency, index: match.index });
      }
      while ((match = after.exec(text)) !== null && out.length < 12) {
        const amount = amountOf(match[1]); const currency = currencyOf(match[2]);
        if (amount && currency) out.push({ amount, currency, index: match.index });
      }
      return out.sort((a, b) => a.index - b.index);
    };
    const excluded = el => {
      for (let node = el; node && node !== document.body; node = node.parentElement) {
        const marker = `${node.getAttribute?.('data-stid') || ''} ${node.getAttribute?.('data-testid') || ''} ${node.id || ''} ${node.className || ''}`;
        const heading = clean(node.querySelector?.('h1,h2,h3,[role="heading"]')?.innerText || '');
        if (/(recommend|similar|related|other-property|cross-sell|upsell|search-result)/i.test(marker)) return true;
        if (/(similar properties|you may also like|other properties|recommended|more places to stay)/i.test(heading)) return true;
      }
      return false;
    };
    const roomName = el => {
      for (let node = el, depth = 0; node && depth < 8; node = node.parentElement, depth += 1) {
        const heading = clean(node.querySelector?.('h2,h3,h4,[role="heading"],[data-testid*="room-name"]')?.innerText || '');
        if (heading && heading.length >= 3 && heading.length <= 180 && !/(recommended|similar|about this property|policies)/i.test(heading)) return heading;
      }
      return null;
    };
    const candidates = [];
    const selectors = [
      '[data-stid*="price-lockup"]','[data-stid*="price"]','[data-testid*="price"]',
      '[class*="uitk-lockup-price"]','[class*="price-lockup"]'
    ];
    const elements = [...new Set(selectors.flatMap(selector => [...document.querySelectorAll(selector)]))];
    const add = (el, scoreBase) => {
      if (!el || excluded(el)) return;
      const style = getComputedStyle(el); const rect = el.getBoundingClientRect();
      if (style.display === 'none' || style.visibility === 'hidden' || rect.width === 0 || rect.height === 0) return;
      let context = clean(el.innerText || el.textContent || '');
      let node = el;
      for (let depth = 0; node && depth < 4 && context.length < 100; depth += 1, node = node.parentElement) {
        const candidate = clean(node.innerText || node.textContent || '');
        if (candidate.length > context.length && candidate.length <= 800) context = candidate;
      }
      if (!context || !/(SAR|SR|ر\.?س\.?|AED|د\.?إ\.?|USD|US\$|\$)/i.test(context)) return;
      if (/(deposit|parking|breakfast fee|airport shuttle|taxi|damage deposit)/i.test(context) && !/(room|suite|night|total|reserve|select|price)/i.test(context)) return;
      let money = moneyValues(context).filter(item => item.amount >= 15 && item.amount <= 100000);
      if (!money.length) return;
      const totalIndex = context.toLowerCase().indexOf('total');
      let total = null;
      if (totalIndex >= 0) {
        const afterTotal = money.filter(item => item.index >= totalIndex);
        if (afterTotal.length) total = afterTotal[afterTotal.length - 1];
        const beforeTotal = money.filter(item => item.index < totalIndex);
        if (beforeTotal.length) money = beforeTotal;
      }
      // Expedia often renders an old struck price before the active rate. Prefer the
      // last non-total amount in the visible price lockup, matching the displayed rate.
      const base = money[money.length - 1];
      const name = roomName(el);
      let score = scoreBase;
      if (name) score += 12;
      if (/per\s+night|\/\s*night|nightly/i.test(context)) score += 22;
      if (/member price|sign in|reward/i.test(context)) score -= 4;
      const basis = (/per\s+night|\/\s*night|nightly/i.test(context) || Number(nights) === 1) ? 'nightly' : (/total/i.test(context) ? 'stay_total' : 'nightly');
      candidates.push({ amount: base.amount, currency: base.currency, totalAmount: total?.amount || null, totalCurrency: total?.currency || null,
        priceBasis: basis, checkIn, checkOut, nights: Number(nights) || 1, adults: 2, rooms: 1, roomName: name,
        method: 'expedia-browser-any-room', confidence: Math.max(0.72, Math.min(0.995, score / 100)), score,
        domIndex: elements.indexOf(el) });
    };
    elements.forEach(el => add(el, 78));
    if (!candidates.length) {
      for (const el of [...document.querySelectorAll('span,div,p,strong')].slice(0, 4500)) {
        const text = clean(el.innerText || el.textContent || '');
        if (text.length < 3 || text.length > 140 || !/(SAR|SR|ر\.?س\.?|AED|د\.?إ\.?|USD|US\$|\$)/i.test(text)) continue;
        add(el, 56);
        if (candidates.length >= 80) break;
      }
    }
    candidates.sort((a, b) => b.score - a.score || a.domIndex - b.domIndex || a.amount - b.amount);
    if (!candidates.length) return null;
    const bestScore = candidates[0].score;
    const pool = candidates.filter(item => item.score >= bestScore - 3);
    // Any room is acceptable: choose the lowest sellable rate among equally strong
    // room-card candidates, rather than requiring Double/Twin room naming.
    pool.sort((a, b) => a.amount - b.amount || a.domIndex - b.domIndex);
    const chosen = pool[0];
    delete chosen.score; delete chosen.domIndex;
    return chosen;
  }, quote).catch(() => null);
  return value || null;
}

export async function renderPricePage(env, sourceURL, provider, expectedKey, now) {
  if (!env.BROWSER) throw new Error('HOTEL_PRICE_BROWSER_UNAVAILABLE');
  const { default: puppeteer } = await import('@cloudflare/puppeteer');
  let browser;
  try {
    browser = await puppeteer.launch(env.BROWSER);
    const page = await browser.newPage();
    await configureBrowserPage(page, provider);
    let response = await page.goto(sourceURL, { waitUntil: 'domcontentloaded', timeout: 18000 });
    let resolved = priceSourceURL(page.url(), provider);
    if (!propertyKey(resolved, provider)) {
      await page.waitForFunction(() => /\/hotel\/.*\.html|\.h\d+\.Hotel-Information/i.test(location.pathname), { timeout: 10000 }).catch(() => {});
      resolved = priceSourceURL(page.url(), provider);
      if (challenge(await page.content())) throw new Error('HOTEL_PRICE_SOURCE_CHALLENGE');
    }
    const key = propertyKey(resolved, provider);
    if (!key || (expectedKey && key !== expectedKey)) throw new Error('HOTEL_PRICE_SOURCE_PROPERTY_MISMATCH');
    const prepared = preparePriceURL(resolved, provider, now);
    if (prepared !== resolved.toString()) response = await page.goto(prepared, { waitUntil: 'domcontentloaded', timeout: 16000 });
    if (response && !response.ok()) throw new Error(`HOTEL_PRICE_SOURCE_HTTP_${response.status()}`);
    await activateAvailability(page);
    await page.waitForFunction(() => {
      const text = document.body?.innerText || '';
      return /(?:USD|US\$|SAR|AED|\$)\s*[0-9]/.test(text) &&
        !!document.querySelector('[data-testid="price-and-discounted-price"], [data-testid="price-for-x-nights"], .prco-valign-middle-helper, .bui-price-display__value, .uitk-lockup-price, [data-stid*="price-lockup"], [data-stid="price-lockup"]');
    }, { timeout: 7000 }).catch(() => {});
    const html = await page.content();
    const result = {
      html,
      finalURL: page.url(),
      quoteURL: prepared,
      httpStatus: response?.status() || 200,
      transport: 'browser',
      contextVerified: true,
      priceSnapshot: provider === 'Expedia' ? await expediaDOMPriceSnapshot(page, prepared) : null
    };
    if (result.html.length > 8_000_000) throw new Error('HOTEL_PRICE_SOURCE_PAGE_TOO_LARGE');
    return result;
  } finally { if (browser) await browser.close().catch(() => {}); }
}

async function renderExpediaPricePages(env, probeURLs, expectedKey, now) {
  if (!env.BROWSER) throw new Error('HOTEL_PRICE_BROWSER_UNAVAILABLE');
  const { default: puppeteer } = await import('@cloudflare/puppeteer');
  let browser;
  let lastError = new Error('HOTEL_PRICE_NOT_FOUND_ON_SOURCE');
  try {
    browser = await puppeteer.launch(env.BROWSER);
    const page = await browser.newPage();
    await configureBrowserPage(page, 'Expedia');

    for (const probeURL of probeURLs.slice(0, EXPEDIA_BROWSER_PROBE_LIMIT)) {
      try {
        const prepared = preparePriceURL(probeURL, 'Expedia', now);
        const response = await page.goto(prepared, { waitUntil: 'domcontentloaded', timeout: 15000 });
        if (response && !response.ok()) throw new Error(`HOTEL_PRICE_SOURCE_HTTP_${response.status()}`);
        const resolved = priceSourceURL(page.url(), 'Expedia');
        const key = propertyKey(resolved, 'Expedia');
        if (!key || key !== expectedKey) throw new Error('HOTEL_PRICE_SOURCE_PROPERTY_MISMATCH');

        await activateAvailability(page);
        await page.waitForFunction(() => {
          const text = document.body?.innerText || '';
          return /(?:USD|US\$|SAR|AED|\$)\s*[0-9]/.test(text) || /sold out|not available|no rooms/i.test(text);
        }, { timeout: 5500 }).catch(() => {});

        const priceSnapshot = await expediaDOMPriceSnapshot(page, prepared);
        const html = await page.content();
        if (challenge(html)) throw new Error('HOTEL_PRICE_SOURCE_CHALLENGE');
        if (html.length > 8_000_000) throw new Error('HOTEL_PRICE_SOURCE_PAGE_TOO_LARGE');
        const rendered = {
          html,
          finalURL: page.url(),
          quoteURL: prepared,
          httpStatus: response?.status() || 200,
          transport: 'browser',
          contextVerified: true,
          priceSnapshot
        };
        // Validate identity/date context and require an actual sellable rate before
        // leaving the shared browser session.
        return extractPage(rendered, 'Expedia', expectedKey, now);
      } catch (error) {
        lastError = error;
        if (/PROPERTY_MISMATCH|REDIRECT_MISMATCH|BAD_REDIRECT/.test(String(error?.message || ''))) throw error;
      }
    }
    throw lastError;
  } finally { if (browser) await browser.close().catch(() => {}); }
}

async function obtainExpediaHotelPrice(env, sourceURL, dependencies = {}) {
  const now = dependencies.now ?? Date.now();
  const expectedKey = propertyKey(sourceURL, 'Expedia');
  if (!expectedKey) throw new Error('HOTEL_PRICE_SOURCE_PROPERTY_MISMATCH');
  const probes = expediaPriceProbeURLs(sourceURL, now);
  const fetcher = dependencies.fetcher || fetch;
  let lastError = new Error('HOTEL_PRICE_NOT_FOUND_ON_SOURCE');

  // Static/SSR Expedia HTML is cheap. Try the complete same-property date ladder
  // first so a sold-out tomorrow does not force an expensive browser session.
  for (const probeURL of probes) {
    try {
      const page = await directPage(probeURL, 'Expedia', fetcher);
      page.quoteURL = probeURL;
      return extractPage(page, 'Expedia', expectedKey, now);
    } catch (error) {
      lastError = error;
      if (/PROPERTY_MISMATCH|REDIRECT_MISMATCH|BAD_REDIRECT/.test(String(error?.message || ''))) throw error;
    }
  }

  const renderMany = dependencies.renderMany || renderExpediaPricePages;
  try {
    return await renderMany(env, probes, expectedKey, now);
  } catch (error) {
    // Backward-compatible single-page renderer injection for unit tests/custom callers.
    if (dependencies.render && !dependencies.renderMany) {
      for (const probeURL of probes.slice(0, EXPEDIA_BROWSER_PROBE_LIMIT)) {
        try {
          const page = await dependencies.render(env, probeURL, 'Expedia', expectedKey, now);
          if (!page.quoteURL) page.quoteURL = probeURL;
          if (!page.transport) page.transport = 'browser';
          return extractPage(page, 'Expedia', expectedKey, now);
        } catch (singleError) { lastError = singleError; }
      }
    } else {
      lastError = error;
    }
  }
  throw lastError;
}

export async function obtainHotelPrice(env, sourceURL, provider, dependencies = {}) {
  if (provider === 'Expedia') return obtainExpediaHotelPrice(env, sourceURL, dependencies);

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
    const page = await render(env, browserURL, provider, expectedKey, now);
    if (!page.quoteURL) page.quoteURL = browserURL;
    if (!page.transport) page.transport = 'browser';
    return extractPage(page, provider, expectedKey, now);
  }
}

// Kept internal for source-entry diagnostics. Expedia Share links are valid import
// inputs, but price refresh should operate on the canonical property URL saved by
// the importer rather than trying to price the tracking link itself.
export function isKnownExpediaShareURL(value) {
  try {
    const url = value instanceof URL ? value : new URL(String(value));
    return url.protocol === 'https:' && !url.username && !url.password && expediaShareHost(url.hostname);
  } catch (_) { return false; }
}
