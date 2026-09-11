const JSON_HEADERS = {
  'content-type': 'application/json; charset=utf-8',
  'cache-control': 'no-store'
};

const EXPORT_SCHEMA = 'iumrah.hotel-monitor.v1';
const UPDATE_SCHEMA = 'iumrah.hotel-price-update.v1';
const MAX_IMPORT_ITEMS = 300;
const PRICE_EPSILON = 0.009;

function json(body, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: JSON_HEADERS });
}

function cleanText(value, max = 1000) {
  if (value == null) return '';
  return String(value).replace(/[\u0000-\u001f\u007f]/g, ' ').trim().slice(0, max);
}

function safeID(value) {
  const text = cleanText(value, 220);
  return /^[A-Za-z0-9._:-]+$/.test(text) ? text : null;
}

function canonicalCity(value) {
  const raw = cleanText(value, 80).toLowerCase().replace(/[-_]/g, ' ');
  if (raw.includes('makkah') || raw.includes('mecca') || raw.includes('مكة')) return 'Makkah';
  if (raw.includes('madinah') || raw.includes('medina') || raw.includes('المدينة')) return 'Madinah';
  return null;
}

function roundedPrice(value) {
  const number = Number(value);
  if (!Number.isFinite(number) || number < 1 || number > 10_000) return null;
  return Math.round(number * 100) / 100;
}

function confidenceValue(value) {
  const text = cleanText(value, 20).toLowerCase();
  if (text === 'high') return { label: 'high', score: 0.95 };
  if (text === 'medium') return { label: 'medium', score: 0.80 };
  if (text === 'low') return { label: 'low', score: 0.55 };
  return { label: 'none', score: 0 };
}

function normalizedProvider(value, sourceURL = '') {
  const raw = cleanText(value, 60).toLowerCase();
  if (raw.includes('booking')) return 'Booking';
  if (raw.includes('expedia')) return 'Expedia';
  try {
    const host = new URL(sourceURL).hostname.toLowerCase();
    if (host === 'booking.com' || host.endsWith('.booking.com')) return 'Booking';
    if (host === 'expedia.com' || host.endsWith('.expedia.com') || host.includes('expedia.')) return 'Expedia';
  } catch (_) {}
  return cleanText(value, 60) || null;
}

function sameSource(expected, actual) {
  const a = cleanText(expected, 4000);
  const b = cleanText(actual, 4000);
  if (!a || !b) return false;
  if (a === b) return true;
  try {
    const ua = new URL(a);
    const ub = new URL(b);
    // ChatGPT must preserve the exact hotel page. Query/hash differences are tolerated
    // because providers often append dates, currency and tracking parameters.
    return ua.hostname.toLowerCase() === ub.hostname.toLowerCase()
      && ua.pathname.replace(/\/+$/, '') === ub.pathname.replace(/\/+$/, '');
  } catch (_) {
    return false;
  }
}

async function exportRows(env, city) {
  const result = await env.HOTELS_DB.prepare(`
    SELECT
      h.id,
      h.name,
      h.city,
      h.stars,
      h.status,
      h.updated_at,
      COALESCE(hpo.nightly_price_usd, hp.nightly_price_usd) AS effective_nightly_usd,
      CASE WHEN hpo.nightly_price_usd IS NOT NULL THEN 1 ELSE 0 END AS is_manual_override,
      hp.nightly_price_usd AS source_nightly_usd,
      hp.status AS price_status,
      hp.fetched_at AS price_fetched_at,
      hp.updated_at AS price_updated_at,
      COALESCE(
        hps.provider,
        (SELECT hs.provider FROM hotel_sources hs
          WHERE hs.hotel_id=h.id
            AND LOWER(hs.provider) IN ('booking','booking.com','expedia','expedia.com')
            AND hs.source_url IS NOT NULL AND hs.source_url!=''
          ORDER BY CASE WHEN LOWER(hs.provider) IN ('expedia','expedia.com') THEN 0 ELSE 1 END,
                   hs.checked_at DESC
          LIMIT 1)
      ) AS source_provider,
      COALESCE(
        hps.source_url,
        (SELECT hs.source_url FROM hotel_sources hs
          WHERE hs.hotel_id=h.id
            AND LOWER(hs.provider) IN ('booking','booking.com','expedia','expedia.com')
            AND hs.source_url IS NOT NULL AND hs.source_url!=''
          ORDER BY CASE WHEN LOWER(hs.provider) IN ('expedia','expedia.com') THEN 0 ELSE 1 END,
                   hs.checked_at DESC
          LIMIT 1)
      ) AS source_url
    FROM hotels h
    LEFT JOIN hotel_price_cache hp ON hp.hotel_id=h.id
    LEFT JOIN hotel_price_overrides hpo ON hpo.hotel_id=h.id
    LEFT JOIN hotel_price_sources hps ON hps.hotel_id=h.id
    ORDER BY h.name COLLATE NOCASE ASC
    LIMIT 300
  `).all();
  return (result.results || []).filter(row => canonicalCity(row.city) === city);
}

