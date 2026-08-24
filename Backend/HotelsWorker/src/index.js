import { WorkflowEntrypoint } from 'cloudflare:workers';

const JSON_HEADERS = {
  'content-type': 'application/json; charset=utf-8',
  'cache-control': 'no-store'
};

const PUBLIC_CACHE_HEADERS = {
  'cache-control': 'public, max-age=60, s-maxage=300'
};

export default {
  async fetch(request, env) {
    try {
      const url = new URL(request.url);

      if (request.method === 'OPTIONS') {
        return new Response(null, {
          status: 204,
          headers: corsHeaders(request)
        });
      }

      if (url.pathname.startsWith('/api/admin/hotels')) {
        const staff = await requireStaff(request, env);
        if (!staff.ok) return staff.response;
        return withCors(await handleAdmin(request, env, url, staff.user), request);
      }

      if (url.pathname.startsWith('/api/catalog/hotels')) {
        return withCors(await handleCatalog(request, env, url), request);
      }

      return json({ ok: false, error: 'NOT_FOUND' }, 404);
    } catch (error) {
      console.error('HOTELS_API_UNHANDLED', error);
      return json({ ok: false, error: 'INTERNAL_ERROR' }, 500);
    }
  }
};

async function handleAdmin(request, env, url, user) {
  const parts = pathParts(url.pathname, '/api/admin/hotels');

  if (parts.length === 0) {
    if (request.method === 'GET') {
      return listHotels(env, url, false);
    }
    if (request.method === 'POST') {
      return saveHotel(request, env, user);
    }
    return methodNotAllowed();
  }

  if (parts.length === 1 && parts[0] === 'health') {
    if (request.method !== 'GET') return methodNotAllowed();
    return health(env, true);
  }

  if (parts[0] === 'dedupe') {
    if (request.method !== 'POST' || parts.length !== 1) return methodNotAllowed();
    return checkDuplicateRequest(request, env);
  }

  if (parts[0] === 'import-jobs') {
    if (parts.length === 1 && request.method === 'GET') return listImportJobs(env, url);
    if (parts.length === 1 && request.method === 'POST') return createImportJob(request, env, user);
    const jobID = safeID(parts[1]);
    if (!jobID) return json({ ok: false, error: 'INVALID_JOB_ID' }, 400);
    if (parts.length === 2 && request.method === 'GET') return importJobDetail(env, jobID);
    if (parts.length === 3 && parts[2] === 'retry' && request.method === 'POST') return retryImportJob(env, jobID);
    return methodNotAllowed();
  }

  const hotelID = safeID(parts[0]);
  if (!hotelID) return json({ ok: false, error: 'INVALID_HOTEL_ID' }, 400);

  if (parts.length === 1) {
    if (request.method === 'GET') return hotelDetail(env, hotelID, true);
    if (request.method === 'DELETE') return deleteHotel(env, hotelID);
    return methodNotAllowed();
  }

  if (parts.length === 2 && parts[1] === 'images') {
    if (request.method === 'POST') return uploadHotelImage(request, env, hotelID);
    if (request.method === 'DELETE') return deleteAllHotelImages(env, hotelID);
    return methodNotAllowed();
  }

  if (parts.length === 3 && parts[1] === 'images') {
    if (request.method !== 'GET') return methodNotAllowed();
    return serveHotelImage(env, hotelID, parts[2], true);
  }

  return json({ ok: false, error: 'NOT_FOUND' }, 404);
}

async function handleCatalog(request, env, url) {
  const parts = pathParts(url.pathname, '/api/catalog/hotels');

  if (parts.length === 0) {
    if (request.method !== 'GET') return methodNotAllowed();
    return listHotels(env, url, true);
  }

  if (parts.length === 1 && parts[0] === 'health') {
    if (request.method !== 'GET') return methodNotAllowed();
    return health(env, false);
  }

  const hotelID = safeID(parts[0]);
  if (!hotelID) return json({ ok: false, error: 'INVALID_HOTEL_ID' }, 400);

  if (parts.length === 1) {
    if (request.method !== 'GET') return methodNotAllowed();
    return hotelDetail(env, hotelID, false);
  }

  if (parts.length === 3 && parts[1] === 'translations') {
    if (request.method !== 'GET') return methodNotAllowed();
    return hotelTranslation(env, hotelID, parts[2]);
  }

  if (parts.length === 3 && parts[1] === 'images') {
    if (request.method !== 'GET') return methodNotAllowed();
    return serveHotelImage(env, hotelID, parts[2], false);
  }

  return json({ ok: false, error: 'NOT_FOUND' }, 404);
}

async function requireStaff(request, env) {
  const cookie = request.headers.get('cookie') || '';
  if (!cookie) {
    return { ok: false, response: json({ ok: false, error: 'UNAUTHORIZED' }, 401) };
  }

  let response;
  try {
    response = await fetch(env.AUTH_SESSION_URL || 'https://iumrah.app/api/auth/staff/session', {
      method: 'GET',
      headers: {
        'cookie': cookie,
        'accept': 'application/json',
        'user-agent': request.headers.get('user-agent') || 'iumrah-business'
      },
      redirect: 'manual'
    });
  } catch (error) {
    console.error('AUTH_PROXY_FAILED', error);
    return { ok: false, response: json({ ok: false, error: 'AUTH_SERVICE_UNAVAILABLE' }, 503) };
  }

  if (!response.ok) {
    return { ok: false, response: json({ ok: false, error: 'UNAUTHORIZED' }, 401) };
  }

  const payload = await response.json().catch(() => null);
  const user = payload?.user;
  const role = String(user?.role || '').toLowerCase();
  if (!user || !['superadmin', 'admin'].includes(role)) {
    return { ok: false, response: json({ ok: false, error: 'FORBIDDEN' }, 403) };
  }

  return { ok: true, user };
}

async function health(env, admin) {
  const row = await env.HOTELS_DB.prepare(
    admin
      ? 'SELECT COUNT(*) AS count FROM hotels'
      : "SELECT COUNT(*) AS count FROM hotels WHERE status = 'published'"
  ).first();

  return json({
    ok: true,
    database: 'iumrah-hotels',
    storage: 'iumrah-hotels-media',
    hotels: Number(row?.count || 0)
  }, 200, PUBLIC_CACHE_HEADERS);
}

async function listHotels(env, url, publishedOnly) {
  const city = cleanText(url.searchParams.get('city'), 80);
  const values = [];
  const where = [];

  if (publishedOnly) where.push("h.status = 'published'");
  if (city) {
    where.push('LOWER(h.city) = LOWER(?)');
    values.push(city);
  }

  const sql = `
    SELECT
      h.id,
      h.name,
      h.city,
      h.stars,
      h.rating,
      h.review_count,
      h.status,
      h.updated_at,
      (SELECT COUNT(*) FROM hotel_images hi WHERE hi.hotel_id = h.id) AS image_count,
      (SELECT COUNT(*) FROM hotel_rooms hr WHERE hr.hotel_id = h.id) AS room_count,
      (
        SELECT hi.id
        FROM hotel_images hi
        WHERE hi.hotel_id = h.id
        ORDER BY hi.is_cover DESC, hi.position ASC, hi.created_at ASC
        LIMIT 1
      ) AS cover_image_id
    FROM hotels h
    ${where.length ? `WHERE ${where.join(' AND ')}` : ''}
    ORDER BY
      CASE LOWER(h.city) WHEN 'makkah' THEN 0 WHEN 'madinah' THEN 1 ELSE 2 END,
      h.name COLLATE NOCASE ASC
    LIMIT 500
  `;

  const result = await env.HOTELS_DB.prepare(sql).bind(...values).all();
  const hotels = (result.results || []).map(row => hotelSummary(row));
  return json({ hotels }, 200, publishedOnly ? PUBLIC_CACHE_HEADERS : undefined);
}

