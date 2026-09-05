export const HOTEL_PRICE_TTL_MS = 48 * 60 * 60 * 1000;
export const HOTEL_PRICE_RETRY_MS = 6 * 60 * 60 * 1000;
export const HOTEL_PRICE_QUOTE_NIGHTS = 1;
export const HOTEL_PRICE_QUOTE_ADULTS = 2;
export const HOTEL_PRICE_QUOTE_ROOMS = 1;

const MONEY_TOKEN = '(?:US\\$|USD|\\$|SAR|SR|ر\\.?س\\.?|AED|د\\.?إ\\.?)';
const AMOUNT_TOKEN = '([0-9]{1,3}(?:[ ,.]?[0-9]{3})*(?:[.,][0-9]{1,2})?|[0-9]{1,6}(?:[.,][0-9]{1,2})?)';

export function quoteContextFromProbeURL(value, provider) {
  try {
    const url = value instanceof URL ? value : new URL(String(value));
    const checkIn = provider === 'Booking' ? url.searchParams.get('checkin') : url.searchParams.get('chkin');
    const checkOut = provider === 'Booking' ? url.searchParams.get('checkout') : url.searchParams.get('chkout');
    const startMs = checkIn ? Date.parse(`${checkIn}T00:00:00Z`) : NaN;
    const endMs = checkOut ? Date.parse(`${checkOut}T00:00:00Z`) : NaN;
    const rawNights = Number.isFinite(startMs) && Number.isFinite(endMs) ? Math.round((endMs - startMs) / 86400000) : HOTEL_PRICE_QUOTE_NIGHTS;
    const nights = rawNights > 0 && rawNights <= 30 ? rawNights : HOTEL_PRICE_QUOTE_NIGHTS;

    let adults = HOTEL_PRICE_QUOTE_ADULTS;
    let rooms = HOTEL_PRICE_QUOTE_ROOMS;
    if (provider === 'Booking') {
      adults = Math.max(1, Number(url.searchParams.get('group_adults')) || HOTEL_PRICE_QUOTE_ADULTS);
      rooms = Math.max(1, Number(url.searchParams.get('no_rooms')) || HOTEL_PRICE_QUOTE_ROOMS);
    } else if (provider === 'Expedia') {
      const rm1 = String(url.searchParams.get('rm1') || '');
      const adultMatch = /a(\d+)/i.exec(rm1);
      adults = Math.max(1, Number(adultMatch?.[1]) || Number(url.searchParams.get('adults')) || HOTEL_PRICE_QUOTE_ADULTS);
      rooms = Math.max(1, Number(url.searchParams.get('rooms')) || HOTEL_PRICE_QUOTE_ROOMS);
    }

    return {
      checkIn: checkIn || null,
      checkOut: checkOut || null,
      nights,
      adults,
      rooms
    };
  } catch (_) {
    return { checkIn: null, checkOut: null, nights: HOTEL_PRICE_QUOTE_NIGHTS, adults: HOTEL_PRICE_QUOTE_ADULTS, rooms: HOTEL_PRICE_QUOTE_ROOMS };
  }
}

export function hotelPriceMoveNeedsConfirmation(previousUSD, nextUSD) {
  const previous = Number(previousUSD);
  const next = Number(nextUSD);
  if (!Number.isFinite(previous) || previous <= 0 || !Number.isFinite(next) || next <= 0) return false;
  const ratio = next / previous;
  return ratio < 0.65 || ratio > 1.75;
}

export function hotelPriceCandidatesMatch(a, b) {
  const first = Number(a);
  const second = Number(b);
  if (!Number.isFinite(first) || first <= 0 || !Number.isFinite(second) || second <= 0) return false;
  return Math.abs(first - second) / Math.max(first, second) <= 0.08;
}

export function normalizeImportedHotelPriceSnapshot(snapshot) {
  const amount = Number(snapshot?.amount);
  const currency = normalizeCurrency(snapshot?.currency);
  const nights = Math.max(1, Number(snapshot?.nights) || HOTEL_PRICE_QUOTE_NIGHTS);
  const adults = Math.max(1, Number(snapshot?.adults) || HOTEL_PRICE_QUOTE_ADULTS);
  const rooms = Math.max(1, Number(snapshot?.rooms) || HOTEL_PRICE_QUOTE_ROOMS);
  if (!Number.isFinite(amount) || amount <= 0 || !currency) return null;

  const rawBasis = String(snapshot?.priceBasis || '').trim().toLowerCase();
  const basis = rawBasis === 'stay_total' || rawBasis === 'totalstay' || rawBasis === 'total_stay'
    ? 'stay_total'
    : 'nightly';

  const amountUSD = toUSD(amount, currency);
  if (!Number.isFinite(amountUSD) || amountUSD <= 0) return null;

  const nightlyUSD = basis === 'stay_total' ? amountUSD / nights : amountUSD;
  if (!Number.isFinite(nightlyUSD) || nightlyUSD < 15 || nightlyUSD > 5000) return null;

  let quoteTotalUSD = basis === 'stay_total' ? amountUSD : nightlyUSD * nights;
  const totalAmount = Number(snapshot?.totalAmount);
  const totalCurrency = normalizeCurrency(snapshot?.totalCurrency);
  if (Number.isFinite(totalAmount) && totalAmount > 0 && totalCurrency) {
    const convertedTotal = toUSD(totalAmount, totalCurrency);
    if (Number.isFinite(convertedTotal) && convertedTotal > 0) quoteTotalUSD = convertedTotal;
  }

  return {
    amountOriginal: roundMoney(amount),
    currencyOriginal: currency,
    priceBasis: basis,
    nightlyUSD: roundMoney(nightlyUSD),
    stayTotalUSD: roundMoney(quoteTotalUSD),
    checkIn: cleanISODate(snapshot?.checkIn),
    checkOut: cleanISODate(snapshot?.checkOut),
    nights,
    adults,
    rooms,
    confidence: Math.max(0.5, Math.min(1, Number(snapshot?.confidence) || 0.9)),
    method: String(snapshot?.method || 'ios-importer').slice(0, 160)
  };
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
    .map((candidate, sourceOrder) => {
      const value = normalizeCandidate(candidate, nights);
      return value ? { ...value, sourceOrder } : null;
    })
    .filter(Boolean)
    .filter(candidate => candidate.nightlyUSD >= 15 && candidate.nightlyUSD <= 5000);
  if (!normalized.length) return null;

  // Never use "lowest amount wins" here. Provider pages often contain savings,
  // crossed-out prices and totals next to the real sellable nightly rate. Prefer
  // the strongest extraction contract and then the first matching DOM occurrence.
  normalized.sort((a, b) => {
    if (Math.abs(b.confidence - a.confidence) > 0.001) return b.confidence - a.confidence;
    return a.sourceOrder - b.sourceOrder;
  });

  const { sourceOrder: _sourceOrder, ...best } = normalized[0];
  return best;
}