async function currentHotelRows(env, hotelIDs) {
  if (!hotelIDs.length) return new Map();
  const placeholders = hotelIDs.map(() => '?').join(',');
  const result = await env.HOTELS_DB.prepare(`
    SELECT
      h.id,
      h.name,
      h.city,
      h.stars,
      h.status,
      COALESCE(hpo.nightly_price_usd, hp.nightly_price_usd) AS effective_nightly_usd,
      CASE WHEN hpo.nightly_price_usd IS NOT NULL THEN 1 ELSE 0 END AS is_manual_override,
      hp.nightly_price_usd AS source_nightly_usd,
      COALESCE(
        hps.provider,
        (SELECT hs.provider FROM hotel_sources hs
          WHERE hs.hotel_id=h.id
            AND LOWER(hs.provider) IN ('booking','booking.com','expedia','expedia.com')
            AND hs.source_url IS NOT NULL AND hs.source_url!=''
          ORDER BY CASE WHEN LOWER(hs.provider) IN ('expedia','expedia.com') THEN 0 ELSE 1 END,
                   hs.checked_at DESC
          LIMIT 1)
      ) AS source_provider,
      COALESCE(
        hps.source_url,
        (SELECT hs.source_url FROM hotel_sources hs
          WHERE hs.hotel_id=h.id
            AND LOWER(hs.provider) IN ('booking','booking.com','expedia','expedia.com')
            AND hs.source_url IS NOT NULL AND hs.source_url!=''
          ORDER BY CASE WHEN LOWER(hs.provider) IN ('expedia','expedia.com') THEN 0 ELSE 1 END,
                   hs.checked_at DESC
          LIMIT 1)
      ) AS source_url,
      hps.source_id AS source_id
    FROM hotels h
    LEFT JOIN hotel_price_cache hp ON hp.hotel_id=h.id
    LEFT JOIN hotel_price_overrides hpo ON hpo.hotel_id=h.id
    LEFT JOIN hotel_price_sources hps ON hps.hotel_id=h.id
    WHERE h.id IN (${placeholders})
  `).bind(...hotelIDs).all();
  return new Map((result.results || []).map(row => [row.id, row]));
}

function normalizeUpdateDocument(body) {
  if (!body || typeof body !== 'object' || Array.isArray(body)) {
    return { ok: false, error: 'INVALID_JSON_DOCUMENT' };
  }
  if (body.schema !== UPDATE_SCHEMA) {
    return { ok: false, error: 'UNSUPPORTED_PRICE_UPDATE_SCHEMA' };
  }
  const sourceExportID = safeID(body.sourceExportID);
  if (!sourceExportID) return { ok: false, error: 'SOURCE_EXPORT_ID_REQUIRED' };
  const city = canonicalCity(body.city);
  if (!city) return { ok: false, error: 'INVALID_PRICE_UPDATE_CITY' };
  const checkedAt = cleanText(body.checkedAt, 80) || new Date().toISOString();
  if (!Array.isArray(body.hotels) || body.hotels.length === 0 || body.hotels.length > MAX_IMPORT_ITEMS) {
    return { ok: false, error: 'INVALID_PRICE_UPDATE_ITEMS' };
  }

  const seen = new Set();
  const items = [];
  for (const raw of body.hotels) {
    const hotelID = safeID(raw?.hotelID);
    if (!hotelID || seen.has(hotelID)) continue;
    seen.add(hotelID);
    items.push({
      hotelID,
      hotelName: cleanText(raw?.hotelName, 300) || null,
      status: cleanText(raw?.status, 40).toLowerCase(),
      oldNightlyUSD: roundedPrice(raw?.oldNightlyUSD),
      newNightlyUSD: raw?.newNightlyUSD == null ? null : roundedPrice(raw?.newNightlyUSD),
      provider: normalizedProvider(raw?.provider, raw?.sourceURL),
      sourceURL: cleanText(raw?.sourceURL, 4000) || null,
      checkedSourceURL: cleanText(raw?.checkedSourceURL, 4000) || null,
      confidence: confidenceValue(raw?.confidence),
      reason: cleanText(raw?.reason, 1000) || null,
      checkedAt: cleanText(raw?.checkedAt, 80) || checkedAt
    });
  }
  if (!items.length) return { ok: false, error: 'NO_VALID_PRICE_UPDATE_ITEMS' };
  return { ok: true, document: { schema: UPDATE_SCHEMA, sourceExportID, city, checkedAt, hotels: items } };
}