async function hotelDetail(env, hotelID, admin) {
  const hotel = await env.HOTELS_DB.prepare(
    `SELECT * FROM hotels WHERE id = ? ${admin ? '' : "AND status = 'published'"}`
  ).bind(hotelID).first();

  if (!hotel) return json({ ok: false, error: 'HOTEL_NOT_FOUND' }, 404);

  const [amenitiesResult, roomsResult, imagesResult, sourcesResult] = await Promise.all([
    env.HOTELS_DB.prepare('SELECT amenity FROM hotel_amenities WHERE hotel_id = ? ORDER BY position ASC, amenity ASC').bind(hotelID).all(),
    env.HOTELS_DB.prepare('SELECT id, name, max_guests, size_m2, beds, view, description, amenities_json FROM hotel_rooms WHERE hotel_id = ? ORDER BY position ASC, name ASC').bind(hotelID).all(),
    env.HOTELS_DB.prepare('SELECT id, source_provider, category, label, room_name, position, is_cover FROM hotel_images WHERE hotel_id = ? ORDER BY is_cover DESC, position ASC, created_at ASC').bind(hotelID).all(),
    admin
      ? env.HOTELS_DB.prepare('SELECT * FROM hotel_sources WHERE hotel_id = ? ORDER BY provider ASC').bind(hotelID).all()
      : Promise.resolve({ results: [] })
  ]);

  const images = (imagesResult.results || []).map(row => ({
    id: row.id,
    provider: row.source_provider,
    category: row.category || 'gallery',
    label: row.label || null,
    roomName: row.room_name || null,
    position: Number(row.position || 0),
    isCover: Number(row.is_cover || 0) === 1,
    url: publicImagePath(hotelID, row.id)
  }));

  const detail = {
    id: hotel.id,
    name: hotel.name,
    city: hotel.city,
    country: hotel.country,
    propertyType: hotel.property_type || null,
    stars: hotel.stars == null ? null : Number(hotel.stars),
    rating: hotel.rating == null ? null : Number(hotel.rating),
    ratingScale: hotel.rating_scale == null ? null : Number(hotel.rating_scale),
    reviewCount: hotel.review_count == null ? null : Number(hotel.review_count),
    address: hotel.address || '',
    description: hotel.description || '',
    latitude: hotel.latitude == null ? null : Number(hotel.latitude),
    longitude: hotel.longitude == null ? null : Number(hotel.longitude),
    checkIn: hotel.check_in || null,
    checkOut: hotel.check_out || null,
    policies: parseJSONArray(hotel.policies_json),
    nearby: parseJSONArray(hotel.nearby_json),
    facts: parseJSONArray(hotel.facts_json),
    fees: parseJSONArray(hotel.fees_json),
    services: parseJSONArray(hotel.services_json),
    googleMapsURL: hotel.google_maps_url || googleMapsURL(hotel.latitude, hotel.longitude, hotel.address),
    canonicalKey: hotel.canonical_key || null,
    status: hotel.status,
    amenities: (amenitiesResult.results || []).map(row => row.amenity),
    rooms: (roomsResult.results || []).map(row => ({
      id: row.id,
      name: row.name,
      maxGuests: row.max_guests == null ? null : Number(row.max_guests),
      sizeM2: row.size_m2 == null ? null : Number(row.size_m2),
      beds: row.beds,
      view: row.view,
      description: row.description || null,
      amenities: parseJSONArray(row.amenities_json)
    })),
    images,
    sources: admin ? (sourcesResult.results || []).map(sourceRow) : [],
    createdAt: hotel.created_at,
    updatedAt: hotel.updated_at
  };

  return json({ ok: true, hotel: detail }, 200, admin ? undefined : PUBLIC_CACHE_HEADERS);
}

async function saveHotel(request, env, user) {
  const payload = await readJSON(request, 4_000_000);
  if (!payload.ok) return payload.response;

  const result = await persistHotelDraft(payload.value, env, user, { checkDuplicate: false });
  if (!result.ok) return result.response;
  return json({ ok: true, hotel: result.hotel }, 200);
}

