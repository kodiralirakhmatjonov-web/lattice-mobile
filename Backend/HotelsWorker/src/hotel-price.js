export const HOTEL_PRICE_TTL_MS = 48 * 60 * 60 * 1000;
export const HOTEL_PRICE_RETRY_MS = 6 * 60 * 60 * 1000;
export const HOTEL_PRICE_QUOTE_NIGHTS = 1;
export const HOTEL_PRICE_QUOTE_ADULTS = 2;
export const HOTEL_PRICE_QUOTE_ROOMS = 1;

const MONEY_TOKEN = '(?:US\\$|USD|\\$|SAR|SR|ر\\.?س\\.?|AED|د\\.?إ\\.?)';
const AMOUNT_TOKEN = '([0-9]{1,3}(?:[ ,.]?[0-9]{3})*(?:[.,][0-9]{1,2})?|[0-9]{1,6}(?:[.,][0-9]{1,2})?)';

export function buildHotelPriceProbeURLs(propertyURL, provider, nowMs = Date.now()) {
  const base = propertyURL instanceof URL ? propertyURL : new URL(String(propertyURL));
  const offsets = [14, 45];
  const out = [];
  const seen = new Set();
  const dateFor = offset => new Date(nowMs + offset * 86400000).toISOString().slice(0, 10);
  const push = url => {
    const value = url.toString();
    if (!seen.has(value)) {
      seen.add(value);
      out.push(value);
    }
  };

  for (const offset of offsets) {
    const checkIn = dateFor(offset);
    const checkOut = dateFor(offset + HOTEL_PRICE_QUOTE_NIGHTS);
    const url = new URL(base.toString());
    if (provider === 'Booking') {
      url.searchParams.set('checkin', checkIn);
      url.searchParams.set('checkout', checkOut);
      url.searchParams.set('group_adults', String(HOTEL_PRICE_QUOTE_ADULTS));
      url.searchParams.set('group_children', '0');
      url.searchParams.set('no_rooms', String(HOTEL_PRICE_QUOTE_ROOMS));
      url.searchParams.set('selected_currency', 'USD');
      push(url);
    } else if (provider === 'Expedia') {
      url.searchParams.set('chkin', checkIn);
      url.searchParams.set('chkout', checkOut);
      url.searchParams.set('rm1', 'a2');
      url.searchParams.set('useRewards', 'false');
      url.searchParams.set('currency', 'USD');
      push(url);
      const canonical = new URL(url.toString());
      canonical.hostname = 'www.expedia.com';
      push(canonical);
    }
  }
  return out.slice(0, 6);
}

export function quoteContextFromProbeURL(value, provider) {
  try {
    const url = value instanceof URL ? value : new URL(String(value));
    const checkIn = provider === 'Booking' ? url.searchParams.get('checkin') : url.searchParams.get('chkin');
    const checkOut = provider === 'Booking' ? url.searchParams.get('checkout') : url.searchParams.get('chkout');
    return {
      checkIn: checkIn || null,
      checkOut: checkOut || null,
      nights: HOTEL_PRICE_QUOTE_NIGHTS,
      adults: HOTEL_PRICE_QUOTE_ADULTS,
      rooms: HOTEL_PRICE_QUOTE_ROOMS
    };
  } catch (_) {
    return { checkIn: null, checkOut: null, nights: HOTEL_PRICE_QUOTE_NIGHTS, adults: HOTEL_PRICE_QUOTE_ADULTS, rooms: HOTEL_PRICE_QUOTE_ROOMS };
  }
}

export function extractHotelPriceFromHTML(html, provider, nights = HOTEL_PRICE_QUOTE_NIGHTS) {
  const raw = String(html || '');
  if (!raw || raw.length < 200) return null;

  const scoped = scopePropertyHTML(raw);
  const readable = htmlToReadableText(scoped);
  const candidates = [];

  collectJSONLDCandidates(scoped, candidates, nights);
  if (provider === 'Booking') collectBookingCandidates(scoped, readable, candidates, nights);
  if (provider === 'Expedia') collectExpediaCandidates(scoped, readable, candidates, nights);
  collectGenericExplicitCandidates(readable, candidates, nights);

  const normalized = candidates
    .map(candidate => normalizeCandidate(candidate, nights))
    .filter(Boolean)
    .filter(candidate => candidate.nightlyUSD >= 15 && candidate.nightlyUSD <= 5000);
  if (!normalized.length) return null;

  normalized.sort((a, b) => {
    if (Math.abs(b.confidence - a.confidence) > 0.001) return b.confidence - a.confidence;
    if (a.nightlyUSD !== b.nightlyUSD) return a.nightlyUSD - b.nightlyUSD;
    return String(a.method).localeCompare(String(b.method));
  });

  const bestConfidence = normalized[0].confidence;
  const trusted = normalized.filter(item => item.confidence >= bestConfidence - 0.025);
  return trusted.sort((a, b) => a.nightlyUSD - b.nightlyUSD)[0] || normalized[0];
}