async function buildPreview(env, document) {
  const rows = await currentHotelRows(env, document.hotels.map(item => item.hotelID));
  const items = [];

  for (const item of document.hotels) {
    const row = rows.get(item.hotelID);
    if (!row) {
      items.push({ ...item, hotelName: item.hotelName || item.hotelID, reviewStatus: 'invalid', selectable: false, issue: 'HOTEL_NOT_FOUND', currentNightlyUSD: null, deltaUSD: null, deltaPercent: null });
      continue;
    }

    const current = roundedPrice(row.effective_nightly_usd);
    const expectedOld = item.oldNightlyUSD;
    const currentSourceURL = cleanText(row.source_url, 4000) || null;
    const currentProvider = normalizedProvider(row.source_provider, currentSourceURL);
    const base = {
      ...item,
      hotelName: row.name || item.hotelName || item.hotelID,
      city: canonicalCity(row.city) || row.city,
      stars: row.stars == null ? null : Number(row.stars),
      currentNightlyUSD: current,
      currentProvider,
      currentSourceURL,
      isManualOverride: Number(row.is_manual_override || 0) === 1
    };

    if ((canonicalCity(row.city) || '') !== document.city) {
      items.push({ ...base, reviewStatus: 'invalid', selectable: false, issue: 'CITY_MISMATCH', deltaUSD: null, deltaPercent: null });
      continue;
    }
    if (!currentSourceURL || !item.sourceURL || !sameSource(currentSourceURL, item.sourceURL)) {
      items.push({ ...base, reviewStatus: 'conflict', selectable: false, issue: 'SOURCE_CHANGED', deltaUSD: null, deltaPercent: null });
      continue;
    }
    if (expectedOld == null || current == null || Math.abs(current - expectedOld) > PRICE_EPSILON) {
      items.push({ ...base, reviewStatus: 'conflict', selectable: false, issue: 'PRICE_CHANGED_AFTER_EXPORT', deltaUSD: item.newNightlyUSD != null && current != null ? Math.round((item.newNightlyUSD - current) * 100) / 100 : null, deltaPercent: null });
      continue;
    }
    if (item.status === 'unverified' || item.status === 'failed' || item.newNightlyUSD == null) {
      items.push({ ...base, reviewStatus: 'unverified', selectable: false, issue: item.reason || 'PRICE_NOT_VERIFIED', deltaUSD: null, deltaPercent: null });
      continue;
    }
    if (!['changed', 'unchanged'].includes(item.status)) {
      items.push({ ...base, reviewStatus: 'invalid', selectable: false, issue: 'INVALID_ITEM_STATUS', deltaUSD: null, deltaPercent: null });
      continue;
    }
    if (item.confidence.label === 'none' || item.confidence.label === 'low') {
      items.push({ ...base, reviewStatus: 'needs_review', selectable: false, issue: 'LOW_CONFIDENCE', deltaUSD: Math.round((item.newNightlyUSD - current) * 100) / 100, deltaPercent: current > 0 ? Math.round(((item.newNightlyUSD - current) / current) * 10000) / 100 : null });
      continue;
    }

    const deltaUSD = Math.round((item.newNightlyUSD - current) * 100) / 100;
    const deltaPercent = current > 0 ? Math.round((deltaUSD / current) * 10000) / 100 : null;
    const changed = Math.abs(deltaUSD) > PRICE_EPSILON;
    items.push({
      ...base,
      reviewStatus: changed ? 'ready' : 'unchanged',
      selectable: changed,
      issue: null,
      deltaUSD,
      deltaPercent
    });
  }

  return {
    schema: UPDATE_SCHEMA,
    sourceExportID: document.sourceExportID,
    city: document.city,
    checkedAt: document.checkedAt,
    total: items.length,
    changed: items.filter(item => item.reviewStatus === 'ready').length,
    unchanged: items.filter(item => item.reviewStatus === 'unchanged').length,
    conflicts: items.filter(item => item.reviewStatus === 'conflict').length,
    unverified: items.filter(item => item.reviewStatus === 'unverified' || item.reviewStatus === 'needs_review').length,
    invalid: items.filter(item => item.reviewStatus === 'invalid').length,
    items
  };
}