async function persistHotelDraft(draft, env, user, options = {}) {
  const id = safeID(draft?.id);
  const name = cleanText(draft?.name, 180);
  const city = canonicalCity(draft?.city);

  if (!id || !name || !city) {
    return { ok: false, response: json({ ok: false, error: 'INVALID_HOTEL_PAYLOAD' }, 400) };
  }

  if (options.checkDuplicate) {
    const duplicate = await findDuplicateHotel(env, draft, id);
    if (duplicate) {
      return {
        ok: false,
        duplicate,
        response: json({ ok: false, error: 'HOTEL_ALREADY_EXISTS', duplicate }, 409)
      };
    }
  }

  const country = cleanText(draft.country, 120) || 'Saudi Arabia';
  const propertyType = cleanText(draft.propertyType, 120);
  const stars = nullableInteger(draft.stars, 1, 5);
  const rating = nullableNumber(draft.rating, 0, 10);
  const ratingScale = nullableNumber(draft.ratingScale, 1, 10);
  const reviewCount = nullableInteger(draft.reviewCount, 0, 100000000);
  const address = cleanText(draft.address, 900) || '';
  const description = cleanText(draft.description, 20_000) || '';
  const latitude = nullableNumber(draft.latitude, -90, 90);
  const longitude = nullableNumber(draft.longitude, -180, 180);
  const checkIn = cleanText(draft.checkIn, 120);
  const checkOut = cleanText(draft.checkOut, 120);
  const policies = uniqueStrings(draft.policies, 260, 900);
  const nearby = safeObjectArray(draft.nearby, 220, 64_000);
  const facts = safeObjectArray(draft.facts, 420, 160_000);
  const fees = safeObjectArray(draft.fees, 220, 80_000);
  const services = uniqueStrings(draft.services, 300, 240);
  const googleMaps = cleanURL(draft.googleMapsURL) || googleMapsURL(latitude, longitude, address);
  const canonicalKey = canonicalHotelKey(name, city, address, latitude, longitude);
  const status = ['draft', 'published', 'archived'].includes(draft.status) ? draft.status : 'draft';
  const slug = await uniqueSlug(env, id, `${name}-${city}`);
  const now = new Date().toISOString();

  const statements = [
    env.HOTELS_DB.prepare(`
      INSERT INTO hotels (
        id, slug, name, city, country, property_type, stars, rating, rating_scale,
        review_count, address, description, latitude, longitude, check_in, check_out,
        policies_json, canonical_key, google_maps_url, nearby_json, facts_json, fees_json,
        services_json, status, created_at, updated_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        name = excluded.name,
        city = excluded.city,
        country = excluded.country,
        property_type = excluded.property_type,
        stars = excluded.stars,
        rating = excluded.rating,
        rating_scale = excluded.rating_scale,
        review_count = excluded.review_count,
        address = excluded.address,
        description = excluded.description,
        latitude = excluded.latitude,
        longitude = excluded.longitude,
        check_in = excluded.check_in,
        check_out = excluded.check_out,
        policies_json = excluded.policies_json,
        canonical_key = excluded.canonical_key,
        google_maps_url = excluded.google_maps_url,
        nearby_json = excluded.nearby_json,
        facts_json = excluded.facts_json,
        fees_json = excluded.fees_json,
        services_json = excluded.services_json,
        status = excluded.status,
        updated_at = excluded.updated_at
    `).bind(
      id, slug, name, city, country, propertyType, stars, rating, ratingScale, reviewCount,
      address, description, latitude, longitude, checkIn, checkOut, JSON.stringify(policies),
      canonicalKey, googleMaps, JSON.stringify(nearby), JSON.stringify(facts), JSON.stringify(fees),
      JSON.stringify(services), status, now, now
    ),
    env.HOTELS_DB.prepare('DELETE FROM hotel_amenities WHERE hotel_id = ?').bind(id),
    env.HOTELS_DB.prepare('DELETE FROM hotel_rooms WHERE hotel_id = ?').bind(id),
    env.HOTELS_DB.prepare('DELETE FROM hotel_sources WHERE hotel_id = ?').bind(id),
    env.HOTELS_DB.prepare('DELETE FROM hotel_translations WHERE hotel_id = ?').bind(id)
  ];

  const amenities = uniqueStrings(draft.amenities, 320, 240);
  amenities.forEach((amenity, index) => {
    statements.push(
      env.HOTELS_DB.prepare('INSERT INTO hotel_amenities (hotel_id, amenity, position) VALUES (?, ?, ?)')
        .bind(id, amenity, index)
    );
  });

  const rooms = Array.isArray(draft.rooms) ? draft.rooms.slice(0, 200) : [];
  rooms.forEach((room, index) => {
    const roomID = safeID(room?.id) || crypto.randomUUID();
    const roomName = cleanText(room?.name, 240);
    if (!roomName || !isPlausibleRoomName(roomName)) return;
    statements.push(
      env.HOTELS_DB.prepare(`
        INSERT INTO hotel_rooms (
          id, hotel_id, name, max_guests, size_m2, beds, view, description, amenities_json, position
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      `).bind(
        roomID,
        id,
        roomName,
        nullableInteger(room?.maxGuests, 1, 30),
        nullableNumber(room?.sizeM2, 1, 3000),
        cleanText(room?.beds, 300),
        cleanText(room?.view, 300),
        cleanText(room?.description, 5000),
        JSON.stringify(uniqueStrings(room?.amenities, 100, 220)),
        index
      )
    );
  });

  const sources = Array.isArray(draft.sources) ? draft.sources.slice(0, 10) : [];
  sources.forEach(source => {
    const sourceURL = cleanURL(source?.sourceURL);
    const provider = cleanText(source?.provider, 80);
    if (!sourceURL || !provider) return;
    const sourceNearby = safeObjectArray(source?.nearby, 220, 64_000);
    const sourceFacts = safeObjectArray(source?.facts, 420, 160_000);
    const sourceFees = safeObjectArray(source?.fees, 220, 80_000);
    const sourceServices = uniqueStrings(source?.services, 300, 240);
    statements.push(
      env.HOTELS_DB.prepare(`
        INSERT INTO hotel_sources (
          id, hotel_id, provider, source_url, source_name, city, country, property_type,
          address, description, stars, rating, rating_scale, review_count, latitude, longitude,
          check_in, check_out, images_json, amenities_json, room_names_json, room_details_json,
          policies_json, provider_hotel_id, canonical_url, google_maps_url, nearby_json, facts_json,
          fees_json, services_json, checked_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      `).bind(
        safeID(source?.id) || crypto.randomUUID(),
        id,
        provider,
        sourceURL,
        cleanText(source?.name, 300),
        canonicalCity(source?.city) || cleanText(source?.city, 80),
        cleanText(source?.country, 120),
        cleanText(source?.propertyType, 120),
        cleanText(source?.address, 900),
        cleanText(source?.description, 20_000),
        nullableInteger(source?.stars, 1, 5),
        nullableNumber(source?.rating, 0, 10),
        nullableNumber(source?.ratingScale, 1, 10),
        nullableInteger(source?.reviewCount, 0, 100000000),
        nullableNumber(source?.latitude, -90, 90),
        nullableNumber(source?.longitude, -180, 180),
        cleanText(source?.checkIn, 120),
        cleanText(source?.checkOut, 120),
        JSON.stringify(uniqueStrings(source?.images, 600, 3000)),
        JSON.stringify(uniqueStrings(source?.amenities, 240, 240)),
        JSON.stringify(uniqueStrings(source?.roomNames, 180, 280)),
        JSON.stringify(Array.isArray(source?.rooms) ? source.rooms.filter(r => isPlausibleRoomName(r?.name)).slice(0, 200) : []),
        JSON.stringify(uniqueStrings(source?.policies, 260, 900)),
        cleanText(source?.providerHotelID, 220),
        cleanURL(source?.canonicalURL),
        cleanURL(source?.googleMapsURL) || googleMapsURL(source?.latitude, source?.longitude, source?.address),
        JSON.stringify(sourceNearby),
        JSON.stringify(sourceFacts),
        JSON.stringify(sourceFees),
        JSON.stringify(sourceServices),
        now
      )
    );
  });

  await env.HOTELS_DB.batch(statements);

  console.log('HOTEL_SAVED', {
    hotelID: id,
    status,
    actor: user?.login || user?.email || 'staff',
    amenities: amenities.length,
    rooms: rooms.length,
    sources: sources.length,
    nearby: nearby.length,
    facts: facts.length
  });

  const row = await summaryRow(env, id);
  return { ok: true, hotel: hotelSummary(row), hotelID: id };
}


async function checkDuplicateRequest(request, env) {
  const payload = await readJSON(request, 600_000);
  if (!payload.ok) return payload.response;
  const duplicate = await findDuplicateHotel(env, payload.value || {}, null);
  return json({ ok: true, duplicate: duplicate || null });
}

async function findDuplicateHotel(env, draft, excludeID = null) {
  const sourceURLs = [];
  if (cleanURL(draft?.sourceURL)) sourceURLs.push(cleanURL(draft.sourceURL));
  for (const source of Array.isArray(draft?.sources) ? draft.sources : []) {
    const url = cleanURL(source?.sourceURL);
    if (url) sourceURLs.push(url);
  }

  for (const sourceURL of [...new Set(sourceURLs)]) {
    const canonicalSource = canonicalSourceURL(sourceURL);
    const row = await env.HOTELS_DB.prepare(`
      SELECT h.id, h.name, h.city, h.address, h.latitude, h.longitude, hs.provider, hs.source_url
      FROM hotel_sources hs JOIN hotels h ON h.id = hs.hotel_id
      WHERE (hs.source_url = ? OR hs.canonical_url = ?) ${excludeID ? 'AND h.id != ?' : ''}
      LIMIT 1
    `).bind(...(excludeID ? [sourceURL, canonicalSource, excludeID] : [sourceURL, canonicalSource])).first();
    if (row) return duplicateSummary(row, 'same_source');
  }

  for (const source of Array.isArray(draft?.sources) ? draft.sources : []) {
    const provider = cleanText(source?.provider, 80);
    const providerHotelID = cleanText(source?.providerHotelID, 220);
    if (!provider || !providerHotelID) continue;
    const row = await env.HOTELS_DB.prepare(`
      SELECT h.id, h.name, h.city, h.address, h.latitude, h.longitude, hs.provider, hs.source_url
      FROM hotel_sources hs JOIN hotels h ON h.id = hs.hotel_id
      WHERE LOWER(hs.provider) = LOWER(?) AND hs.provider_hotel_id = ? ${excludeID ? 'AND h.id != ?' : ''}
      LIMIT 1
    `).bind(...(excludeID ? [provider, providerHotelID, excludeID] : [provider, providerHotelID])).first();
    if (row) return duplicateSummary(row, 'provider_id');
  }

  const name = cleanText(draft?.name, 180);
  const city = canonicalCity(draft?.city);
  if (!name || !city) return null;

  const latitude = nullableNumber(draft?.latitude, -90, 90);
  const longitude = nullableNumber(draft?.longitude, -180, 180);
  const address = cleanText(draft?.address, 900) || '';
  const candidates = await env.HOTELS_DB.prepare(`
    SELECT id, name, city, address, latitude, longitude
    FROM hotels
    WHERE LOWER(city) = LOWER(?) ${excludeID ? 'AND id != ?' : ''}
    ORDER BY updated_at DESC
    LIMIT 600
  `).bind(...(excludeID ? [city, excludeID] : [city])).all();

  const requestedTokens = hotelNameTokens(name);
  const requestedAddress = normalizedAddress(address);
  for (const row of candidates.results || []) {
    const nameScore = tokenSimilarity(requestedTokens, hotelNameTokens(row.name));
    const addressScore = requestedAddress && row.address ? tokenSimilarity(addressTokens(requestedAddress), addressTokens(normalizedAddress(row.address))) : 0;
    const geoMeters = latitude != null && longitude != null && row.latitude != null && row.longitude != null
      ? haversineMeters(latitude, longitude, Number(row.latitude), Number(row.longitude))
      : null;

    const strongGeoAndName = geoMeters != null && geoMeters <= 180 && nameScore >= 0.50;
    const strongNameAndAddress = nameScore >= 0.72 && addressScore >= 0.52;
    const exactishName = nameScore >= 0.92;
    if (strongGeoAndName || strongNameAndAddress || exactishName) {
      return duplicateSummary({ ...row, provider: null, source_url: null }, geoMeters != null ? 'same_property_geo' : 'same_property_name');
    }
  }

  return null;
}