function collectBookingCandidates(html, readable, out, nights) {
  for (const segment of extractTestIDSegments(html, ['price-for-x-nights'])) {
    const money = primaryDisplayMoney(segment);
    if (money) out.push({ ...money, basis: 'stay_total', confidence: 0.99, method: 'booking-price-for-x-nights' });
  }
  for (const segment of extractTestIDContexts(html, 'price-and-discounted-price')) {
    const money = primaryDisplayMoney(segment.element);
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
    const money = primaryDisplayMoney(segment);
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

function moneyTokens(value) {
  const text = htmlToReadableText(String(value || '')).replace(/\u00a0/g, ' ');
  const tokenPattern = new RegExp(`(${MONEY_TOKEN})\\s*${AMOUNT_TOKEN}|${AMOUNT_TOKEN}\\s*(${MONEY_TOKEN})`, 'gi');
  const out = [];
  let match;
  while ((match = tokenPattern.exec(text)) !== null && out.length < 30) {
    let amount = null;
    let currency = null;
    if (match[1]) {
      currency = normalizeCurrency(match[1]);
      amount = parseLocalizedAmount(match[2]);
    } else {
      amount = parseLocalizedAmount(match[3]);
      currency = normalizeCurrency(match[4]);
    }
    if (!amount || !currency) continue;
    out.push({ amount, currency, index: match.index, end: match.index + match[0].length, text });
  }
  return out;
}

function primaryDisplayMoney(value) {
  const tokens = moneyTokens(value);
  if (!tokens.length) return null;
  const text = tokens[0].text;
  const lower = text.toLowerCase();
  const eligible = tokens.filter(item => {
    const before = lower.slice(Math.max(0, item.index - 24), item.index);
    const after = lower.slice(item.end, Math.min(lower.length, item.end + 28));
    // Savings/credits are not room prices. Totals are kept separately from the
    // nightly/base rate and therefore must not win the primary amount slot.
    if (/(?:save|saving|discount|coupon|credit|reward)\s*$/.test(before)) return false;
    if (/^\s*(?:total|tax(?:es)?|fees?|deposit|credit|saving)/.test(after)) return false;
    return true;
  });
  const pool = eligible.length ? eligible : tokens;
  // Provider lockups normally render old/struck price first and the active price
  // immediately after it; taking the last non-total value reproduces the visible
  // public sellable rate (e.g. 495 struck -> 421 -> 508 total => 421).
  const chosen = pool[pool.length - 1];
  return { amount: chosen.amount, currency: chosen.currency };
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

function extractBalancedElement(html, openingIndex, tagName, maxLength = 2400) {
  const source = String(html || '');
  const tag = escapeRegExp(String(tagName || '').toLowerCase());
  if (!tag) return '';
  const limit = Math.min(source.length, openingIndex + maxLength);
  const slice = source.slice(openingIndex, limit);
  const pattern = new RegExp(`<\\/?${tag}\\b[^>]*>`, 'gi');
  let depth = 0;
  let match;
  while ((match = pattern.exec(slice)) !== null) {
    const closing = /^<\//.test(match[0]);
    const selfClosing = /\/\s*>$/.test(match[0]);
    if (!closing) {
      if (!selfClosing) depth += 1;
    } else {
      depth -= 1;
      if (depth === 0) return slice.slice(0, match.index + match[0].length);
    }
  }
  return slice;
}

function extractTestIDSegments(html, testIDs) {
  const out = [];
  for (const id of testIDs) {
    const pattern = new RegExp(`<([a-z0-9]+)[^>]+data-testid=["']${escapeRegExp(id)}["'][^>]*>`, 'gi');
    let match;
    while ((match = pattern.exec(html)) !== null && out.length < 100) {
      out.push(extractBalancedElement(html, match.index, match[1], 2400));
    }
  }
  return out;
}

function extractClassSegments(html, classNames) {
  const out = [];
  for (const name of classNames) {
    const pattern = new RegExp(`<([a-z0-9]+)[^>]+class=["'][^"']*${escapeRegExp(name)}[^"']*["'][^>]*>`, 'gi');
    let match;
    while ((match = pattern.exec(html)) !== null && out.length < 100) {
      out.push(extractBalancedElement(html, match.index, match[1], 2600));
    }
  }
  return out;
}


function cleanISODate(value) {
  const text = String(value || '').trim();
  if (!/^\d{4}-\d{2}-\d{2}$/.test(text)) return null;
  const ms = Date.parse(`${text}T00:00:00Z`);
  return Number.isFinite(ms) ? text : null;
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