async function applySelected(env, document, selectedHotelIDs, user) {
  const preview = await buildPreview(env, document);
  const selected = new Set(selectedHotelIDs.map(safeID).filter(Boolean));
  const ready = preview.items.filter(item => selected.has(item.hotelID) && item.reviewStatus === 'ready' && item.selectable);
  if (!ready.length) {
    return { ok: false, error: 'NO_VALID_PRICES_SELECTED', preview };
  }

  const now = new Date().toISOString();
  let applied = 0;
  const appliedHotelIDs = [];

  // Apply sequentially so every hotel is rechecked immediately before write.
  // This preserves optimistic concurrency even if another admin changes a price
  // between preview and the final confirmation tap.
  for (const item of ready) {
    const latestMap = await currentHotelRows(env, [item.hotelID]);
    const latest = latestMap.get(item.hotelID);
    const latestPrice = roundedPrice(latest?.effective_nightly_usd);
    const latestSource = cleanText(latest?.source_url, 4000) || null;
    if (!latest || latestPrice == null || item.oldNightlyUSD == null) continue;
    if (Math.abs(latestPrice - item.oldNightlyUSD) > PRICE_EPSILON) continue;
    if (!sameSource(latestSource, item.sourceURL)) continue;

    const provider = normalizedProvider(latest.source_provider || item.provider, latestSource) || item.provider || 'External';
    const method = `chatgpt-json-import:${document.sourceExportID}`.slice(0, 180);
    const sourceID = latest.source_id || null;
    const newPrice = item.newNightlyUSD;
    const confidence = item.confidence.score;

    await env.HOTELS_DB.batch([
      env.HOTELS_DB.prepare(`
        INSERT INTO hotel_price_cache (
          hotel_id, source_id, provider, source_url, resolved_url,
          amount_original, currency_original, price_basis, nightly_price_usd,
          quote_total_usd, quote_check_in, quote_check_out, quote_nights, quote_adults, quote_rooms,
          confidence, method, status, fetched_at, expires_at, last_attempt_at, next_retry_at,
          last_http_status, error, pending_nightly_price_usd, pending_seen_count,
          pending_first_seen_at, pending_last_seen_at, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, 'USD', 'nightly', ?, NULL, NULL, NULL, 1, 2, 1, ?, ?, 'fresh', ?, NULL, ?, NULL, 200, NULL, NULL, 0, NULL, NULL, ?, ?)
        ON CONFLICT(hotel_id) DO UPDATE SET
          source_id=excluded.source_id,
          provider=excluded.provider,
          source_url=excluded.source_url,
          resolved_url=excluded.resolved_url,
          amount_original=excluded.amount_original,
          currency_original='USD',
          price_basis='nightly',
          nightly_price_usd=excluded.nightly_price_usd,
          quote_total_usd=NULL,
          quote_check_in=NULL,
          quote_check_out=NULL,
          quote_nights=1,
          quote_adults=2,
          quote_rooms=1,
          confidence=excluded.confidence,
          method=excluded.method,
          status='fresh',
          fetched_at=excluded.fetched_at,
          expires_at=NULL,
          last_attempt_at=excluded.last_attempt_at,
          next_retry_at=NULL,
          last_http_status=200,
          error=NULL,
          pending_nightly_price_usd=NULL,
          pending_seen_count=0,
          pending_first_seen_at=NULL,
          pending_last_seen_at=NULL,
          updated_at=excluded.updated_at
      `).bind(
        item.hotelID,
        sourceID,
        provider,
        latestSource,
        item.checkedSourceURL || latestSource,
        newPrice,
        newPrice,
        confidence,
        method,
        item.checkedAt || document.checkedAt || now,
        now,
        now,
        now
      ),
      // The imported JSON is an explicit admin-approved price. Remove an old
      // manual override so the newly approved catalog price becomes effective.
      env.HOTELS_DB.prepare('DELETE FROM hotel_price_overrides WHERE hotel_id=?').bind(item.hotelID)
    ]);
    applied += 1;
    appliedHotelIDs.push(item.hotelID);
  }

  const appliedSet = new Set(appliedHotelIDs);
  const finalItems = preview.items.map(item => appliedSet.has(item.hotelID)
    ? {
        ...item,
        currentNightlyUSD: item.newNightlyUSD,
        reviewStatus: 'applied',
        selectable: false,
        issue: null,
        deltaUSD: 0,
        deltaPercent: 0
      }
    : item);
  const finalPreview = {
    ...preview,
    changed: finalItems.filter(item => item.reviewStatus === 'ready').length,
    unchanged: finalItems.filter(item => item.reviewStatus === 'unchanged' || item.reviewStatus === 'applied').length,
    conflicts: finalItems.filter(item => item.reviewStatus === 'conflict').length,
    unverified: finalItems.filter(item => item.reviewStatus === 'unverified' || item.reviewStatus === 'needs_review').length,
    invalid: finalItems.filter(item => item.reviewStatus === 'invalid').length,
    items: finalItems
  };
  return {
    ok: true,
    applied,
    requested: selected.size,
    skipped: Math.max(0, selected.size - applied),
    appliedHotelIDs,
    preview: finalPreview,
    appliedBy: cleanText(user?.login, 180) || null,
    appliedAt: now
  };
}