function duplicateSummary(row, match) {
  return {
    id: row.id,
    name: row.name,
    city: row.city,
    address: row.address || '',
    latitude: row.latitude == null ? null : Number(row.latitude),
    longitude: row.longitude == null ? null : Number(row.longitude),
    provider: row.provider || null,
    sourceURL: row.source_url || null,
    match
  };
}

async function createImportJob(request, env, user) {
  const payload = await readJSON(request, 4_000_000);
  if (!payload.ok) return payload.response;
  const draft = payload.value?.hotel || payload.value;
  const selectedImages = Array.isArray(payload.value?.images)
    ? payload.value.images
    : Array.isArray(draft?.images) ? draft.images.filter(image => image?.selected !== false) : [];

  const duplicate = await findDuplicateHotel(env, draft, null);
  if (duplicate) return json({ ok: false, error: 'HOTEL_ALREADY_EXISTS', duplicate }, 409);

  const canPublish = Boolean(payload.value?.publishWhenComplete) && selectedImages.length >= 4 && Array.isArray(draft?.rooms) && draft.rooms.length > 0;
  const safeDraft = { ...draft, status: 'draft' };
  const persisted = await persistHotelDraft(safeDraft, env, user, { checkDuplicate: false });
  if (!persisted.ok) return persisted.response;

  const hotelID = persisted.hotelID;
  const jobID = `hotel-import-${crypto.randomUUID()}`;
  const images = selectedImages.slice(0, 240).map((image, index) => ({
    url: cleanURL(image?.url),
    provider: cleanText(image?.provider, 80) || 'unknown',
    sourcePageURL: cleanURL(image?.sourcePageURL),
    category: validImageCategory(image?.kind) || validImageCategory(image?.category) || 'gallery',
    label: cleanText(image?.label, 600),
    roomName: cleanText(image?.roomName, 260),
    isCover: image?.isCover === true,
    position: index
  })).filter(image => image.url);

  if (!images.length) return json({ ok: false, error: 'NO_IMAGES_SELECTED' }, 400);

  await env.HOTELS_DB.prepare(`
    INSERT INTO hotel_import_jobs (
      id, hotel_id, hotel_name, source_provider, source_url, status, stage, progress,
      total_images, stored_images, failed_images, images_json, publish_when_complete, updated_at
    ) VALUES (?, ?, ?, ?, ?, 'queued', 'queued', 0, ?, 0, 0, ?, ?, ?)
  `).bind(
    jobID,
    hotelID,
    cleanText(draft?.name, 180) || hotelID,
    cleanText(draft?.sources?.[0]?.provider, 80),
    cleanURL(draft?.sources?.[0]?.sourceURL),
    images.length,
    JSON.stringify(images),
    canPublish ? 1 : 0,
    new Date().toISOString()
  ).run();

  try {
    const instance = await env.HOTEL_IMPORT_WORKFLOW.create({
      id: jobID,
      params: { jobID, hotelID, images, publishWhenComplete: canPublish }
    });
    await env.HOTELS_DB.prepare(`
      UPDATE hotel_import_jobs SET workflow_instance_id = ?, updated_at = ? WHERE id = ?
    `).bind(instance.id, new Date().toISOString(), jobID).run();
  } catch (error) {
    console.error('HOTEL_WORKFLOW_START_FAILED', error);
    await env.HOTELS_DB.prepare(`
      UPDATE hotel_import_jobs SET status = 'failed', stage = 'start_failed', error = ?, completed_at = ?, updated_at = ? WHERE id = ?
    `).bind(String(error?.message || error).slice(0, 1200), new Date().toISOString(), new Date().toISOString(), jobID).run();
    return json({ ok: false, error: 'IMPORT_WORKFLOW_START_FAILED', jobID }, 503);
  }

  return importJobDetail(env, jobID, 202);
}

async function listImportJobs(env, url) {
  const activeOnly = url.searchParams.get('active') === '1';
  const sql = `
    SELECT * FROM hotel_import_jobs
    ${activeOnly ? "WHERE status IN ('queued','running')" : ''}
    ORDER BY created_at DESC
    LIMIT 80
  `;
  const result = await env.HOTELS_DB.prepare(sql).all();
  return json({ ok: true, jobs: (result.results || []).map(importJobRow) });
}

async function importJobDetail(env, jobID, status = 200) {
  const row = await env.HOTELS_DB.prepare('SELECT * FROM hotel_import_jobs WHERE id = ?').bind(jobID).first();
  if (!row) return json({ ok: false, error: 'IMPORT_JOB_NOT_FOUND' }, 404);
  return json({ ok: true, job: importJobRow(row) }, status);
}

async function retryImportJob(env, jobID) {
  const row = await env.HOTELS_DB.prepare('SELECT * FROM hotel_import_jobs WHERE id = ?').bind(jobID).first();
  if (!row) return json({ ok: false, error: 'IMPORT_JOB_NOT_FOUND' }, 404);
  if (!['failed'].includes(row.status)) return json({ ok: false, error: 'IMPORT_JOB_NOT_RETRYABLE' }, 409);

  const images = parseJSONArray(row.images_json);
  await env.HOTELS_DB.prepare(`
    UPDATE hotel_import_jobs
    SET status='queued', stage='retry_queued', progress=0, stored_images=0, failed_images=0, error=NULL,
        started_at=NULL, completed_at=NULL, updated_at=? WHERE id=?
  `).bind(new Date().toISOString(), jobID).run();
  await deleteAllHotelImagesInternal(env, row.hotel_id);

  try {
    const instance = await env.HOTEL_IMPORT_WORKFLOW.create({
      id: `${jobID}-retry-${crypto.randomUUID().slice(0, 8)}`,
      params: { jobID, hotelID: row.hotel_id, images, publishWhenComplete: Number(row.publish_when_complete) === 1 }
    });
    await env.HOTELS_DB.prepare('UPDATE hotel_import_jobs SET workflow_instance_id=?, updated_at=? WHERE id=?')
      .bind(instance.id, new Date().toISOString(), jobID).run();
  } catch (error) {
    await env.HOTELS_DB.prepare("UPDATE hotel_import_jobs SET status='failed', stage='start_failed', error=?, updated_at=? WHERE id=?")
      .bind(String(error?.message || error).slice(0, 1200), new Date().toISOString(), jobID).run();
    return json({ ok: false, error: 'IMPORT_WORKFLOW_START_FAILED' }, 503);
  }
  return importJobDetail(env, jobID, 202);
}

function importJobRow(row) {
  return {
    id: row.id,
    hotelID: row.hotel_id,
    hotelName: row.hotel_name,
    sourceProvider: row.source_provider || null,
    sourceURL: row.source_url || null,
    status: row.status,
    stage: row.stage,
    progress: Number(row.progress || 0),
    totalImages: Number(row.total_images || 0),
    storedImages: Number(row.stored_images || 0),
    failedImages: Number(row.failed_images || 0),
    publishWhenComplete: Number(row.publish_when_complete || 0) === 1,
    error: row.error || null,
    createdAt: row.created_at,
    startedAt: row.started_at || null,
    completedAt: row.completed_at || null,
    updatedAt: row.updated_at
  };
}