function collectBookingCandidates(html, readable, out, nights) {
  for (const segment of extractTestIDSegments(html, ['price-for-x-nights'])) {
    const money = firstMoney(segment);
    if (money) out.push({ ...money, basis: 'stay_total', confidence: 0.99, method: 'booking-price-for-x-nights' });
  }
  for (const segment of extractTestIDContexts(html, 'price-and-discounted-price')) {
    const money = firstMoney(segment.element);
    if (!money) continue;
    const lower = htmlToReadableText(segment.context).toLowerCase();
    if (/per\s+night|nightly/.test(lower)) {
      out.push({ ...money, basis: 'nightly', confidence: 0.97, method: 'booking-price-testid-nightly' });
    } else if (nights === 1) {
      out.push({ ...money, basis: 'nightly', confidence: 0.95, method: 'booking-price-testid-one-night' });
    } else if (new RegExp(`\\b${nights}\\s+nights?\\b`, 'i').test(lower)) {
      out.push({ ...money, basis: 'stay_total', confidence: 0.95, method: 'booking-price-testid-stay' });
    }
  }

  const escaped = readable.replace(/\u00a0/g, ' ');
  const totalPatterns = [
    new RegExp(`${MONEY_TOKEN}\\s*${AMOUNT_TOKEN}[^\\n]{0,80}(?:for\\s+)?${nights}\\s+nights?`, 'gi'),
    new RegExp(`${nights}\\s+nights?[^\\n]{0,80}${MONEY_TOKEN}\\s*${AMOUNT_TOKEN}`, 'gi')
  ];
  for (const pattern of totalPatterns) collectPatternMoney(escaped, pattern, out, 'stay_total', 0.96, 'booking-explicit-stay');
}

function collectExpediaCandidates(html, readable, out, nights) {
  const text = readable.replace(/\u00a0/g, ' ');
  const nightlyPatterns = [
    new RegExp(`${MONEY_TOKEN}\\s*${AMOUNT_TOKEN}[^\\n]{0,45}per\\s+night`, 'gi'),
    new RegExp(`per\\s+night[^\\n]{0,45}${MONEY_TOKEN}\\s*${AMOUNT_TOKEN}`, 'gi')
  ];
  for (const pattern of nightlyPatterns) collectPatternMoney(text, pattern, out, 'nightly', 0.99, 'expedia-explicit-nightly');

  const totalPatterns = [
    new RegExp(`${MONEY_TOKEN}\\s*${AMOUNT_TOKEN}[^\\n]{0,80}(?:total|for\\s+${nights}\\s+nights?)`, 'gi'),
    new RegExp(`(?:total|for\\s+${nights}\\s+nights?)[^\\n]{0,80}${MONEY_TOKEN}\\s*${AMOUNT_TOKEN}`, 'gi')
  ];
  for (const pattern of totalPatterns) collectPatternMoney(text, pattern, out, 'stay_total', 0.97, 'expedia-explicit-total');

  const priceLockups = extractClassSegments(html, ['uitk-lockup-price', 'price-lockup-text', 'price-summary']);
  for (const segment of priceLockups) {
    const money = firstMoney(segment);
    if (!money) continue;
    const lower = segment.toLowerCase();
    if (/per\s+night|nightly/.test(lower)) out.push({ ...money, basis: 'nightly', confidence: 0.96, method: 'expedia-price-lockup' });
    else if (nights === 1) out.push({ ...money, basis: 'nightly', confidence: 0.995, method: 'expedia-price-lockup-one-night' });
    else if (/total|nights?/.test(lower)) out.push({ ...money, basis: 'stay_total', confidence: 0.92, method: 'expedia-price-lockup-total' });
  }
}

function collectGenericExplicitCandidates(text, out, nights) {
  const nightlyPatterns = [
    new RegExp(`${MONEY_TOKEN}\\s*${AMOUNT_TOKEN}[^\\n]{0,30}(?:per\\s+night|/\\s*night)`, 'gi'),
    new RegExp(`(?:per\\s+night|nightly)[^\\n]{0,30}${MONEY_TOKEN}\\s*${AMOUNT_TOKEN}`, 'gi')
  ];
  for (const pattern of nightlyPatterns) collectPatternMoney(text, pattern, out, 'nightly', 0.90, 'generic-explicit-nightly');

  const stayPatterns = [
    new RegExp(`${MONEY_TOKEN}\\s*${AMOUNT_TOKEN}[^\\n]{0,50}${nights}\\s+nights?`, 'gi'),
    new RegExp(`${nights}\\s+nights?[^\\n]{0,50}${MONEY_TOKEN}\\s*${AMOUNT_TOKEN}`, 'gi')
  ];
  for (const pattern of stayPatterns) collectPatternMoney(text, pattern, out, 'stay_total', 0.90, 'generic-explicit-stay');
}