export async function handlePriceJSONAdmin(request, env, url, parts, user) {
  if (parts.length === 1 && parts[0] === 'export' && request.method === 'GET') {
    const city = canonicalCity(url.searchParams.get('city'));
    if (!city) return json({ ok: false, error: 'CITY_REQUIRED' }, 400);
    const rows = await exportRows(env, city);
    const generatedAt = new Date().toISOString();
    const exportID = `hotel-monitor-${city.toLowerCase()}-${crypto.randomUUID()}`;
    const hotels = rows.map(row => ({
      hotelID: row.id,
      hotelName: row.name,
      city: canonicalCity(row.city) || row.city,
      stars: row.stars == null ? null : Number(row.stars),
      currentNightlyUSD: roundedPrice(row.effective_nightly_usd),
      currency: 'USD',
      catalogStatus: row.status || null,
      priceStatus: row.price_status || (Number(row.is_manual_override || 0) === 1 ? 'manual' : null),
      isManualOverride: Number(row.is_manual_override || 0) === 1,
      provider: normalizedProvider(row.source_provider, row.source_url),
      sourceURL: row.source_url || null,
      lastPriceFetchedAt: row.price_fetched_at || row.price_updated_at || null
    }));

    return json({
      schema: EXPORT_SCHEMA,
      version: 1,
      exportID,
      city,
      generatedAt,
      currency: 'USD',
      monitoringPolicy: {
        rooms: 1,
        adults: 2,
        priceBasis: 'nightly',
        dateStrategy: 'same_method_for_every_hotel_nearest_available_future_sample',
        preferredDateOffsetsDays: [20, 25, 30],
        sourceRule: 'Use the supplied sourceURL for the exact hotel. Do not substitute another property.',
        comparisonRule: 'Compare the newly observed USD nightly rate with currentNightlyUSD.',
        returnSchema: UPDATE_SCHEMA
      },
      instructions: [
        'Check every hotel with the same monitoring method.',
        'Preserve hotelID, old price, provider and sourceURL exactly in the result.',
        'Use status changed, unchanged, or unverified.',
        'Do not invent a price when the source cannot be verified.',
        'Return one JSON document using schema iumrah.hotel-price-update.v1.'
      ],
      hotelCount: hotels.length,
      hotels
    });
  }

  if (parts.length === 1 && parts[0] === 'preview' && request.method === 'POST') {
    let body;
    try { body = await request.json(); }
    catch { return json({ ok: false, error: 'INVALID_JSON_DOCUMENT' }, 400); }
    const normalized = normalizeUpdateDocument(body);
    if (!normalized.ok) return json({ ok: false, error: normalized.error }, 422);
    const preview = await buildPreview(env, normalized.document);
    return json({ ok: true, preview });
  }

  if (parts.length === 1 && parts[0] === 'apply' && request.method === 'POST') {
    let body;
    try { body = await request.json(); }
    catch { return json({ ok: false, error: 'INVALID_JSON_DOCUMENT' }, 400); }
    const normalized = normalizeUpdateDocument(body?.document);
    if (!normalized.ok) return json({ ok: false, error: normalized.error }, 422);
    const hotelIDs = Array.isArray(body?.hotelIDs) ? body.hotelIDs : [];
    const result = await applySelected(env, normalized.document, hotelIDs, user);
    if (!result.ok) return json(result, 409);
    return json(result);
  }

  return json({ ok: false, error: 'NOT_FOUND' }, 404);
}