export class HotelImportWorkflow extends WorkflowEntrypoint {
  async run(event, step) {
    const { jobID, hotelID, images = [], publishWhenComplete = false } = event.payload || {};
    if (!safeID(jobID) || !safeID(hotelID) || !Array.isArray(images)) {
      throw new Error('INVALID_IMPORT_WORKFLOW_PAYLOAD');
    }

    await step.do('mark job running', async () => {
      const now = new Date().toISOString();
      await this.env.HOTELS_DB.prepare(`
        UPDATE hotel_import_jobs
        SET status='running', stage='downloading_images', progress=1, started_at=COALESCE(started_at, ?), updated_at=?
        WHERE id=?
      `).bind(now, now, jobID).run();
      return { ok: true };
    });

    let stored = 0;
    let failed = 0;
    const total = images.length;

    for (let index = 0; index < total; index += 1) {
      const item = images[index];
      let result;
      try {
        result = await step.do(
          `store image ${String(index + 1).padStart(3, '0')}`,
          { retries: { limit: 4, delay: '4 seconds', backoff: 'exponential' }, timeout: '2 minutes' },
          async () => storeRemoteHotelImage(this.env, hotelID, item, index)
        );
      } catch (error) {
        result = { ok: false, error: String(error?.message || error).slice(0, 900) };
      }

      if (result?.ok) stored += 1;
      else failed += 1;

      const progress = Math.min(96, Math.max(2, Math.round(((index + 1) / Math.max(total, 1)) * 94)));
      await step.do(`record progress ${String(index + 1).padStart(3, '0')}`, async () => {
        await this.env.HOTELS_DB.prepare(`
          UPDATE hotel_import_jobs
          SET stored_images=?, failed_images=?, progress=?, stage=?, error=?, updated_at=?
          WHERE id=?
        `).bind(
          stored,
          failed,
          progress,
          result?.ok ? 'downloading_images' : 'image_retry_exhausted',
          result?.ok ? null : result?.error || 'IMAGE_FAILED',
          new Date().toISOString(),
          jobID
        ).run();
        return { stored, failed, progress };
      });
    }

    const finalState = await step.do('finalize hotel import', async () => {
      const now = new Date().toISOString();
      const completed = failed === 0 && stored === total && total > 0;
      if (completed && publishWhenComplete) {
        await this.env.HOTELS_DB.prepare("UPDATE hotels SET status='published', updated_at=? WHERE id=?")
          .bind(now, hotelID).run();
      } else {
        await this.env.HOTELS_DB.prepare("UPDATE hotels SET status='draft', updated_at=? WHERE id=?")
          .bind(now, hotelID).run();
      }
      await this.env.HOTELS_DB.prepare(`
        UPDATE hotel_import_jobs
        SET status=?, stage=?, progress=100, stored_images=?, failed_images=?, completed_at=?, updated_at=?, error=?
        WHERE id=?
      `).bind(
        completed ? 'completed' : 'failed',
        completed ? 'completed' : 'incomplete_media',
        stored,
        failed,
        now,
        now,
        completed ? null : `Не удалось сохранить ${failed} из ${total} фотографий. Отель оставлен черновиком.`,
        jobID
      ).run();
      return { completed, stored, failed, total, hotelID };
    });

    return finalState;
  }
}

async function storeRemoteHotelImage(env, hotelID, item, fallbackPosition) {
  const sourceURL = cleanURL(item?.url);
  if (!sourceURL) throw new Error('INVALID_IMAGE_URL');
  const optimizedURL = optimizeProviderImageURL(sourceURL);
  const headers = new Headers({
    'user-agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_6 like Mac OS X) AppleWebKit/605.1.15 Version/17.6 Mobile/15E148 Safari/604.1',
    'accept': 'image/avif,image/webp,image/jpeg,image/png,image/*;q=0.8',
    'accept-language': 'en-US,en;q=0.9'
  });
  if (cleanURL(item?.sourcePageURL)) headers.set('referer', item.sourcePageURL);

  const response = await fetch(optimizedURL, { headers, redirect: 'follow' });
  if (!response.ok) throw new Error(`IMAGE_HTTP_${response.status}`);
  const contentType = (response.headers.get('content-type') || '').split(';')[0].trim().toLowerCase();
  if (!['image/jpeg','image/jpg','image/png','image/webp','image/avif'].includes(contentType)) {
    throw new Error(`UNSUPPORTED_IMAGE_TYPE_${contentType || 'unknown'}`);
  }
  const announced = Number(response.headers.get('content-length') || 0);
  if (announced > 10 * 1024 * 1024) throw new Error('IMAGE_TOO_LARGE');
  const bytes = await response.arrayBuffer();
  if (!bytes.byteLength) throw new Error('EMPTY_IMAGE');
  if (bytes.byteLength > 10 * 1024 * 1024) throw new Error('IMAGE_TOO_LARGE');

  const imageID = crypto.randomUUID();
  const extension = contentType.includes('png') ? 'png' : contentType.includes('webp') ? 'webp' : contentType.includes('avif') ? 'avif' : 'jpg';
  const objectKey = `hotels/${hotelID}/${imageID}.${extension}`;
  const provider = cleanText(item?.provider, 80) || 'unknown';
  const category = validImageCategory(item?.category) || 'gallery';
  const label = cleanText(item?.label, 600);
  const roomName = cleanText(item?.roomName, 260);
  const position = boundedInteger(item?.position, 0, 10000, fallbackPosition);
  const isCover = item?.isCover === true ? 1 : 0;

  await env.HOTELS_MEDIA.put(objectKey, bytes, {
    httpMetadata: { contentType },
    customMetadata: { hotelID, provider, category, roomName: roomName || '', source: 'background-import' }
  });

  try {
    const statements = [];
    if (isCover) statements.push(env.HOTELS_DB.prepare('UPDATE hotel_images SET is_cover=0 WHERE hotel_id=?').bind(hotelID));
    statements.push(env.HOTELS_DB.prepare(`
      INSERT INTO hotel_images (
        id, hotel_id, object_key, source_provider, source_url, category, label, room_name,
        content_type, byte_size, position, is_cover
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    `).bind(imageID, hotelID, objectKey, provider, sourceURL, category, label, roomName, contentType, bytes.byteLength, position, isCover));
    await env.HOTELS_DB.batch(statements);
  } catch (error) {
    await env.HOTELS_MEDIA.delete(objectKey).catch(() => {});
    throw error;
  }

  return { ok: true, imageID, byteSize: bytes.byteLength };
}

function optimizeProviderImageURL(value) {
  try {
    const url = new URL(value);
    const host = url.hostname.toLowerCase();
    if (host.includes('trvl-media.com') || host.includes('expedia')) {
      if (!url.searchParams.has('impolicy')) url.searchParams.set('impolicy', 'resizecrop');
      if (!url.searchParams.has('rw')) url.searchParams.set('rw', '1600');
      if (!url.searchParams.has('ra')) url.searchParams.set('ra', 'fit');
    }
    return url.toString();
  } catch {
    return value;
  }
}

async function deleteAllHotelImagesInternal(env, hotelID) {
  const rows = await env.HOTELS_DB.prepare('SELECT object_key FROM hotel_images WHERE hotel_id=?').bind(hotelID).all();
  await Promise.allSettled((rows.results || []).map(row => env.HOTELS_MEDIA.delete(row.object_key)));
  await env.HOTELS_DB.prepare('DELETE FROM hotel_images WHERE hotel_id=?').bind(hotelID).run();
}