function collectJSONLDCandidates(html, out, nights) {
  const scriptPattern = /<script[^>]+type=["']application\/ld\+json["'][^>]*>([\s\S]*?)<\/script>/gi;
  let match;
  let count = 0;
  while ((match = scriptPattern.exec(html)) !== null && count < 30) {
    count += 1;
    const body = decodeHTMLEntities(match[1]).trim();
    if (!body || body.length > 1_500_000) continue;
    let parsed;
    try { parsed = JSON.parse(body); } catch (_) { continue; }
    walkJSON(parsed, value => {
      if (!value || typeof value !== 'object' || Array.isArray(value)) return;
      const type = String(value['@type'] || '').toLowerCase();
      if (!/(offer|price|rate)/.test(type)) return;
      const currency = value.priceCurrency || value.currency || value?.priceSpecification?.priceCurrency;
      const rawAmount = value.price ?? value.lowPrice ?? value?.priceSpecification?.price;
      const amount = parseNumericAmount(rawAmount);
      if (!currency || !amount) return;
      const unit = String(value?.priceSpecification?.unitText || value?.unitText || value?.unitCode || '').toLowerCase();
      const basis = /night|day|nite/.test(unit) ? 'nightly' : null;
      if (!basis) return; // Ambiguous JSON-LD totals are deliberately rejected.
      out.push({ amount, currency: normalizeCurrency(currency), basis, confidence: 0.92, method: 'jsonld-nightly-offer' });
    });
  }
}

function normalizeCandidate(candidate, nights) {
  const amount = Number(candidate?.amount);
  const currency = normalizeCurrency(candidate?.currency);
  if (!Number.isFinite(amount) || amount <= 0 || !currency) return null;
  const usd = toUSD(amount, currency);
  if (!Number.isFinite(usd) || usd <= 0) return null;
  const basis = candidate.basis === 'stay_total' ? 'stay_total' : candidate.basis === 'nightly' ? 'nightly' : null;
  if (!basis) return null;
  const nightlyUSD = basis === 'stay_total' ? usd / Math.max(1, Number(nights) || 1) : usd;
  const stayTotalUSD = basis === 'stay_total' ? usd : usd * Math.max(1, Number(nights) || 1);
  return {
    amount,
    currency,
    priceBasis: basis,
    nightlyUSD: roundMoney(nightlyUSD),
    stayTotalUSD: roundMoney(stayTotalUSD),
    confidence: Math.max(0, Math.min(1, Number(candidate.confidence) || 0)),
    method: String(candidate.method || 'unknown')
  };
}

function collectPatternMoney(text, pattern, out, basis, confidence, method) {
  pattern.lastIndex = 0;
  let match;
  while ((match = pattern.exec(text)) !== null && out.length < 300) {
    const money = moneyFromRegexMatch(match);
    if (money) out.push({ ...money, basis, confidence, method });
  }
}

function moneyFromRegexMatch(match) {
  const value = match[0] || '';
  return firstMoney(value);
}

function firstMoney(value) {
  const text = htmlToReadableText(String(value || ''));
  const before = new RegExp(`(${MONEY_TOKEN})\\s*${AMOUNT_TOKEN}`, 'i').exec(text);
  if (before) {
    const amount = parseLocalizedAmount(before[2]);
    const currency = normalizeCurrency(before[1]);
    if (amount && currency) return { amount, currency };
  }
  const after = new RegExp(`${AMOUNT_TOKEN}\\s*(${MONEY_TOKEN})`, 'i').exec(text);
  if (after) {
    const amount = parseLocalizedAmount(after[1]);
    const currency = normalizeCurrency(after[2]);
    if (amount && currency) return { amount, currency };
  }
  return null;
}

function extractTestIDContexts(html, testID) {
  const out = [];
  const pattern = new RegExp(`<[^>]+data-testid=["']${escapeRegExp(testID)}["'][^>]*>`, 'gi');
  let match;
  while ((match = pattern.exec(html)) !== null && out.length < 100) {
    const start = Math.max(0, match.index - 500);
    const end = Math.min(html.length, match.index + match[0].length + 1200);
    const elementEnd = Math.min(html.length, match.index + match[0].length + 500);
    out.push({ element: html.slice(match.index, elementEnd), context: html.slice(start, end) });
  }
  return out;
}

function extractTestIDSegments(html, testIDs) {
  const out = [];
  for (const id of testIDs) {
    const pattern = new RegExp(`<[^>]+data-testid=["']${escapeRegExp(id)}["'][^>]*>[\\s\\S]{0,900}?</[^>]+>`, 'gi');
    let match;
    while ((match = pattern.exec(html)) !== null && out.length < 100) out.push(match[0]);
  }
  return out;
}

function extractClassSegments(html, classNames) {
  const out = [];
  for (const name of classNames) {
    const pattern = new RegExp(`<[^>]+class=["'][^"']*${escapeRegExp(name)}[^"']*["'][^>]*>[\\s\\S]{0,1200}?</[^>]+>`, 'gi');
    let match;
    while ((match = pattern.exec(html)) !== null && out.length < 100) out.push(match[0]);
  }
  return out;
}

function normalizeCurrency(value) {
  const token = String(value || '').trim().toUpperCase().replace(/\s+/g, '');
  if (!token) return null;
  if (token === '$' || token === 'US$' || token === 'USD') return 'USD';
  if (token === 'SAR' || token === 'SR' || token.includes('ر.س') || token.includes('ر.س.')) return 'SAR';
  if (token === 'AED' || token.includes('د.إ')) return 'AED';
  return null;
}

function toUSD(amount, currency) {
  if (currency === 'USD') return amount;
  if (currency === 'SAR') return amount / 3.75;
  if (currency === 'AED') return amount / 3.6725;
  return NaN;
}

function parseNumericAmount(value) {
  if (typeof value === 'number') return Number.isFinite(value) && value > 0 ? value : null;
  return parseLocalizedAmount(String(value || ''));
}

function parseLocalizedAmount(value) {
  let text = String(value || '').replace(/[\u00a0\u202f\s]/g, '').replace(/[^0-9.,]/g, '');
  if (!text) return null;
  const lastComma = text.lastIndexOf(',');
  const lastDot = text.lastIndexOf('.');
  if (lastComma >= 0 && lastDot >= 0) {
    if (lastDot > lastComma) text = text.replace(/,/g, '');
    else text = text.replace(/\./g, '').replace(',', '.');
  } else if (lastComma >= 0) {
    const digitsAfter = text.length - lastComma - 1;
    if (digitsAfter === 1 || digitsAfter === 2) text = text.replace(',', '.');
    else text = text.replace(/,/g, '');
  } else if (lastDot >= 0) {
    const digitsAfter = text.length - lastDot - 1;
    if (digitsAfter !== 1 && digitsAfter !== 2) text = text.replace(/\./g, '');
  }
  const amount = Number(text);
  return Number.isFinite(amount) && amount > 0 ? amount : null;
}

function scopePropertyHTML(html) {
  const boundary = String(html || '').search(/(?:You may also like|Similar properties|Recommended properties|Other properties you may like|Guests who viewed this property also viewed)/i);
  return boundary >= 0 ? String(html || '').slice(0, boundary) : String(html || '');
}

function htmlToReadableText(value) {
  return decodeHTMLEntities(String(value || '')
    .replace(/<script\b[^>]*>[\s\S]*?<\/script>/gi, ' ')
    .replace(/<style\b[^>]*>[\s\S]*?<\/style>/gi, ' ')
    .replace(/<br\s*\/?\s*>/gi, '\n')
    .replace(/<\/p\s*>/gi, '\n')
    .replace(/<\/div\s*>/gi, '\n')
    .replace(/<\/li\s*>/gi, '\n')
    .replace(/<[^>]+>/g, ' '))
    .replace(/[\t ]+/g, ' ')
    .replace(/\n[\t ]+/g, '\n')
    .replace(/\n{3,}/g, '\n\n')
    .trim();
}

function decodeHTMLEntities(value) {
  return String(value || '')
    .replace(/&nbsp;|&#160;/gi, ' ')
    .replace(/&amp;/gi, '&')
    .replace(/&quot;|&#34;/gi, '"')
    .replace(/&#39;|&apos;/gi, "'")
    .replace(/&lt;/gi, '<')
    .replace(/&gt;/gi, '>')
    .replace(/&#36;/gi, '$')
    .replace(/&#x24;/gi, '$');
}

function walkJSON(value, visit, depth = 0) {
  if (depth > 18 || value == null) return;
  visit(value);
  if (Array.isArray(value)) {
    for (const item of value.slice(0, 500)) walkJSON(item, visit, depth + 1);
    return;
  }
  if (typeof value === 'object') {
    for (const item of Object.values(value).slice(0, 500)) walkJSON(item, visit, depth + 1);
  }
}

function roundMoney(value) {
  return Math.round((Number(value) + Number.EPSILON) * 100) / 100;
}

function escapeRegExp(value) {
  return String(value).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}