async function hotelTranslation(env, hotelID, rawLocale) {
  const locale = normalizeLocale(rawLocale);
  if (!locale) return json({ ok: false, error: 'UNSUPPORTED_LOCALE' }, 400);
  const hotelResponse = await hotelDataForTranslation(env, hotelID);
  if (!hotelResponse) return json({ ok: false, error: 'HOTEL_NOT_FOUND' }, 404);
  if (locale === 'en') return json({ ok: true, locale, cached: true, translation: hotelResponse }, 200, PUBLIC_CACHE_HEADERS);

  const sourceHash = await sha256Hex(JSON.stringify(hotelResponse));
  const cached = await env.HOTELS_DB.prepare('SELECT source_hash, payload_json FROM hotel_translations WHERE hotel_id=? AND locale=?')
    .bind(hotelID, locale).first();
  if (cached?.source_hash === sourceHash) {
    try {
      return json({ ok: true, locale, cached: true, translation: JSON.parse(cached.payload_json) }, 200, PUBLIC_CACHE_HEADERS);
    } catch {}
  }

  const languageName = locale === 'ru' ? 'Russian' : locale === 'uz-Latn' ? 'Uzbek in Latin script' : 'Uzbek in Cyrillic script';
  const system = `You are a hotel localization engine. Translate all human-readable strings in the supplied JSON into ${languageName}. Preserve JSON keys, IDs, URLs, numbers, measurements, times, brand names, hotel names and place names unless a conventional localized place name is obvious. Never invent missing information. Do not summarize. Return ONLY valid JSON with exactly the same structure.`;
  let answer;
  try {
    const ai = await env.AI.run('@cf/zai-org/glm-4.7-flash', {
      messages: [
        { role: 'system', content: system },
        { role: 'user', content: JSON.stringify(hotelResponse) }
      ],
      max_tokens: 12000,
      temperature: 0.05
    });
    answer = ai?.response ?? ai?.result?.response ?? ai?.choices?.[0]?.message?.content;
  } catch (error) {
    console.error('HOTEL_TRANSLATION_AI_FAILED', error);
    return json({ ok: false, error: 'TRANSLATION_UNAVAILABLE' }, 503);
  }

  const translated = parseJSONEnvelope(answer);
  if (!translated || typeof translated !== 'object') return json({ ok: false, error: 'TRANSLATION_INVALID' }, 502);
  const now = new Date().toISOString();
  await env.HOTELS_DB.prepare(`
    INSERT INTO hotel_translations (hotel_id, locale, source_hash, payload_json, created_at, updated_at)
    VALUES (?, ?, ?, ?, ?, ?)
    ON CONFLICT(hotel_id, locale) DO UPDATE SET source_hash=excluded.source_hash, payload_json=excluded.payload_json, updated_at=excluded.updated_at
  `).bind(hotelID, locale, sourceHash, JSON.stringify(translated), now, now).run();
  return json({ ok: true, locale, cached: false, translation: translated }, 200, PUBLIC_CACHE_HEADERS);
}

async function hotelDataForTranslation(env, hotelID) {
  const hotel = await env.HOTELS_DB.prepare("SELECT * FROM hotels WHERE id=? AND status='published'").bind(hotelID).first();
  if (!hotel) return null;
  const [amenities, rooms] = await Promise.all([
    env.HOTELS_DB.prepare('SELECT amenity FROM hotel_amenities WHERE hotel_id=? ORDER BY position').bind(hotelID).all(),
    env.HOTELS_DB.prepare('SELECT id,name,max_guests,size_m2,beds,view,description,amenities_json FROM hotel_rooms WHERE hotel_id=? ORDER BY position').bind(hotelID).all()
  ]);
  return {
    name: hotel.name,
    city: hotel.city,
    country: hotel.country,
    propertyType: hotel.property_type || null,
    address: hotel.address || '',
    description: hotel.description || '',
    checkIn: hotel.check_in || null,
    checkOut: hotel.check_out || null,
    amenities: (amenities.results || []).map(x => x.amenity),
    policies: parseJSONArray(hotel.policies_json),
    nearby: parseJSONArray(hotel.nearby_json),
    facts: parseJSONArray(hotel.facts_json),
    fees: parseJSONArray(hotel.fees_json),
    services: parseJSONArray(hotel.services_json),
    rooms: (rooms.results || []).map(row => ({
      id: row.id,
      name: row.name,
      maxGuests: row.max_guests == null ? null : Number(row.max_guests),
      sizeM2: row.size_m2 == null ? null : Number(row.size_m2),
      beds: row.beds || null,
      view: row.view || null,
      description: row.description || null,
      amenities: parseJSONArray(row.amenities_json)
    }))
  };
}

function normalizeLocale(value) {
  const raw = String(value || '').trim().replace('_', '-').toLowerCase();
  if (raw === 'en' || raw.startsWith('en-')) return 'en';
  if (raw === 'ru' || raw.startsWith('ru-')) return 'ru';
  if (['uz','uz-latn','uz-latin'].includes(raw)) return 'uz-Latn';
  if (['uz-cyrl','uz-cyrillic','uz-uz-cyrl'].includes(raw)) return 'uz-Cyrl';
  return null;
}

async function sha256Hex(value) {
  const bytes = new TextEncoder().encode(value);
  const digest = await crypto.subtle.digest('SHA-256', bytes);
  return [...new Uint8Array(digest)].map(x => x.toString(16).padStart(2, '0')).join('');
}

function parseJSONEnvelope(value) {
  if (typeof value !== 'string') return value;
  const trimmed = value.trim().replace(/^```(?:json)?\s*/i, '').replace(/\s*```$/, '');
  try { return JSON.parse(trimmed); } catch {}
  const start = Math.min(...['{','['].map(ch => trimmed.indexOf(ch)).filter(i => i >= 0));
  const end = Math.max(trimmed.lastIndexOf('}'), trimmed.lastIndexOf(']'));
  if (Number.isFinite(start) && start >= 0 && end > start) {
    try { return JSON.parse(trimmed.slice(start, end + 1)); } catch {}
  }
  return null;
}

async function deleteAllHotelImages(env, hotelID) {
  const hotel = await env.HOTELS_DB.prepare('SELECT id FROM hotels WHERE id = ?').bind(hotelID).first();
  if (!hotel) return json({ ok: false, error: 'HOTEL_NOT_FOUND' }, 404);

  const rows = await env.HOTELS_DB.prepare(
    'SELECT object_key FROM hotel_images WHERE hotel_id = ?'
  ).bind(hotelID).all();

  await Promise.allSettled((rows.results || []).map(row => env.HOTELS_MEDIA.delete(row.object_key)));
  await env.HOTELS_DB.batch([
    env.HOTELS_DB.prepare('DELETE FROM hotel_images WHERE hotel_id = ?').bind(hotelID),
    env.HOTELS_DB.prepare("UPDATE hotels SET updated_at = strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id = ?").bind(hotelID)
  ]);

  return json({ ok: true, deleted: (rows.results || []).length }, 200);
}

async function uploadHotelImage(request, env, hotelID) {
  const hotel = await env.HOTELS_DB.prepare('SELECT id, status FROM hotels WHERE id = ?').bind(hotelID).first();
  if (!hotel) return json({ ok: false, error: 'HOTEL_NOT_FOUND' }, 404);

  const contentType = (request.headers.get('content-type') || '').split(';')[0].trim().toLowerCase();
  if (!['image/jpeg', 'image/jpg', 'image/png', 'image/webp'].includes(contentType)) {
    return json({ ok: false, error: 'UNSUPPORTED_IMAGE_TYPE' }, 415);
  }

  const bytes = await request.arrayBuffer();
  if (!bytes.byteLength) return json({ ok: false, error: 'EMPTY_IMAGE' }, 400);
  if (bytes.byteLength > 8 * 1024 * 1024) return json({ ok: false, error: 'IMAGE_TOO_LARGE' }, 413);

  const imageID = crypto.randomUUID();
  const extension = contentType.includes('png') ? 'png' : contentType.includes('webp') ? 'webp' : 'jpg';
  const objectKey = `hotels/${hotelID}/${imageID}.${extension}`;
  const provider = cleanText(request.headers.get('x-iumrah-source'), 80);
  const rawCategory = cleanText(request.headers.get('x-iumrah-category'), 30) || 'other';
  const category = ['exterior', 'room', 'bathroom', 'lobby', 'restaurant', 'amenity', 'view', 'gallery', 'other'].includes(rawCategory) ? rawCategory : 'gallery';
  const sourceURL = cleanURL(request.headers.get('x-iumrah-source-url'));
  const label = cleanText(request.headers.get('x-iumrah-label'), 600);
  const roomName = cleanText(request.headers.get('x-iumrah-room'), 260);
  const position = boundedInteger(request.headers.get('x-iumrah-position'), 0, 10000, 0);
  const isCover = request.headers.get('x-iumrah-cover') === '1' ? 1 : 0;

  await env.HOTELS_MEDIA.put(objectKey, bytes, {
    httpMetadata: { contentType },
    customMetadata: {
      hotelID,
      provider: provider || 'unknown',
      category,
      roomName: roomName || ''
    }
  });

  const statements = [];
  if (isCover) {
    statements.push(
      env.HOTELS_DB.prepare('UPDATE hotel_images SET is_cover = 0 WHERE hotel_id = ?').bind(hotelID)
    );
  }
  statements.push(
    env.HOTELS_DB.prepare(`
      INSERT INTO hotel_images (
        id, hotel_id, object_key, source_provider, source_url, category, label, room_name, content_type,
        byte_size, position, is_cover
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    `).bind(imageID, hotelID, objectKey, provider, sourceURL, category, label, roomName, contentType, bytes.byteLength, position, isCover)
  );
  statements.push(
    env.HOTELS_DB.prepare("UPDATE hotels SET updated_at = strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id = ?").bind(hotelID)
  );

  try {
    await env.HOTELS_DB.batch(statements);
  } catch (error) {
    await env.HOTELS_MEDIA.delete(objectKey).catch(() => {});
    throw error;
  }

  return json({
    ok: true,
    image: {
      id: imageID,
      url: publicImagePath(hotelID, imageID),
      position,
      isCover: isCover === 1,
      category,
      roomName: roomName || ''
    }
  }, 201);
}

async function serveHotelImage(env, hotelID, imageID, admin) {
  const row = await env.HOTELS_DB.prepare(`
    SELECT hi.object_key, hi.content_type, h.status
    FROM hotel_images hi
    JOIN hotels h ON h.id = hi.hotel_id
    WHERE hi.hotel_id = ? AND hi.id = ?
  `).bind(hotelID, imageID).first();

  if (!row) return new Response('Not Found', { status: 404 });
  if (!admin && row.status !== 'published') return new Response('Not Found', { status: 404 });

  const object = await env.HOTELS_MEDIA.get(row.object_key);
  if (!object) return new Response('Not Found', { status: 404 });

  const headers = new Headers();
  object.writeHttpMetadata(headers);
  headers.set('content-type', row.content_type || headers.get('content-type') || 'image/jpeg');
  headers.set('cache-control', admin ? 'private, max-age=60' : 'public, max-age=86400, s-maxage=604800');
  if (object.httpEtag) headers.set('etag', object.httpEtag);
  return new Response(object.body, { headers });
}

async function deleteHotel(env, hotelID) {
  const images = await env.HOTELS_DB.prepare('SELECT object_key FROM hotel_images WHERE hotel_id = ?').bind(hotelID).all();
  const result = await env.HOTELS_DB.prepare('DELETE FROM hotels WHERE id = ?').bind(hotelID).run();

  if (!result.meta?.changes) return json({ ok: false, error: 'HOTEL_NOT_FOUND' }, 404);

  await Promise.allSettled((images.results || []).map(row => env.HOTELS_MEDIA.delete(row.object_key)));
  return json({ ok: true });
}

async function summaryRow(env, hotelID) {
  return env.HOTELS_DB.prepare(`
    SELECT
      h.id,
      h.name,
      h.city,
      h.stars,
      h.rating,
      h.review_count,
      h.status,
      h.updated_at,
      (SELECT COUNT(*) FROM hotel_images hi WHERE hi.hotel_id = h.id) AS image_count,
      (SELECT COUNT(*) FROM hotel_rooms hr WHERE hr.hotel_id = h.id) AS room_count,
      (
        SELECT hi.id FROM hotel_images hi
        WHERE hi.hotel_id = h.id
        ORDER BY hi.is_cover DESC, hi.position ASC, hi.created_at ASC
        LIMIT 1
      ) AS cover_image_id
    FROM hotels h
    WHERE h.id = ?
  `).bind(hotelID).first();
}

function hotelSummary(row) {
  if (!row) return null;
  return {
    id: row.id,
    name: row.name,
    city: row.city,
    stars: row.stars == null ? null : Number(row.stars),
    rating: row.rating == null ? null : Number(row.rating),
    reviewCount: row.review_count == null ? null : Number(row.review_count),
    status: row.status,
    coverImageURL: row.cover_image_id ? publicImagePath(row.id, row.cover_image_id) : null,
    imageCount: Number(row.image_count || 0),
    roomCount: Number(row.room_count || 0),
    updatedAt: row.updated_at
  };
}

function sourceRow(row) {
  return {
    id: row.id,
    provider: row.provider,
    sourceURL: row.source_url,
    name: row.source_name,
    city: row.city,
    country: row.country,
    propertyType: row.property_type,
    address: row.address,
    description: row.description,
    stars: row.stars == null ? null : Number(row.stars),
    rating: row.rating == null ? null : Number(row.rating),
    ratingScale: row.rating_scale == null ? null : Number(row.rating_scale),
    reviewCount: row.review_count == null ? null : Number(row.review_count),
    latitude: row.latitude == null ? null : Number(row.latitude),
    longitude: row.longitude == null ? null : Number(row.longitude),
    checkIn: row.check_in,
    checkOut: row.check_out,
    images: parseJSONArray(row.images_json),
    amenities: parseJSONArray(row.amenities_json),
    roomNames: parseJSONArray(row.room_names_json),
    rooms: parseJSONArray(row.room_details_json),
    policies: parseJSONArray(row.policies_json),
    providerHotelID: row.provider_hotel_id || null,
    canonicalURL: row.canonical_url || null,
    googleMapsURL: row.google_maps_url || null,
    nearby: parseJSONArray(row.nearby_json),
    facts: parseJSONArray(row.facts_json),
    fees: parseJSONArray(row.fees_json),
    services: parseJSONArray(row.services_json),
    checkedAt: row.checked_at
  };
}

async function uniqueSlug(env, hotelID, seed) {
  const base = slugify(seed) || `hotel-${hotelID.toLowerCase()}`;
  let candidate = base;
  for (let index = 0; index < 20; index += 1) {
    const row = await env.HOTELS_DB.prepare('SELECT id FROM hotels WHERE slug = ? AND id != ? LIMIT 1').bind(candidate, hotelID).first();
    if (!row) return candidate;
    candidate = `${base}-${index + 2}`;
  }
  return `${base}-${crypto.randomUUID().slice(0, 8)}`;
}

function publicImagePath(hotelID, imageID) {
  return `/api/catalog/hotels/${encodeURIComponent(hotelID)}/images/${encodeURIComponent(imageID)}`;
}

function pathParts(pathname, prefix) {
  const suffix = pathname.slice(prefix.length).replace(/^\/+|\/+$/g, '');
  return suffix ? suffix.split('/').map(decodeURIComponent) : [];
}

function safeID(value) {
  const text = String(value || '').trim();
  return /^[A-Za-z0-9._:-]{1,128}$/.test(text) ? text : null;
}

function cleanText(value, maxLength = 1000) {
  if (value == null) return null;
  const text = String(value).replace(/\u0000/g, '').trim();
  if (!text) return null;
  return text.slice(0, maxLength);
}

function canonicalCity(value) {
  const text = String(value || '').trim().toLowerCase();
  if (['makkah', 'mecca', 'makkah al mukarramah'].includes(text)) return 'Makkah';
  if (['madinah', 'medina', 'al madinah'].includes(text)) return 'Madinah';
  return cleanText(value, 80);
}

function cleanURL(value) {
  try {
    const url = new URL(String(value || ''));
    if (!['http:', 'https:'].includes(url.protocol)) return null;
    return url.toString().slice(0, 3000);
  } catch {
    return null;
  }
}

function nullableInteger(value, min, max) {
  if (value == null || value === '') return null;
  const number = Number(value);
  if (!Number.isFinite(number)) return null;
  const integer = Math.trunc(number);
  return integer >= min && integer <= max ? integer : null;
}

function boundedInteger(value, min, max, fallback) {
  const parsed = nullableInteger(value, min, max);
  return parsed == null ? fallback : parsed;
}

function nullableNumber(value, min, max) {
  if (value == null || value === '') return null;
  const number = Number(value);
  if (!Number.isFinite(number) || number < min || number > max) return null;
  return number;
}

function uniqueStrings(value, maxItems, maxLength) {
  if (!Array.isArray(value)) return [];
  const result = [];
  const seen = new Set();
  for (const item of value) {
    const text = cleanText(item, maxLength);
    if (!text) continue;
    const key = text.toLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    result.push(text);
    if (result.length >= maxItems) break;
  }
  return result;
}


function safeObjectArray(value, maxItems = 120, maxBytes = 30_000) {
  if (!Array.isArray(value)) return [];
  const result = [];
  const seen = new Set();
  let used = 2;
  for (const item of value) {
    if (!item || typeof item !== 'object' || Array.isArray(item)) continue;
    const clean = {};
    for (const [key, raw] of Object.entries(item)) {
      const safeKey = String(key).replace(/[^A-Za-z0-9_-]/g, '').slice(0, 64);
      if (!safeKey) continue;
      if (typeof raw === 'string') clean[safeKey] = cleanText(raw, 1200);
      else if (typeof raw === 'number' && Number.isFinite(raw)) clean[safeKey] = raw;
      else if (typeof raw === 'boolean') clean[safeKey] = raw;
      else if (raw == null) clean[safeKey] = null;
    }
    const encoded = JSON.stringify(clean);
    if (encoded === '{}' || used + encoded.length > maxBytes) continue;
    const signature = encoded.toLowerCase();
    if (seen.has(signature)) continue;
    seen.add(signature);
    result.push(clean);
    used += encoded.length + 1;
    if (result.length >= maxItems) break;
  }
  return result;
}

function validImageCategory(value) {
  const category = cleanText(typeof value === 'string' ? value : value?.rawValue, 30);
  return ['exterior','room','bathroom','lobby','restaurant','amenity','view','gallery','other'].includes(category) ? category : null;
}

function isPlausibleRoomName(value) {
  const text = cleanText(value, 260);
  if (!text || text.length < 4 || text.length > 240) return false;
  const lower = text.toLowerCase();
  const roomToken = /(room|suite|studio|apartment|villa|king|queen|twin|double|triple|quad|family|deluxe|superior|classic|standard|executive|premier|номер|люкс|комнат|غرفة|جناح)/i;
  const blocked = /(how much|parking|breakfast|restaurant|front desk|reception|concierge|room service|meeting room|prayer room|laundry room|locker room|non-smoking rooms|family rooms|guest rooms|choose your room|select room|room amenities|frequently asked|question|answer|policy|check[- ]?in|check[- ]?out)/i;
  if (!roomToken.test(text) || blocked.test(text)) return false;
  if (/[?؟]$/.test(text)) return false;
  const words = lower.split(/\s+/).filter(Boolean);
  if (words.length > 24) return false;
  return true;
}

function canonicalSourceURL(value) {
  try {
    const url = new URL(String(value || ''));
    url.hash = '';
    const keep = new Set(['hotelid','hotel_id','propertyid','property_id','id']);
    for (const key of [...url.searchParams.keys()]) {
      if (!keep.has(key.toLowerCase())) url.searchParams.delete(key);
    }
    url.hostname = url.hostname.toLowerCase().replace(/^www\./, '');
    url.pathname = url.pathname.replace(/\/+$/, '') || '/';
    return url.toString().slice(0, 3000);
  } catch {
    return null;
  }
}

function canonicalHotelKey(name, city, address, latitude, longitude) {
  const namePart = [...hotelNameTokens(name)].sort().join('-');
  const cityPart = slugify(canonicalCity(city) || city || '');
  let locationPart = '';
  const lat = nullableNumber(latitude, -90, 90);
  const lng = nullableNumber(longitude, -180, 180);
  if (lat != null && lng != null) locationPart = `${lat.toFixed(3)}:${lng.toFixed(3)}`;
  else locationPart = [...addressTokens(normalizedAddress(address))].slice(0, 8).join('-');
  return cleanText(`${cityPart}|${namePart}|${locationPart}`, 600);
}

function normalizedAddress(value) {
  return String(value || '')
    .normalize('NFKD')
    .replace(/[\u0300-\u036f]/g, '')
    .toLowerCase()
    .replace(/\b(saudi arabia|kingdom of saudi arabia|ksa)\b/g, ' ')
    .replace(/[^a-z0-9\u0600-\u06ff]+/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

function hotelNameTokens(value) {
  const stop = new Set(['hotel','hotels','resort','resorts','by','the','makkah','mecca','madinah','medina','saudi','arabia','ksa','فندق']);
  const text = String(value || '')
    .normalize('NFKD')
    .replace(/[\u0300-\u036f]/g, '')
    .toLowerCase()
    .replace(/&/g, ' and ')
    .replace(/[^a-z0-9\u0600-\u06ff]+/g, ' ');
  return new Set(text.split(/\s+/).filter(token => token.length > 1 && !stop.has(token)));
}

function addressTokens(value) {
  const stop = new Set(['street','st','road','rd','district','area','saudi','arabia','makkah','mecca','madinah','medina']);
  return new Set(String(value || '').split(/\s+/).filter(token => token.length > 1 && !stop.has(token)));
}

function tokenSimilarity(a, b) {
  if (!(a instanceof Set) || !(b instanceof Set) || !a.size || !b.size) return 0;
  let overlap = 0;
  for (const token of a) if (b.has(token)) overlap += 1;
  return overlap / Math.max(a.size, b.size);
}

function haversineMeters(lat1, lon1, lat2, lon2) {
  const toRad = deg => deg * Math.PI / 180;
  const R = 6371000;
  const dLat = toRad(lat2 - lat1);
  const dLon = toRad(lon2 - lon1);
  const a = Math.sin(dLat / 2) ** 2 + Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLon / 2) ** 2;
  return R * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

function googleMapsURL(latitude, longitude, address) {
  const lat = nullableNumber(latitude, -90, 90);
  const lng = nullableNumber(longitude, -180, 180);
  const query = lat != null && lng != null ? `${lat},${lng}` : cleanText(address, 900);
  return query ? `https://www.google.com/maps/search/?api=1&query=${encodeURIComponent(query)}` : null;
}

function slugify(value) {
  return String(value || '')
    .normalize('NFKD')
    .replace(/[\u0300-\u036f]/g, '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 140);
}

function parseJSONArray(value) {
  try {
    const parsed = JSON.parse(value || '[]');
    return Array.isArray(parsed) ? parsed : [];
  } catch {
    return [];
  }
}

async function readJSON(request, maxBytes) {
  const contentLength = Number(request.headers.get('content-length') || 0);
  if (contentLength > maxBytes) {
    return { ok: false, response: json({ ok: false, error: 'PAYLOAD_TOO_LARGE' }, 413) };
  }

  let text;
  try {
    text = await request.text();
  } catch {
    return { ok: false, response: json({ ok: false, error: 'INVALID_BODY' }, 400) };
  }

  if (new TextEncoder().encode(text).byteLength > maxBytes) {
    return { ok: false, response: json({ ok: false, error: 'PAYLOAD_TOO_LARGE' }, 413) };
  }

  try {
    return { ok: true, value: JSON.parse(text) };
  } catch {
    return { ok: false, response: json({ ok: false, error: 'INVALID_JSON' }, 400) };
  }
}

function methodNotAllowed() {
  return json({ ok: false, error: 'METHOD_NOT_ALLOWED' }, 405);
}

function json(value, status = 200, extraHeaders) {
  const headers = new Headers(JSON_HEADERS);
  if (extraHeaders) {
    Object.entries(extraHeaders).forEach(([key, value]) => headers.set(key, value));
  }
  return new Response(JSON.stringify(value), { status, headers });
}

function corsHeaders(request) {
  const origin = request.headers.get('origin') || '';
  const allowed = origin === 'https://iumrah.app' || origin === 'https://www.iumrah.app';
  return {
    'access-control-allow-origin': allowed ? origin : 'https://iumrah.app',
    'access-control-allow-credentials': 'true',
    'access-control-allow-methods': 'GET,POST,DELETE,OPTIONS',
    'access-control-allow-headers': 'Content-Type,X-Iumrah-Source,X-Iumrah-Position,X-Iumrah-Cover',
    'vary': 'Origin'
  };
}

function withCors(response, request) {
  const headers = new Headers(response.headers);
  Object.entries(corsHeaders(request)).forEach(([key, value]) => headers.set(key, value));
  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers
  });
}
