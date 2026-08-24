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

  if (parts[0] === 'source-rooms') {
    if (parts.length !== 1 || request.method !== 'POST') return methodNotAllowed();
    return recoverSourceRooms(request, env);
  }

  if (parts[0] === 'import-jobs') {
    if (parts.length === 1 && request.method === 'GET') return listImportJobs(env, url);
    if (parts.length === 1 && request.method === 'POST') return createImportJob(request, env, user);
    const jobID = safeID(parts[1]);
    if (!jobID) return json({ ok: false, error: 'INVALID_JOB_ID' }, 400);
    if (parts.length === 2 && request.method === 'GET') return importJobDetail(env, jobID);
    if (parts.length === 2 && request.method === 'DELETE') return deleteImportJob(env, jobID);
    if (parts.length === 3 && parts[2] === 'retry' && request.method === 'POST') return retryImportJob(env, jobID);
    if (parts.length === 3 && parts[2] === 'cancel' && request.method === 'POST') return cancelImportJob(env, jobID);
    return methodNotAllowed();
  }

  if (parts[0] === 'chats') {
    return handleBusinessChats(request, env, parts.slice(1), user);
  }

  if (parts[0] === 'push') {
    return handleBusinessPush(request, env, parts.slice(1), user);
  }

  const hotelID = safeID(parts[0]);
  if (!hotelID) return json({ ok: false, error: 'INVALID_HOTEL_ID' }, 400);

  if (parts.length === 1) {
    if (request.method === 'GET') return hotelDetail(env, hotelID, true, url);
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


async function handleBusinessChats(request, env, parts, user) {
  if (parts.length === 0 && request.method === 'GET') return listBusinessChatThreads(env);
  const bookingID = safeID(parts[0]);
  if (!bookingID) return json({ ok: false, error: 'INVALID_BOOKING_ID' }, 400);
  if (parts.length === 1 && request.method === 'GET') return chatMessages(env, bookingID);
  if (parts.length === 2 && parts[1] === 'messages') {
    if (request.method === 'GET') return chatMessages(env, bookingID);
    if (request.method === 'POST') return sendChatMessage(request, env, bookingID, user);
  }
  if (parts.length === 2 && parts[1] === 'read' && request.method === 'POST') {
    await env.HOTELS_DB.batch([
      env.HOTELS_DB.prepare('UPDATE business_chat_messages SET read_by_staff=1 WHERE booking_id=?').bind(bookingID),
      env.HOTELS_DB.prepare('UPDATE business_chat_threads SET unread_for_staff=0, updated_at=? WHERE booking_id=?').bind(new Date().toISOString(), bookingID)
    ]);
    return json({ ok: true });
  }
  return methodNotAllowed();
}

async function listBusinessChatThreads(env) {
  const result = await env.HOTELS_DB.prepare(`
    SELECT booking_id, last_message_at, last_message_preview, last_sender_type, unread_for_staff, updated_at
    FROM business_chat_threads
    ORDER BY COALESCE(last_message_at, updated_at) DESC
    LIMIT 300
  `).all();
  return json({
    ok: true,
    threads: (result.results || []).map(row => ({
      bookingID: row.booking_id,
      lastMessageAt: row.last_message_at || row.updated_at,
      lastMessagePreview: row.last_message_preview || '',
      lastSenderType: row.last_sender_type || null,
      unreadForStaff: Number(row.unread_for_staff || 0) === 1
    }))
  });
}

async function chatMessages(env, bookingID) {
  const result = await env.HOTELS_DB.prepare(`
    SELECT id, booking_id, sender_type, sender_name, body, created_at, read_by_staff
    FROM business_chat_messages WHERE booking_id=? ORDER BY created_at ASC LIMIT 500
  `).bind(bookingID).all();
  return json({
    ok: true,
    bookingID,
    messages: (result.results || []).map(row => ({
      id: row.id,
      bookingID: row.booking_id,
      senderType: row.sender_type,
      senderName: row.sender_name || null,
      body: row.body,
      createdAt: row.created_at,
      readByStaff: Number(row.read_by_staff || 0) === 1
    }))
  });
}

async function sendChatMessage(request, env, bookingID, user) {
  const payload = await request.json().catch(() => null);
  const body = safeHumanText(payload?.body, 4000);
  if (!body) return json({ ok: false, error: 'EMPTY_MESSAGE' }, 400);
  const clientMessageID = safeID(payload?.clientMessageID) || null;
  if (clientMessageID) {
    const existing = await env.HOTELS_DB.prepare('SELECT id FROM business_chat_messages WHERE booking_id=? AND client_message_id=? LIMIT 1')
      .bind(bookingID, clientMessageID).first();
    if (existing?.id) return chatMessageDetail(env, existing.id, 200);
  }
  const id = crypto.randomUUID();
  const now = new Date().toISOString();
  const senderName = safeHumanText(user?.displayName || user?.login || 'iumrah Business', 160) || 'iumrah Business';
  await env.HOTELS_DB.batch([
    env.HOTELS_DB.prepare(`
      INSERT INTO business_chat_threads (booking_id, created_at, updated_at, last_message_at, last_message_preview, last_sender_type, unread_for_staff)
      VALUES (?, ?, ?, ?, ?, 'staff', 0)
      ON CONFLICT(booking_id) DO UPDATE SET updated_at=excluded.updated_at, last_message_at=excluded.last_message_at,
        last_message_preview=excluded.last_message_preview, last_sender_type='staff', unread_for_staff=0
    `).bind(bookingID, now, now, now, body.slice(0, 240)),
    env.HOTELS_DB.prepare(`
      INSERT INTO business_chat_messages (id, booking_id, sender_type, sender_name, body, created_at, read_by_staff, client_message_id)
      VALUES (?, ?, 'staff', ?, ?, ?, 1, ?)
    `).bind(id, bookingID, senderName, body, now, clientMessageID)
  ]);
  return chatMessageDetail(env, id, 201);
}

async function chatMessageDetail(env, id, status = 200) {
  const row = await env.HOTELS_DB.prepare('SELECT * FROM business_chat_messages WHERE id=?').bind(id).first();
  if (!row) return json({ ok: false, error: 'MESSAGE_NOT_FOUND' }, 404);
  return json({ ok: true, message: {
    id: row.id,
    bookingID: row.booking_id,
    senderType: row.sender_type,
    senderName: row.sender_name || null,
    body: row.body,
    createdAt: row.created_at,
    readByStaff: Number(row.read_by_staff || 0) === 1
  }}, status);
}

async function handleBusinessPush(request, env, parts, user) {
  if (parts.length === 1 && parts[0] === 'devices' && request.method === 'POST') {
    const payload = await request.json().catch(() => null);
    const token = cleanText(payload?.deviceToken, 256)?.toLowerCase();
    if (!token || !/^[0-9a-f]{32,256}$/.test(token)) return json({ ok: false, error: 'INVALID_DEVICE_TOKEN' }, 400);
    const environment = payload?.environment === 'development' ? 'development' : 'production';
    const now = new Date().toISOString();
    await env.HOTELS_DB.prepare(`
      INSERT INTO business_push_devices (device_token, staff_login, environment, app_bundle_id, enabled, created_at, updated_at, last_error)
      VALUES (?, ?, ?, 'com.iumrah.business', 1, ?, ?, NULL)
      ON CONFLICT(device_token) DO UPDATE SET staff_login=excluded.staff_login, environment=excluded.environment,
        app_bundle_id=excluded.app_bundle_id, enabled=1, updated_at=excluded.updated_at, last_error=NULL
    `).bind(token, cleanText(user?.login, 180), environment, now, now).run();
    return json({ ok: true, ready: apnsConfigured(env) });
  }
  if (parts.length === 1 && parts[0] === 'status' && request.method === 'GET') {
    const row = await env.HOTELS_DB.prepare('SELECT COUNT(*) AS count FROM business_push_devices WHERE enabled=1').first();
    return json({ ok: true, configured: apnsConfigured(env), devices: Number(row?.count || 0) });
  }
  return methodNotAllowed();
}

function apnsConfigured(env) {
  return !!(env.APNS_PRIVATE_KEY && env.APNS_KEY_ID && env.APPLE_TEAM_ID);
}

async function sendStaffPush(env, title, body, data = {}) {
  if (!apnsConfigured(env)) return { ok: false, skipped: 'APNS_NOT_CONFIGURED' };
  const devices = await env.HOTELS_DB.prepare('SELECT device_token, environment FROM business_push_devices WHERE enabled=1 LIMIT 100').all();
  const rows = devices.results || [];
  if (!rows.length) return { ok: false, skipped: 'NO_DEVICES' };
  const jwt = await apnsJWT(env);
  let sent = 0;
  for (const device of rows) {
    const base = device.environment === 'development' ? 'https://api.sandbox.push.apple.com' : 'https://api.push.apple.com';
    const response = await fetch(`${base}/3/device/${device.device_token}`, {
      method: 'POST',
      headers: {
        authorization: `bearer ${jwt}`,
        'apns-topic': 'com.iumrah.business',
        'apns-push-type': 'alert',
        'apns-priority': '10',
        'content-type': 'application/json'
      },
      body: JSON.stringify({ aps: { alert: { title, body }, sound: 'default' }, ...data })
    }).catch(() => null);
    if (response?.ok) {
      sent += 1;
      await env.HOTELS_DB.prepare('UPDATE business_push_devices SET last_success_at=?, last_error=NULL, updated_at=? WHERE device_token=?')
        .bind(new Date().toISOString(), new Date().toISOString(), device.device_token).run().catch(() => {});
    } else if (response) {
      const text = await response.text().catch(() => '');
      const disable = response.status === 410 || /BadDeviceToken|Unregistered/i.test(text);
      await env.HOTELS_DB.prepare('UPDATE business_push_devices SET enabled=?, last_error=?, updated_at=? WHERE device_token=?')
        .bind(disable ? 0 : 1, `${response.status}:${text}`.slice(0, 900), new Date().toISOString(), device.device_token).run().catch(() => {});
    }
  }
  return { ok: sent > 0, sent, total: rows.length };
}

let cachedAPNSJWT = null;
let cachedAPNSJWTAt = 0;
async function apnsJWT(env) {
  const nowSeconds = Math.floor(Date.now() / 1000);
  if (cachedAPNSJWT && nowSeconds - cachedAPNSJWTAt < 45 * 60) return cachedAPNSJWT;
  const header = base64urlJSON({ alg: 'ES256', kid: env.APNS_KEY_ID });
  const payload = base64urlJSON({ iss: env.APPLE_TEAM_ID, iat: nowSeconds });
  const signingInput = `${header}.${payload}`;
  const key = await crypto.subtle.importKey('pkcs8', pemToArrayBuffer(env.APNS_PRIVATE_KEY), { name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign']);
  const signature = await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, key, new TextEncoder().encode(signingInput));
  cachedAPNSJWT = `${signingInput}.${base64urlBytes(new Uint8Array(signature))}`;
  cachedAPNSJWTAt = nowSeconds;
  return cachedAPNSJWT;
}

function pemToArrayBuffer(pem) {
  const base64 = String(pem || '').replace(/-----BEGIN PRIVATE KEY-----|-----END PRIVATE KEY-----|\s+/g, '');
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i);
  return bytes.buffer;
}

function base64urlJSON(value) {
  return base64urlBytes(new TextEncoder().encode(JSON.stringify(value)));
}

function base64urlBytes(bytes) {
  let binary = '';
  for (let i = 0; i < bytes.length; i += 1) binary += String.fromCharCode(bytes[i]);
  return btoa(binary).replace(/=/g, '').replace(/\+/g, '-').replace(/\//g, '_');
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
    return hotelDetail(env, hotelID, false, url);
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
      h.lifecycle_state,
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

async function hotelDetail(env, hotelID, admin, url = null) {
  const hotel = await env.HOTELS_DB.prepare(
    `SELECT * FROM hotels WHERE id = ? ${admin ? '' : "AND status = 'published'"}`
  ).bind(hotelID).first();

  if (!hotel) return json({ ok: false, error: 'HOTEL_NOT_FOUND' }, 404);

  const [amenitiesResult, roomsResult, imagesResult, sourcesResult] = await Promise.all([
    env.HOTELS_DB.prepare('SELECT amenity FROM hotel_amenities WHERE hotel_id = ? ORDER BY position ASC, amenity ASC').bind(hotelID).all(),
    env.HOTELS_DB.prepare('SELECT id, name, max_guests, size_m2, beds, view, description, amenities_json, smoking, accessibility_json, category, bathroom_json FROM hotel_rooms WHERE hotel_id = ? ORDER BY position ASC, name ASC').bind(hotelID).all(),
    env.HOTELS_DB.prepare('SELECT id, source_provider, category, label, room_name, position, is_cover, width, height, byte_size, original_byte_size, content_type, transform_version FROM hotel_images WHERE hotel_id = ? ORDER BY is_cover DESC, position ASC, created_at ASC').bind(hotelID).all(),
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
    width: row.width == null ? null : Number(row.width),
    height: row.height == null ? null : Number(row.height),
    byteSize: Number(row.byte_size || 0),
    originalByteSize: Number(row.original_byte_size || 0),
    contentType: row.content_type || 'image/webp',
    transformVersion: row.transform_version || null,
    url: publicImagePath(hotelID, row.id)
  }));

  const detail = {
    id: hotel.id,
    name: hotel.name,
    city: hotel.city,
    country: hotel.country,
    propertyType: hotel.property_type || null,
    brand: hotel.brand || null,
    chain: hotel.chain_name || null,
    postalCode: hotel.postal_code || null,
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
    highlights: parseJSONArray(hotel.highlights_json),
    importantInformation: parseJSONArray(hotel.important_information_json),
    food: parseJSONArray(hotel.food_json),
    parkingTransport: parseJSONArray(hotel.parking_transport_json),
    accessibility: parseJSONArray(hotel.accessibility_json),
    googleMapsURL: hotel.google_maps_url || googleMapsURL(hotel.latitude, hotel.longitude, hotel.address),
    canonicalKey: hotel.canonical_key || null,
    status: hotel.status,
    lifecycleState: hotel.lifecycle_state || hotel.status,
    dataQuality: parseJSONObject(hotel.data_quality_json),
    lastVerifiedAt: hotel.last_verified_at || null,
    amenities: (amenitiesResult.results || []).map(row => row.amenity),
    rooms: (roomsResult.results || []).map(row => ({
      id: row.id,
      name: row.name,
      maxGuests: row.max_guests == null ? null : Number(row.max_guests),
      sizeM2: row.size_m2 == null ? null : Number(row.size_m2),
      beds: row.beds,
      view: row.view,
      description: row.description || null,
      amenities: parseJSONArray(row.amenities_json),
      smoking: row.smoking || null,
      accessibility: parseJSONArray(row.accessibility_json),
      category: row.category || null,
      bathroom: parseJSONArray(row.bathroom_json)
    })),
    images,
    sources: admin ? (sourcesResult.results || []).map(sourceRow) : [],
    createdAt: hotel.created_at,
    updatedAt: hotel.updated_at
  };

  if (!admin && url) {
    const requestedLocale = normalizeLocale(url.searchParams.get('locale') || 'en');
    if (requestedLocale && requestedLocale !== 'en') {
      try {
        const source = await hotelDataForTranslation(env, hotelID);
        if (source) {
          const translated = await getOrCreateHotelTranslation(env, hotelID, requestedLocale, source);
          applyHotelTranslation(detail, translated.translation);
          detail.locale = requestedLocale;
          detail.translationStatus = translated.cached ? 'cached' : 'generated';
        }
      } catch (error) {
        console.error('HOTEL_DETAIL_TRANSLATION_FAILED', { hotelID, locale: requestedLocale, error: String(error?.message || error) });
        detail.locale = 'en';
        detail.translationStatus = 'fallback';
      }
    } else {
      detail.locale = 'en';
      detail.translationStatus = 'canonical';
    }
  }

  return json({ ok: true, hotel: detail }, 200, admin ? undefined : PUBLIC_CACHE_HEADERS);
}

function applyHotelTranslation(detail, translated) {
  if (!translated || typeof translated !== 'object') return detail;
  const fields = [
    'propertyType','address','description','checkIn','checkOut','amenities','policies',
    'nearby','facts','fees','services','highlights','importantInformation','food',
    'parkingTransport','accessibility','rooms'
  ];
  for (const field of fields) {
    if (translated[field] != null) detail[field] = translated[field];
  }
  return detail;
}

async function saveHotel(request, env, user) {
  const payload = await readJSON(request, 4_000_000);
  if (!payload.ok) return payload.response;

  // Direct admin saves are always server-side drafts. Publishing is reserved for
  // the import workflow after media/data integrity checks have completed.
  const safeDraft = { ...(payload.value || {}), status: 'draft', lifecycleState: 'draft' };
  const allowPossibleDuplicate = request.headers.get('x-iumrah-allow-possible-duplicate') === '1';
  const duplicate = await findDuplicateHotel(env, safeDraft, safeID(safeDraft.id));
  if (duplicate?.certainty === 'definitive') return json({ ok: false, error: 'HOTEL_ALREADY_EXISTS', duplicate }, 409);
  if (duplicate?.certainty === 'possible' && !allowPossibleDuplicate) return json({ ok: false, error: 'POSSIBLE_DUPLICATE', duplicate }, 409);
  const result = await persistHotelDraft(safeDraft, env, user, { checkDuplicate: false });
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
  const propertyType = safeHumanText(draft.propertyType, 120);
  const stars = nullableInteger(draft.stars, 1, 5);
  const rating = nullableNumber(draft.rating, 0, 10);
  const ratingScale = nullableNumber(draft.ratingScale, 1, 10);
  const reviewCount = nullableInteger(draft.reviewCount, 0, 100000000);
  const address = safeHumanText(draft.address, 900) || '';
  const description = safeHumanText(draft.description, 3_500) || '';
  const latitude = nullableNumber(draft.latitude, -90, 90);
  const longitude = nullableNumber(draft.longitude, -180, 180);
  const checkIn = safeHumanText(draft.checkIn, 120);
  const checkOut = safeHumanText(draft.checkOut, 120);
  const policies = []; // provider policies are intentionally not part of the core catalog
  const nearby = safeObjectArray(draft.nearby, 24, 24_000);
  const facts = []; // noisy provider facts are omitted from the canonical selection object
  const fees = [];
  const services = []; // canonical amenities are stored in hotel_amenities
  const brand = safeHumanText(draft.brand, 180);
  const chainName = safeHumanText(draft.chain, 180) || safeHumanText(draft.chainName, 180);
  const postalCode = safeHumanText(draft.postalCode, 40);
  const highlights = uniqueStrings(draft.highlights, 16, 420);
  const importantInformation = [];
  const food = safeObjectArray(draft.food, 16, 24_000);
  const parkingTransport = safeObjectArray(draft.parkingTransport, 16, 24_000);
  const accessibility = uniqueStrings(draft.accessibility, 16, 360);
  const dataQuality = sanitizeObject(draft.dataQuality, 24_000);
  const googleMaps = cleanURL(draft.googleMapsURL) || googleMapsURL(latitude, longitude, address);
  const canonicalKey = canonicalHotelKey(name, city, address, latitude, longitude);
  // Persisting code never elevates an incoming payload to published. The workflow
  // is the only publication authority.
  const status = draft.status === 'archived' ? 'archived' : 'draft';
  const lifecycleState = cleanLifecycleState(draft.lifecycleState) || (status === 'archived' ? 'archived' : 'draft');
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

  const amenities = canonicalAmenities(draft.amenities, 120);
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
          id, hotel_id, name, max_guests, size_m2, beds, view, description, amenities_json,
          smoking, accessibility_json, category, bathroom_json, position
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      `).bind(
        roomID,
        id,
        roomName,
        nullableInteger(room?.maxGuests, 1, 30),
        nullableNumber(room?.sizeM2, 1, 3000),
        safeHumanText(room?.beds, 300),
        safeHumanText(room?.view, 300),
        safeHumanText(room?.description, 1200),
        JSON.stringify(uniqueStrings(room?.amenities, 60, 180)),
        safeHumanText(room?.smoking, 160),
        JSON.stringify(uniqueStrings(room?.accessibility, 24, 220)),
        safeHumanText(room?.category, 160),
        JSON.stringify(uniqueStrings(room?.bathroom, 24, 220)),
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
        safeHumanText(source?.name, 300),
        canonicalCity(source?.city) || cleanText(source?.city, 80),
        safeHumanText(source?.country, 120),
        safeHumanText(source?.propertyType, 120),
        safeHumanText(source?.address, 900),
        null,
        nullableInteger(source?.stars, 1, 5),
        nullableNumber(source?.rating, 0, 10),
        nullableNumber(source?.ratingScale, 1, 10),
        nullableInteger(source?.reviewCount, 0, 100000000),
        nullableNumber(source?.latitude, -90, 90),
        nullableNumber(source?.longitude, -180, 180),
        safeHumanText(source?.checkIn, 120),
        safeHumanText(source?.checkOut, 120),
        '[]',
        '[]',
        '[]',
        '[]',
        '[]',
        cleanText(source?.providerHotelID, 220),
        cleanURL(source?.canonicalURL),
        cleanURL(source?.googleMapsURL) || googleMapsURL(source?.latitude, source?.longitude, source?.address),
        '[]',
        '[]',
        '[]',
        '[]',
        now
      )
    );
  });

  await env.HOTELS_DB.batch(statements);

  await env.HOTELS_DB.prepare(`
    UPDATE hotels
    SET brand=?, chain_name=?, postal_code=?, highlights_json=?, important_information_json=?,
        food_json=?, parking_transport_json=?, accessibility_json=?, lifecycle_state=?,
        data_quality_json=?, last_verified_at=?, catalog_profile='core-v1', source_room_count=?, updated_at=?
    WHERE id=?
  `).bind(
    brand,
    chainName,
    postalCode,
    JSON.stringify(highlights),
    JSON.stringify(importantInformation),
    JSON.stringify(food),
    JSON.stringify(parkingTransport),
    JSON.stringify(accessibility),
    lifecycleState,
    JSON.stringify(dataQuality),
    now,
    rooms.filter(room => isPlausibleRoomName(room?.name)).length,
    now,
    id
  ).run();

  for (const source of sources) {
    const sourceURL = cleanURL(source?.sourceURL);
    const provider = cleanText(source?.provider, 80);
    if (!sourceURL || !provider) continue;
    await env.HOTELS_DB.prepare(`
      UPDATE hotel_sources
      SET brand=?, chain_name=?, postal_code=?, highlights_json=?, important_information_json=?,
          food_json=?, parking_transport_json=?, accessibility_json=?, raw_identity_json=?
      WHERE hotel_id=? AND LOWER(provider)=LOWER(?) AND source_url=?
    `).bind(
      safeHumanText(source?.brand, 180),
      safeHumanText(source?.chain, 180) || safeHumanText(source?.chainName, 180),
      safeHumanText(source?.postalCode, 40),
      '[]',
      '[]',
      '[]',
      '[]',
      '[]',
      '{}',
      id,
      provider,
      sourceURL
    ).run();
  }

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
  if (isRepairableDuplicate(duplicate)) {
    return json({ ok: true, duplicate: null, repairable: duplicate });
  }
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
      SELECT h.id, h.name, h.city, h.address, h.latitude, h.longitude, h.brand, h.chain_name, h.status, h.lifecycle_state, hs.provider, hs.source_url
      FROM hotel_sources hs JOIN hotels h ON h.id = hs.hotel_id
      WHERE (hs.source_url = ? OR hs.canonical_url = ?) ${excludeID ? 'AND h.id != ?' : ''}
      LIMIT 1
    `).bind(...(excludeID ? [sourceURL, canonicalSource, excludeID] : [sourceURL, canonicalSource])).first();
    if (row) return duplicateSummary(row, 'same_source', 'definitive', 1);
  }

  for (const source of Array.isArray(draft?.sources) ? draft.sources : []) {
    const provider = cleanText(source?.provider, 80);
    const providerHotelID = cleanText(source?.providerHotelID, 220);
    if (!provider || !providerHotelID) continue;
    const row = await env.HOTELS_DB.prepare(`
      SELECT h.id, h.name, h.city, h.address, h.latitude, h.longitude, h.brand, h.chain_name, h.status, h.lifecycle_state, hs.provider, hs.source_url
      FROM hotel_sources hs JOIN hotels h ON h.id = hs.hotel_id
      WHERE LOWER(hs.provider) = LOWER(?) AND hs.provider_hotel_id = ? ${excludeID ? 'AND h.id != ?' : ''}
      LIMIT 1
    `).bind(...(excludeID ? [provider, providerHotelID, excludeID] : [provider, providerHotelID])).first();
    if (row) return duplicateSummary(row, 'provider_id', 'definitive', 1);
  }

  const name = cleanText(draft?.name, 180);
  const city = canonicalCity(draft?.city);
  if (!name || !city) return null;

  const latitude = nullableNumber(draft?.latitude, -90, 90);
  const longitude = nullableNumber(draft?.longitude, -180, 180);
  const address = cleanText(draft?.address, 900) || '';
  const requestedBrand = cleanText(draft?.brand, 180) || cleanText(draft?.chain, 180) || '';
  const candidates = await env.HOTELS_DB.prepare(`
    SELECT id, name, city, address, latitude, longitude, brand, chain_name, status, lifecycle_state
    FROM hotels
    WHERE LOWER(city) = LOWER(?) ${excludeID ? 'AND id != ?' : ''}
    ORDER BY updated_at DESC
    LIMIT 600
  `).bind(...(excludeID ? [city, excludeID] : [city])).all();

  const requestedTokens = hotelNameTokens(name);
  const requestedAddress = normalizedAddress(address);
  const requestedBrandTokens = hotelNameTokens(requestedBrand);
  let bestPossible = null;

  for (const row of candidates.results || []) {
    const nameScore = tokenSimilarity(requestedTokens, hotelNameTokens(row.name));
    const addressScore = requestedAddress && row.address
      ? tokenSimilarity(addressTokens(requestedAddress), addressTokens(normalizedAddress(row.address)))
      : 0;
    const candidateBrand = `${row.brand || ''} ${row.chain_name || ''}`.trim();
    const brandScore = requestedBrandTokens.size && candidateBrand
      ? tokenSimilarity(requestedBrandTokens, hotelNameTokens(candidateBrand))
      : 0;
    const geoMeters = latitude != null && longitude != null && row.latitude != null && row.longitude != null
      ? haversineMeters(latitude, longitude, Number(row.latitude), Number(row.longitude))
      : null;

    // Definitive physical-property matches require two strong independent signals.
    if (geoMeters != null && geoMeters <= 80 && nameScore >= 0.55) {
      const confidence = Math.min(0.99, 0.90 + nameScore * 0.08 + (brandScore > 0.6 ? 0.01 : 0));
      return duplicateSummary(row, 'same_property_geo', 'definitive', confidence, { nameScore, addressScore, brandScore, geoMeters });
    }
    if (nameScore >= 0.88 && addressScore >= 0.70) {
      const confidence = Math.min(0.99, 0.88 + nameScore * 0.06 + addressScore * 0.05);
      return duplicateSummary(row, 'same_property_address', 'definitive', confidence, { nameScore, addressScore, brandScore, geoMeters });
    }

    // A similar name alone is never enough to auto-block; surface it for human review.
    let possibleConfidence = 0;
    let possibleMatch = null;
    if (geoMeters != null && geoMeters <= 250 && nameScore >= 0.45) {
      possibleConfidence = 0.72 + Math.min(0.12, nameScore * 0.10) + (geoMeters <= 120 ? 0.05 : 0);
      possibleMatch = 'possible_property_geo';
    } else if (nameScore >= 0.70 && addressScore >= 0.40) {
      possibleConfidence = 0.68 + nameScore * 0.10 + addressScore * 0.08;
      possibleMatch = 'possible_property_address';
    } else if (nameScore >= 0.90) {
      possibleConfidence = 0.72 + nameScore * 0.08 + (brandScore >= 0.60 ? 0.04 : 0);
      possibleMatch = 'possible_property_name';
    }

    if (possibleMatch) {
      const candidate = duplicateSummary(row, possibleMatch, 'possible', Math.min(0.89, possibleConfidence), { nameScore, addressScore, brandScore, geoMeters });
      if (!bestPossible || candidate.confidence > bestPossible.confidence) bestPossible = candidate;
    }
  }

  return bestPossible;
}

function duplicateSummary(row, match, certainty = 'definitive', confidence = 1, signals = null) {
  return {
    id: row.id,
    name: row.name,
    city: row.city,
    address: row.address || '',
    latitude: row.latitude == null ? null : Number(row.latitude),
    longitude: row.longitude == null ? null : Number(row.longitude),
    brand: row.brand || null,
    chain: row.chain_name || null,
    provider: row.provider || null,
    sourceURL: row.source_url || null,
    status: row.status || null,
    lifecycleState: row.lifecycle_state || row.status || null,
    match,
    certainty,
    confidence: Math.round(Math.max(0, Math.min(1, Number(confidence) || 0)) * 1000) / 1000,
    signals: signals || null
  };
}

function isRepairableDuplicate(duplicate) {
  if (!duplicate || duplicate.certainty !== 'definitive') return false;
  const status = String(duplicate.status || '').toLowerCase();
  const lifecycle = String(duplicate.lifecycleState || status).toLowerCase();
  if (status === 'published' || lifecycle === 'published' || lifecycle === 'importing') return false;
  return ['draft','failed','ready','archived'].includes(status) || ['draft','failed','ready','archived'].includes(lifecycle);
}


async function recoverSourceRooms(request, env) {
  const payload = await readJSON(request, 100_000);
  if (!payload.ok) return payload.response;
  const sourceURL = cleanURL(payload.value?.sourceURL);
  if (!sourceURL) return json({ ok: false, error: 'INVALID_SOURCE_URL' }, 400);

  let input;
  try { input = new URL(sourceURL); } catch (_) { return json({ ok: false, error: 'INVALID_SOURCE_URL' }, 400); }
  const inputHost = input.hostname.toLowerCase();
  const hintedProvider = inputHost === 'expe.onelink.me' || inputHost.endsWith('.expe.onelink.me')
    ? 'Expedia'
    : detectRoomProvider(input);
  if (!hintedProvider) return json({ ok: false, error: 'UNSUPPORTED_SOURCE_PROVIDER' }, 400);

  const headers = new Headers({
    'user-agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Mobile/15E148 Safari/604.1',
    'accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
    'accept-language': 'en-US,en;q=0.9',
    'cache-control': 'no-cache'
  });

  let response;
  try {
    response = await fetch(sourceURL, { headers, redirect: 'follow', cf: { cacheTtl: 0 } });
  } catch (error) {
    return json({ ok: false, error: 'SOURCE_ROOM_FETCH_FAILED', detail: String(error?.message || error).slice(0, 500) }, 502);
  }
  if (!response.ok) return json({ ok: false, error: `SOURCE_ROOM_HTTP_${response.status}` }, 502);

  const finalURL = response.url || sourceURL;
  let finalParsed;
  try { finalParsed = new URL(finalURL); } catch (_) { return json({ ok: false, error: 'SOURCE_ROOM_BAD_REDIRECT' }, 502); }
  const provider = detectRoomProvider(finalParsed) || hintedProvider;
  if (!provider || !providerRoomHostAllowed(finalParsed, provider)) {
    return json({ ok: false, error: 'SOURCE_REDIRECT_OUTSIDE_PROVIDER' }, 400);
  }

  const html = await response.text();
  if (!html || html.length < 500) return json({ ok: false, error: 'SOURCE_ROOM_EMPTY_PAGE' }, 502);
  if (html.length > 8_000_000) return json({ ok: false, error: 'SOURCE_ROOM_PAGE_TOO_LARGE' }, 502);
  if (isProviderChallengeHTML(html)) {
    return json({ ok: false, error: 'SOURCE_PROVIDER_CHALLENGE', detail: 'Provider returned an anti-bot verification page instead of the hotel property.' }, 409);
  }

  let rooms = extractProviderRoomsFromHTML(html, provider);
  let recoveryURL = finalURL;
  let method = rooms.length ? 'server-property-page-v3' : 'server-property-page-no-room-match';

  // Room cards are availability-driven on both Expedia and Booking. Probe only the
  // exact resolved property URL with deterministic future dates; this never searches
  // by hotel name and therefore cannot drift to a different physical hotel.
  if (rooms.length < 4) {
    const candidates = roomRecoveryProbeURLs(finalParsed, provider);
    for (const fallbackURL of candidates) {
      try {
        const fallbackResponse = await fetch(fallbackURL, { headers, redirect: 'follow', cf: { cacheTtl: 0 } });
        if (!fallbackResponse.ok) continue;
        const fallbackFinal = new URL(fallbackResponse.url || fallbackURL);
        if (!providerRoomHostAllowed(fallbackFinal, provider)) continue;
        const fallbackHTML = await fallbackResponse.text();
        if (!fallbackHTML || fallbackHTML.length > 8_000_000) continue;
        const recovered = extractProviderRoomsFromHTML(fallbackHTML, provider);
        if (!recovered.length) continue;
        rooms = mergeRecoveredRooms(rooms, recovered);
        recoveryURL = fallbackResponse.url || fallbackURL;
        method = 'server-property-page-dated-probe-v3';
        if (rooms.length >= 4) break;
      } catch (_) {}
    }
  }

  return json({
    ok: true,
    provider,
    sourceURL: recoveryURL,
    roomCount: rooms.length,
    rooms,
    method
  });
}

function isProviderChallengeHTML(html) {
  const text = String(html || '').toLowerCase();
  return [
    'bot or not', 'verify you are human', 'are you a robot', 'security check',
    'robot check', 'unusual traffic', 'captcha', 'access denied'
  ].some(marker => text.includes(marker));
}

function detectRoomProvider(url) {
  const host = String(url?.hostname || '').toLowerCase();
  if (host === 'booking.com' || host.endsWith('.booking.com')) return 'Booking';
  if (host === 'expedia.com' || host.endsWith('.expedia.com') || host.includes('expedia.')) return 'Expedia';
  return null;
}

function providerRoomHostAllowed(url, provider) {
  const host = String(url?.hostname || '').toLowerCase();
  return provider === 'Booking'
    ? host === 'booking.com' || host.endsWith('.booking.com')
    : host === 'expedia.com' || host.endsWith('.expedia.com') || host.includes('expedia.');
}

function roomRecoveryProbeURLs(propertyURL, provider) {
  const offsets = [14, 45];
  const output = [];
  const seen = new Set();
  const dateFor = offset => new Date(Date.now() + offset * 86400000).toISOString().slice(0, 10);
  const push = url => {
    const value = url.toString();
    if (!seen.has(value)) { seen.add(value); output.push(value); }
  };

  for (const offset of offsets) {
    const url = new URL(propertyURL.toString());
    const checkIn = dateFor(offset);
    const checkOut = dateFor(offset + 2);
    if (provider === 'Expedia') {
      url.searchParams.set('chkin', checkIn);
      url.searchParams.set('chkout', checkOut);
      url.searchParams.set('rm1', 'a2');
      url.searchParams.set('useRewards', 'false');
      push(url);

      // Regional Expedia properties share the same .h<propertyID> identity/path.
      // The .com render is often richer server-side, but the path is never changed.
      const canonical = new URL(url.toString());
      canonical.hostname = 'www.expedia.com';
      push(canonical);
    } else {
      url.searchParams.set('checkin', checkIn);
      url.searchParams.set('checkout', checkOut);
      url.searchParams.set('group_adults', '2');
      url.searchParams.set('group_children', '0');
      url.searchParams.set('no_rooms', '1');
      push(url);
    }
  }
  return output.slice(0, 6);
}

function mergeRecoveredRooms(primary, recovered) {
  const out = [];
  const seen = new Set();
  for (const room of [...(primary || []), ...(recovered || [])]) {
    if (!room || !isPlausibleRoomName(room.name)) continue;
    const key = normalizeRoomIdentity(room.name);
    if (!key || seen.has(key)) continue;
    seen.add(key);
    out.push(room);
    if (out.length >= 140) break;
  }
  return out;
}

function extractProviderRoomsFromHTML(html, provider) {
  const visible = htmlToReadableText(html);
  const roomStart = visible.search(/\b(?:room options|rooms and rates|available rooms|choose your room|room types)\b/i);
  let roomText = roomStart >= 0 ? visible.slice(roomStart, roomStart + 180_000) : visible;
  const end = roomText.slice(800).search(/\b(?:about this property|property amenities|location|policies|reviews|getting around)\b/i);
  if (end >= 0) roomText = roomText.slice(0, Math.max(2_500, end + 800));

  const anchors = [];
  const patterns = provider === 'Expedia' ? [
    { source: 'photo', regex: /View all photos for\s+([^\n]{3,220})/gi },
    { source: 'detail', regex: /More details(?:\s+More details)? for\s+([^\n]{3,220})/gi },
    { source: 'price', regex: /View prices(?: for your dates)?(?: for)?\s+([^\n]{3,220})/gi }
  ] : [
    { source: 'room', regex: /(?:Room type|Room name)\s*[:\-]?\s*([^\n]{3,220})/gi }
  ];
  for (const entry of patterns) {
    let match;
    while ((match = entry.regex.exec(roomText)) !== null && anchors.length < 500) {
      anchors.push({ name: cleanRoomAnchor(match[1]), index: match.index, source: entry.source });
    }
  }
  anchors.sort((a, b) => a.index - b.index);

  // Expedia repeats the room name in “More details …” / “View prices …”. When a
  // photo anchor exists for that name, use the photo anchor because the sellable
  // details live between it and the action footer. This prevents details from the
  // next room card leaking into the previous room.
  const photoNames = new Set(anchors.filter(a => a.source === 'photo').map(a => normalizeRoomIdentity(a.name)));
  const visibleAnchors = anchors.filter(a => !['detail','price'].includes(a.source) || !photoNames.has(normalizeRoomIdentity(a.name)));

  // Explicit room-name keys from application state are useful only as a fallback
  // for names not already represented by visible room cards.
  const rawJSONAnchors = [];
  const rawJSONPatterns = [
    /["']roomTypeName["']\s*:\s*["']([^"']{3,220})["']/gi,
    /["']roomName["']\s*:\s*["']([^"']{3,220})["']/gi,
    /["']unitName["']\s*:\s*["']([^"']{3,220})["']/gi
  ];
  for (const pattern of rawJSONPatterns) {
    let match;
    while ((match = pattern.exec(html)) !== null && rawJSONAnchors.length < 300) {
      rawJSONAnchors.push({ name: cleanRoomAnchor(decodeHTMLEntities(match[1])), index: -1, source: 'json' });
    }
  }

  // SSR room cards frequently expose the room name only through aria-label/title
  // attributes. htmlToReadableText intentionally removes tags, so capture those
  // attributes directly before the markup is stripped.
  const rawAttributePatterns = provider === 'Expedia' ? [
    /aria-label=["'][^"']*View all photos for\s+([^"']{3,220})["']/gi,
    /aria-label=["'][^"']*More details(?:\s+More details)? for\s+([^"']{3,220})["']/gi,
    /title=["'][^"']*View all photos for\s+([^"']{3,220})["']/gi
  ] : [
    /data-testid=["'][^"']*room[^"']*["'][^>]*>\s*([^<]{3,220})</gi,
    /aria-label=["'][^"']*(?:room|suite)\s*[:\-]?\s*([^"']{3,220})["']/gi
  ];
  for (const pattern of rawAttributePatterns) {
    let match;
    while ((match = pattern.exec(html)) !== null && rawJSONAnchors.length < 420) {
      rawJSONAnchors.push({ name: cleanRoomAnchor(decodeHTMLEntities(match[1])), index: -1, source: 'attribute' });
    }
  }

  // Expedia application state is often JSON-escaped inside another script string.
  // Normalize only quoting/unicode escapes and then reuse the strict room-name keys.
  const normalizedStructuredHTML = String(html || '')
    .replace(/\\u([0-9a-f]{4})/gi, (_, hex) => String.fromCharCode(parseInt(hex, 16)))
    .replace(/\\"/g, '"');
  if (normalizedStructuredHTML !== html) {
    for (const pattern of rawJSONPatterns) {
      pattern.lastIndex = 0;
      let match;
      while ((match = pattern.exec(normalizedStructuredHTML)) !== null && rawJSONAnchors.length < 500) {
        rawJSONAnchors.push({ name: cleanRoomAnchor(decodeHTMLEntities(match[1])), index: -1, source: 'escaped-json' });
      }
    }
  }

  const processAnchors = [...visibleAnchors];
  const visibleNames = new Set(processAnchors.map(a => normalizeRoomIdentity(a.name)));
  for (const anchor of rawJSONAnchors) {
    if (!visibleNames.has(normalizeRoomIdentity(anchor.name))) processAnchors.push(anchor);
  }

  const result = [];
  const seen = new Set();
  for (let i = 0; i < processAnchors.length; i += 1) {
    const anchor = processAnchors[i];
    const name = safeHumanText(anchor.name, 240);
    if (!name || !isPlausibleRoomName(name)) continue;

    let context = name;
    if (anchor.index >= 0) {
      const nextVisible = anchors.find(other => other.index > anchor.index);
      const endIndex = nextVisible ? Math.min(nextVisible.index, anchor.index + 2_200) : Math.min(roomText.length, anchor.index + 2_200);
      context = roomText.slice(Math.max(0, anchor.index), endIndex);
    }
    const room = roomFromTextContext(name, context);
    const key = [normalizeRoomIdentity(room.name), room.beds || '', room.maxGuests || '', room.sizeM2 || '', room.view || '']
      .join('|').toLowerCase().replace(/\s+/g, ' ');
    if (seen.has(key)) continue;
    seen.add(key);
    result.push(room);
    if (result.length >= 140) break;
  }
  return result;
}

function normalizeRoomIdentity(value) {
  return String(value || '')
    .toLowerCase()
    .replace(/[^a-z0-9\u0400-\u04ff\u0600-\u06ff]+/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

function roomFromTextContext(name, context) {
  const compact = String(context || '').replace(/[ \t]+/g, ' ').replace(/\n{3,}/g, '\n\n');
  const guest = compact.match(/\bSleeps?\s*(\d{1,2})\b/i) || compact.match(/\b(?:up to|max(?:imum)?)\s*(\d{1,2})\s*(?:guests?|people)\b/i);
  const metricSize = compact.match(/\b(\d{1,4}(?:\.\d+)?)\s*(?:sq\s*m|m²|square meters?)\b/i);
  const imperialSize = compact.match(/\b(\d{2,5}(?:\.\d+)?)\s*(?:sq\s*ft|ft²|square feet)\b/i);
  const sizeM2 = metricSize ? Number(metricSize[1]) : imperialSize ? Math.round(Number(imperialSize[1]) * 0.092903 * 10) / 10 : null;
  const bed = compact.match(/\b(?:\d+\s+)?(?:King|Queen|Twin|Double|Single|Large Twin|Sofa)\s+Beds?(?:\s+(?:and|or)\s+(?:\d+\s+)?(?:King|Queen|Twin|Double|Single|Large Twin|Sofa)\s+Beds?)*/i);
  const view = compact.match(/\b(?:city|kaaba|kabba|haram|landmark|mountain|courtyard|garden|sea)\s+view\b/i);
  const category = name.match(/\b(standard|superior|deluxe|executive|premier|classic|family|studio|junior suite|suite|presidential|royal)\b/i);
  return {
    id: crypto.randomUUID(),
    name,
    maxGuests: guest ? Number(guest[1]) : null,
    sizeM2: Number.isFinite(sizeM2) ? sizeM2 : null,
    beds: bed ? cleanText(bed[0], 260) : null,
    view: view ? cleanText(view[0], 180) : null,
    description: null,
    amenities: /free wi[- ]?fi/i.test(compact) ? ['Free WiFi'] : [],
    smoking: /non[- ]smoking|smoke[- ]free/i.test(compact) ? 'Non-smoking' : null,
    accessibility: [],
    category: category ? category[1] : null,
    bathroom: []
  };
}

function cleanRoomAnchor(value) {
  return String(value || '')
    .replace(/\\u002F/gi, '/')
    .replace(/\\u0026/gi, '&')
    .replace(/\\"/g, '"')
    .replace(/\s+(?:image|photo)\s*:\s*.*$/i, '')
    .replace(/\s+/g, ' ')
    .trim()
    .slice(0, 240);
}

function htmlToReadableText(html) {
  return decodeHTMLEntities(String(html || '')
    .replace(/<script\b[^>]*>[\s\S]*?<\/script>/gi, '\n')
    .replace(/<style\b[^>]*>[\s\S]*?<\/style>/gi, '\n')
    .replace(/<noscript\b[^>]*>[\s\S]*?<\/noscript>/gi, '\n')
    .replace(/<br\s*\/?\s*>/gi, '\n')
    .replace(/<\/(?:p|div|section|article|li|h1|h2|h3|h4|button|a)>/gi, '\n')
    .replace(/<[^>]+>/g, ' '))
    .replace(/\r/g, '')
    .replace(/[ \t]+/g, ' ')
    .replace(/\n[ \t]+/g, '\n')
    .replace(/\n{3,}/g, '\n\n')
    .trim();
}

function decodeHTMLEntities(value) {
  return String(value || '')
    .replace(/&nbsp;/gi, ' ')
    .replace(/&amp;/gi, '&')
    .replace(/&quot;/gi, '"')
    .replace(/&#39;|&apos;/gi, "'")
    .replace(/&lt;/gi, '<')
    .replace(/&gt;/gi, '>')
    .replace(/&#x([0-9a-f]+);/gi, (_, hex) => String.fromCodePoint(parseInt(hex, 16)))
    .replace(/&#(\d+);/g, (_, num) => String.fromCodePoint(parseInt(num, 10)));
}



function prioritizeImportImages(images, limit = 48) {
  const input = Array.isArray(images) ? images : [];
  const output = [];
  const seenURL = new Set();
  const take = image => {
    if (!image?.url || output.length >= limit) return;
    const key = canonicalImageSourceKey(image.url) || image.url;
    if (seenURL.has(key)) return;
    seenURL.add(key);
    output.push({ ...image, position: output.length });
  };

  input.filter(image => image.isCover).forEach(take);

  // First preserve room diversity: one photo per named room, then a second pass.
  const namedRooms = new Map();
  for (const image of input) {
    const room = cleanText(image?.roomName, 260);
    if (!room) continue;
    if (!namedRooms.has(room)) namedRooms.set(room, []);
    namedRooms.get(room).push(image);
  }
  for (let pass = 0; pass < 2 && output.length < limit; pass += 1) {
    for (const roomImages of namedRooms.values()) {
      if (roomImages[pass]) take(roomImages[pass]);
      if (output.length >= limit) break;
    }
  }

  const categoryOrder = ['exterior','lobby','room','bathroom','restaurant','breakfast','view','pool','gym','spa','lounge','facility','gallery'];
  for (const category of categoryOrder) {
    const candidate = input.find(image => image.category === category);
    if (candidate) take(candidate);
  }

  for (const image of input) take(image);
  if (output.length && !output.some(image => image.isCover)) output[0].isCover = true;
  return output;
}

function compactHotelImportSnapshot(draft, images) {
  const source = Array.isArray(draft?.sources) ? draft.sources[0] : null;
  const rooms = Array.isArray(draft?.rooms)
    ? draft.rooms.filter(room => isPlausibleRoomName(room?.name)).slice(0, 140).map(room => ({
        id: safeID(room?.id) || crypto.randomUUID(),
        name: safeHumanText(room?.name, 240),
        maxGuests: nullableInteger(room?.maxGuests, 1, 30),
        sizeM2: nullableNumber(room?.sizeM2, 1, 3000),
        beds: safeHumanText(room?.beds, 260),
        view: safeHumanText(room?.view, 220),
        category: safeHumanText(room?.category, 160),
        amenities: uniqueStrings(room?.amenities, 40, 180)
      }))
    : [];
  return {
    version: 'core-v1',
    id: safeID(draft?.id),
    name: safeHumanText(draft?.name, 180),
    city: canonicalCity(draft?.city),
    country: safeHumanText(draft?.country, 120),
    propertyType: safeHumanText(draft?.propertyType, 120),
    brand: safeHumanText(draft?.brand, 180),
    chain: safeHumanText(draft?.chain, 180),
    postalCode: safeHumanText(draft?.postalCode, 40),
    stars: nullableInteger(draft?.stars, 1, 5),
    rating: nullableNumber(draft?.rating, 0, 10),
    ratingScale: nullableNumber(draft?.ratingScale, 1, 10),
    reviewCount: nullableInteger(draft?.reviewCount, 0, 100000000),
    address: safeHumanText(draft?.address, 900),
    latitude: nullableNumber(draft?.latitude, -90, 90),
    longitude: nullableNumber(draft?.longitude, -180, 180),
    checkIn: safeHumanText(draft?.checkIn, 120),
    checkOut: safeHumanText(draft?.checkOut, 120),
    amenities: canonicalAmenities(draft?.amenities, 120),
    nearby: safeObjectArray(draft?.nearby, 24, 24_000),
    food: safeObjectArray(draft?.food, 16, 24_000),
    parkingTransport: safeObjectArray(draft?.parkingTransport, 16, 24_000),
    rooms,
    images: (Array.isArray(images) ? images : []).slice(0, 240).map(image => ({
      url: cleanURL(image?.url),
      provider: cleanText(image?.provider, 80),
      sourcePageURL: cleanURL(image?.sourcePageURL),
      category: validImageCategory(image?.category) || validImageCategory(image?.kind) || 'gallery',
      roomName: safeHumanText(image?.roomName, 260),
      isCover: image?.isCover === true,
      position: boundedInteger(image?.position, 0, 10000, 0)
    })).filter(image => image.url),
    source: source ? {
      provider: cleanText(source?.provider, 80),
      sourceURL: cleanURL(source?.sourceURL),
      canonicalURL: cleanURL(source?.canonicalURL),
      providerHotelID: cleanText(source?.providerHotelID, 220),
      checkedAt: new Date().toISOString()
    } : null
  };
}

async function createImportJob(request, env, user) {
  const payload = await readJSON(request, 4_000_000);
  if (!payload.ok) return payload.response;
  const draft = payload.value?.hotel || payload.value;
  const selectedImages = Array.isArray(payload.value?.images)
    ? payload.value.images
    : Array.isArray(draft?.images) ? draft.images.filter(image => image?.selected !== false) : [];
  const idempotencyKey = cleanText(payload.value?.idempotencyKey || request.headers.get('idempotency-key'), 180);
  const allowPossibleDuplicate = payload.value?.allowPossibleDuplicate === true;

  if (idempotencyKey) {
    const existing = await env.HOTELS_DB.prepare('SELECT id FROM hotel_import_jobs WHERE idempotency_key=? LIMIT 1').bind(idempotencyKey).first();
    if (existing?.id) return importJobDetail(env, existing.id, 200);
  }

  const duplicate = await findDuplicateHotel(env, draft, null);
  const repairDuplicate = isRepairableDuplicate(duplicate) ? duplicate : null;
  if (duplicate?.certainty === 'definitive' && !repairDuplicate) {
    return json({ ok: false, error: 'HOTEL_ALREADY_EXISTS', duplicate }, 409);
  }
  if (duplicate?.certainty === 'possible' && !allowPossibleDuplicate) {
    return json({ ok: false, error: 'POSSIBLE_DUPLICATE', duplicate }, 409);
  }

  const cleanedImages = selectedImages.slice(0, 240).map((image, index) => ({
    url: cleanURL(image?.url),
    provider: cleanText(image?.provider, 80) || 'unknown',
    sourcePageURL: cleanURL(image?.sourcePageURL),
    category: validImageCategory(image?.kind) || validImageCategory(image?.category) || 'gallery',
    label: cleanText(image?.label, 600),
    roomName: cleanText(image?.roomName, 260),
    isCover: image?.isCover === true,
    position: index
  })).filter(image => image.url && image.category !== 'other');
  const images = prioritizeImportImages(cleanedImages, 48);

  if (!images.length) return json({ ok: false, error: 'NO_IMAGES_SELECTED' }, 400);

  const plausibleRooms = Array.isArray(draft?.rooms) ? draft.rooms.filter(room => isPlausibleRoomName(room?.name)) : [];
  if (payload.value?.publishWhenComplete === true && plausibleRooms.length === 0) {
    return json({ ok: false, error: 'ROOM_TYPES_REQUIRED', detail: 'Published hotel requires at least one confirmed room type.' }, 422);
  }
  const trustedImageCount = images.filter(image => image.category !== 'other').length;
  const canPublish = Boolean(payload.value?.publishWhenComplete) && trustedImageCount >= 4 && plausibleRooms.length > 0;
  const safeDraft = { ...draft, id: repairDuplicate?.id || draft?.id, status: 'draft', lifecycleState: 'importing' };
  const persisted = await persistHotelDraft(safeDraft, env, user, { checkDuplicate: false });
  if (!persisted.ok) return persisted.response;

  const hotelID = persisted.hotelID;
  if (repairDuplicate) {
    // Re-importing a failed/draft record repairs the same canonical hotel instead of
    // creating a duplicate. Old partial media is removed before the immutable new job starts.
    await deleteAllHotelImagesInternal(env, hotelID);
  }
  const jobID = `hotel-import-${crypto.randomUUID()}`;
  const snapshotJSON = JSON.stringify(compactHotelImportSnapshot(safeDraft, images));
  const snapshotHash = await sha256Hex(snapshotJSON);
  const now = new Date().toISOString();

  try {
    await env.HOTELS_DB.prepare(`
      INSERT INTO hotel_import_jobs (
        id, hotel_id, hotel_name, source_provider, source_url, status, stage, progress,
        total_images, stored_images, failed_images, images_json, publish_when_complete, updated_at,
        idempotency_key, hotel_snapshot_json, snapshot_hash, retry_count, possible_duplicate_json
      ) VALUES (?, ?, ?, ?, ?, 'queued', 'queued', 0, ?, 0, 0, ?, ?, ?, ?, ?, ?, 0, ?)
    `).bind(
      jobID,
      hotelID,
      cleanText(draft?.name, 180) || hotelID,
      cleanText(draft?.sources?.[0]?.provider, 80),
      cleanURL(draft?.sources?.[0]?.sourceURL),
      images.length,
      JSON.stringify(images),
      canPublish ? 1 : 0,
      now,
      idempotencyKey,
      snapshotJSON,
      snapshotHash,
      duplicate?.certainty === 'possible' ? JSON.stringify(duplicate) : null
    ).run();
  } catch (error) {
    if (idempotencyKey) {
      const existing = await env.HOTELS_DB.prepare('SELECT id FROM hotel_import_jobs WHERE idempotency_key=? LIMIT 1').bind(idempotencyKey).first();
      if (existing?.id) return importJobDetail(env, existing.id, 200);
    }
    throw error;
  }

  await env.HOTELS_DB.prepare("UPDATE hotels SET lifecycle_state='importing', status='draft', updated_at=? WHERE id=?")
    .bind(now, hotelID).run();

  try {
    const instance = await env.HOTEL_IMPORT_WORKFLOW.create({
      id: jobID,
      params: { jobID, hotelID, images, publishWhenComplete: canPublish, snapshotHash }
    });
    await env.HOTELS_DB.prepare(`
      UPDATE hotel_import_jobs SET workflow_instance_id = ?, updated_at = ?, heartbeat_at = ? WHERE id = ?
    `).bind(instance.id, new Date().toISOString(), new Date().toISOString(), jobID).run();
  } catch (error) {
    console.error('HOTEL_WORKFLOW_START_FAILED', error);
    const failedAt = new Date().toISOString();
    await env.HOTELS_DB.batch([
      env.HOTELS_DB.prepare(`
        UPDATE hotel_import_jobs SET status = 'failed', stage = 'start_failed', error = ?, last_error_code='WORKFLOW_START_FAILED', completed_at = ?, updated_at = ?, heartbeat_at = ? WHERE id = ?
      `).bind(String(error?.message || error).slice(0, 1200), failedAt, failedAt, failedAt, jobID),
      env.HOTELS_DB.prepare("UPDATE hotels SET lifecycle_state='failed', status='draft', updated_at=? WHERE id=?").bind(failedAt, hotelID)
    ]);
    return json({ ok: false, error: 'IMPORT_WORKFLOW_START_FAILED', jobID }, 503);
  }

  return importJobDetail(env, jobID, 202);
}


async function reconcileStaleImportJobs(env) {
  const cutoffMs = Date.now() - 15 * 60 * 1000;
  const result = await env.HOTELS_DB.prepare(`
    SELECT id, hotel_id, workflow_instance_id, status, stage, updated_at, heartbeat_at
    FROM hotel_import_jobs
    WHERE status IN ('queued','running')
    ORDER BY updated_at ASC
    LIMIT 40
  `).all();

  for (const row of result.results || []) {
    const heartbeat = Date.parse(row.heartbeat_at || row.updated_at || '');
    if (Number.isFinite(heartbeat) && heartbeat >= cutoffMs) continue;

    let workflowStatus = 'unknown';
    let workflowError = null;
    if (row.workflow_instance_id) {
      try {
        const instance = await env.HOTEL_IMPORT_WORKFLOW.get(row.workflow_instance_id);
        const details = await instance.status();
        workflowStatus = details?.status || 'unknown';
        workflowError = details?.error?.message || null;
        if (['running','queued','waiting','waitingForPause','paused'].includes(workflowStatus)) {
          await instance.terminate().catch(() => {});
          workflowStatus = 'terminated';
        }
      } catch (error) {
        workflowError = String(error?.message || error).slice(0, 500);
      }
    }

    const now = new Date().toISOString();
    const reason = workflowError
      ? `STALE_IMPORT_RECOVERED: ${workflowError}`
      : `STALE_IMPORT_RECOVERED: workflow=${workflowStatus}`;
    await env.HOTELS_DB.batch([
      env.HOTELS_DB.prepare(`
        UPDATE hotel_import_jobs
        SET status='failed', stage='stale_recovered', progress=MIN(progress, 99), error=?, last_error_code='STALE_IMPORT',
            completed_at=COALESCE(completed_at, ?), updated_at=?, heartbeat_at=?
        WHERE id=? AND status IN ('queued','running')
      `).bind(reason.slice(0, 1200), now, now, now, row.id),
      env.HOTELS_DB.prepare(`
        UPDATE hotels SET status='draft', lifecycle_state='failed', updated_at=?
        WHERE id=? AND status!='published'
      `).bind(now, row.hotel_id)
    ]);
  }
}

async function terminateWorkflowForJob(env, row) {
  if (!row?.workflow_instance_id) return;
  try {
    const instance = await env.HOTEL_IMPORT_WORKFLOW.get(row.workflow_instance_id);
    const status = await instance.status().catch(() => null);
    if (!status || !['complete','errored','terminated'].includes(status.status)) {
      await instance.terminate().catch(() => {});
    }
  } catch (_) {}
}

async function cancelImportJob(env, jobID) {
  const row = await env.HOTELS_DB.prepare('SELECT * FROM hotel_import_jobs WHERE id=?').bind(jobID).first();
  if (!row) return json({ ok: false, error: 'IMPORT_JOB_NOT_FOUND' }, 404);
  if (!['queued','running'].includes(row.status)) return importJobDetail(env, jobID, 200);

  await terminateWorkflowForJob(env, row);
  const now = new Date().toISOString();
  await env.HOTELS_DB.batch([
    env.HOTELS_DB.prepare(`
      UPDATE hotel_import_jobs
      SET status='failed', stage='cancelled', error='Импорт остановлен пользователем.', last_error_code='CANCELLED',
          cancel_requested_at=?, completed_at=?, updated_at=?, heartbeat_at=?
      WHERE id=?
    `).bind(now, now, now, now, jobID),
    env.HOTELS_DB.prepare(`
      UPDATE hotels SET status='draft', lifecycle_state='failed', updated_at=?
      WHERE id=? AND status!='published'
    `).bind(now, row.hotel_id)
  ]);
  return importJobDetail(env, jobID, 200);
}

async function deleteImportJob(env, jobID) {
  const row = await env.HOTELS_DB.prepare('SELECT * FROM hotel_import_jobs WHERE id=?').bind(jobID).first();
  if (!row) return json({ ok: false, error: 'IMPORT_JOB_NOT_FOUND' }, 404);
  await terminateWorkflowForJob(env, row);
  await env.HOTELS_DB.prepare('DELETE FROM hotel_import_jobs WHERE id=?').bind(jobID).run();
  return json({ ok: true, deletedJobID: jobID, hotelID: row.hotel_id });
}

async function listImportJobs(env, url) {
  await reconcileStaleImportJobs(env);
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
  await reconcileStaleImportJobs(env);
  const row = await env.HOTELS_DB.prepare('SELECT * FROM hotel_import_jobs WHERE id = ?').bind(jobID).first();
  if (!row) return json({ ok: false, error: 'IMPORT_JOB_NOT_FOUND' }, 404);
  return json({ ok: true, job: importJobRow(row) }, status);
}

async function retryImportJob(env, jobID) {
  const row = await env.HOTELS_DB.prepare('SELECT * FROM hotel_import_jobs WHERE id = ?').bind(jobID).first();
  if (!row) return json({ ok: false, error: 'IMPORT_JOB_NOT_FOUND' }, 404);
  if (!['failed'].includes(row.status)) return json({ ok: false, error: 'IMPORT_JOB_NOT_RETRYABLE' }, 409);

  const images = prioritizeImportImages(parseJSONArray(row.images_json), 48);
  const retryAt = new Date().toISOString();
  await env.HOTELS_DB.batch([
    env.HOTELS_DB.prepare(`
      UPDATE hotel_import_jobs
      SET status='queued', stage='retry_queued', progress=0, stored_images=0, failed_images=0, error=NULL, warning=NULL,
          current_image=0, current_image_label=NULL, compression_mode=NULL, last_error_code=NULL, cancel_requested_at=NULL,
          retry_count=retry_count+1, started_at=NULL, completed_at=NULL, updated_at=?, heartbeat_at=? WHERE id=?
    `).bind(retryAt, retryAt, jobID),
    env.HOTELS_DB.prepare("UPDATE hotels SET status='draft', lifecycle_state='importing', updated_at=? WHERE id=?")
      .bind(retryAt, row.hotel_id)
  ]);
  await deleteAllHotelImagesInternal(env, row.hotel_id);

  try {
    const instance = await env.HOTEL_IMPORT_WORKFLOW.create({
      id: `${jobID}-retry-${crypto.randomUUID().slice(0, 8)}`,
      params: { jobID, hotelID: row.hotel_id, images, publishWhenComplete: Number(row.publish_when_complete) === 1, snapshotHash: row.snapshot_hash || null }
    });
    await env.HOTELS_DB.prepare('UPDATE hotel_import_jobs SET workflow_instance_id=?, updated_at=?, heartbeat_at=? WHERE id=?')
      .bind(instance.id, new Date().toISOString(), new Date().toISOString(), jobID).run();
  } catch (error) {
    const failedAt = new Date().toISOString();
    await env.HOTELS_DB.batch([
      env.HOTELS_DB.prepare("UPDATE hotel_import_jobs SET status='failed', stage='start_failed', error=?, last_error_code='WORKFLOW_START_FAILED', updated_at=?, heartbeat_at=? WHERE id=?")
        .bind(String(error?.message || error).slice(0, 1200), failedAt, failedAt, jobID),
      env.HOTELS_DB.prepare("UPDATE hotels SET lifecycle_state='failed', status='draft', updated_at=? WHERE id=?")
        .bind(failedAt, row.hotel_id)
    ]);
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
    updatedAt: row.updated_at,
    retryCount: Number(row.retry_count || 0),
    snapshotHash: row.snapshot_hash || null,
    possibleDuplicate: parseJSONObject(row.possible_duplicate_json),
    currentImage: Number(row.current_image || 0),
    currentImageLabel: row.current_image_label || null,
    warning: row.warning || null,
    compressionMode: row.compression_mode || null,
    heartbeatAt: row.heartbeat_at || row.updated_at || null,
    lastErrorCode: row.last_error_code || null,
    cancelRequestedAt: row.cancel_requested_at || null
  };
}

export class HotelImportWorkflow extends WorkflowEntrypoint {
  async run(event, step) {
    const { jobID, hotelID, images = [], publishWhenComplete = false, snapshotHash = null } = event.payload || {};
    if (!safeID(jobID) || !safeID(hotelID) || !Array.isArray(images)) {
      throw new Error('INVALID_IMPORT_WORKFLOW_PAYLOAD');
    }

    await step.do('validate immutable snapshot', async () => {
      const row = await this.env.HOTELS_DB.prepare('SELECT snapshot_hash, hotel_snapshot_json FROM hotel_import_jobs WHERE id=? AND hotel_id=?')
        .bind(jobID, hotelID).first();
      if (!row) throw new Error('IMPORT_JOB_NOT_FOUND');
      const storedHash = cleanText(row.snapshot_hash, 128);
      if (snapshotHash && storedHash && snapshotHash !== storedHash) throw new Error('IMPORT_SNAPSHOT_MISMATCH');
      if (storedHash) {
        const recomputed = await sha256Hex(String(row.hotel_snapshot_json || '{}'));
        if (recomputed !== storedHash) throw new Error('IMPORT_SNAPSHOT_CORRUPTED');
      }
      return { ok: true, snapshotHash: storedHash || null };
    });

    await step.do('mark job running', async () => {
      const now = new Date().toISOString();
      await this.env.HOTELS_DB.batch([
        this.env.HOTELS_DB.prepare(`
          UPDATE hotel_import_jobs
          SET status='running', stage='preparing_media', progress=1, current_image=0, current_image_label=NULL, warning=NULL, started_at=COALESCE(started_at, ?), updated_at=?, heartbeat_at=?
          WHERE id=?
        `).bind(now, now, now, jobID),
        this.env.HOTELS_DB.prepare("UPDATE hotels SET status='draft', lifecycle_state='importing', updated_at=? WHERE id=?")
          .bind(now, hotelID)
      ]);
      return { ok: true };
    });

    let stored = 0;
    let failed = 0;
    const total = images.length;

    for (let index = 0; index < total; index += 1) {
      const item = images[index];
      const itemLabel = cleanText(item?.label || item?.roomName || item?.category || `Фото ${index + 1}`, 220);
      const startProgress = Math.min(92, Math.max(2, Math.round((index / Math.max(total, 1)) * 90)));
      await step.do(`announce image ${String(index + 1).padStart(3, '0')}`, async () => {
        await this.env.HOTELS_DB.prepare(`
          UPDATE hotel_import_jobs
          SET stage='downloading_image', progress=?, current_image=?, current_image_label=?, error=NULL, updated_at=?, heartbeat_at=?
          WHERE id=?
        `).bind(startProgress, index + 1, itemLabel, new Date().toISOString(), new Date().toISOString(), jobID).run();
        return { index: index + 1, label: itemLabel };
      });

      let result;
      try {
        result = await step.do(
          `store image ${String(index + 1).padStart(3, '0')}`,
          { retries: { limit: 2, delay: '3 seconds', backoff: 'exponential' }, timeout: '45 seconds' },
          async () => storeRemoteHotelImage(this.env, jobID, hotelID, item, index)
        );
      } catch (error) {
        result = { ok: false, error: String(error?.message || error).slice(0, 900) };
      }

      if (result?.ok) stored += 1;
      else failed += 1;

      const progress = Math.min(96, Math.max(3, Math.round(((index + 1) / Math.max(total, 1)) * 94)));
      await step.do(`record progress ${String(index + 1).padStart(3, '0')}`, async () => {
        await this.env.HOTELS_DB.prepare(`
          UPDATE hotel_import_jobs
          SET stored_images=?, failed_images=?, progress=?, stage=?, error=?, compression_mode=COALESCE(?, compression_mode), updated_at=?, heartbeat_at=?
          WHERE id=?
        `).bind(
          stored,
          failed,
          progress,
          result?.ok ? 'media_progress' : 'image_retry_exhausted',
          result?.ok ? null : result?.error || 'IMAGE_FAILED',
          result?.compressionMode || null,
          new Date().toISOString(),
          new Date().toISOString(),
          jobID
        ).run();
        return { stored, failed, progress };
      });
    }

    const finalState = await step.do('finalize hotel import', async () => {
      const now = new Date().toISOString();
      const [roomRow, coverRow] = await Promise.all([
        this.env.HOTELS_DB.prepare('SELECT COUNT(*) AS count FROM hotel_rooms WHERE hotel_id=?').bind(hotelID).first(),
        this.env.HOTELS_DB.prepare('SELECT COUNT(*) AS count FROM hotel_images WHERE hotel_id=? AND is_cover=1').bind(hotelID).first()
      ]);
      const roomCount = Number(roomRow?.count || 0);
      const coverCount = Number(coverRow?.count || 0);
      const requiredImages = Math.min(4, total);
      const mediaReady = total > 0 && stored >= requiredImages && coverCount > 0;
      const roomsReady = !publishWhenComplete || roomCount > 0;
      const completed = mediaReady && roomsReady;
      const withWarnings = completed && failed > 0;
      const warning = withWarnings ? `${failed} из ${total} фотографий недоступны у источника; сохранено ${stored}.` : null;
      let failureReason = null;
      if (!mediaReady) failureReason = `Сохранено только ${stored} из ${total} фотографий; для готовой карточки требуется минимум ${requiredImages} и обложка.`;
      else if (!roomsReady) failureReason = 'Не найдено ни одного подтверждённого типа номера; публикация остановлена.';

      if (completed && publishWhenComplete) {
        await this.env.HOTELS_DB.prepare("UPDATE hotels SET status='published', lifecycle_state='published', updated_at=? WHERE id=?")
          .bind(now, hotelID).run();
      } else if (completed) {
        await this.env.HOTELS_DB.prepare("UPDATE hotels SET status='draft', lifecycle_state='ready', updated_at=? WHERE id=?")
          .bind(now, hotelID).run();
      } else {
        await this.env.HOTELS_DB.prepare("UPDATE hotels SET status='draft', lifecycle_state='failed', updated_at=? WHERE id=?")
          .bind(now, hotelID).run();
      }
      await this.env.HOTELS_DB.prepare(`
        UPDATE hotel_import_jobs
        SET status=?, stage=?, progress=100, stored_images=?, failed_images=?, current_image=?, current_image_label=NULL,
            completed_at=?, updated_at=?, heartbeat_at=?, error=?, warning=?
        WHERE id=?
      `).bind(
        completed ? 'completed' : 'failed',
        completed ? (withWarnings ? 'completed_with_warnings' : 'completed') : 'integrity_failed',
        stored,
        failed,
        total,
        now,
        now,
        now,
        completed ? null : failureReason || 'IMPORT_INTEGRITY_FAILED',
        warning,
        jobID
      ).run();
      return { completed, stored, failed, total, hotelID, roomCount, coverCount, warning };
    });

    if (finalState.completed && publishWhenComplete) {
      await step.do('prewarm hotel translations', { retries: { limit: 2, delay: '5 seconds', backoff: 'exponential' }, timeout: '2 minutes' }, async () => {
        try {
          await prewarmHotelTranslations(this.env, hotelID);
          return { ok: true };
        } catch (error) {
          console.error('HOTEL_TRANSLATION_PREWARM_FAILED', { hotelID, error: String(error?.message || error) });
          return { ok: false };
        }
      });
    }

    await step.do('notify business device', async () => {
      try {
        const row = await this.env.HOTELS_DB.prepare('SELECT hotel_name FROM hotel_import_jobs WHERE id=?').bind(jobID).first();
        const title = finalState.completed ? 'Импорт отеля завершён' : 'Ошибка импорта отеля';
        const body = finalState.completed
          ? `${row?.hotel_name || 'Отель'} · сохранено ${finalState.stored} фото${finalState.warning ? ' · есть предупреждение' : ''}.`
          : `${row?.hotel_name || 'Отель'} · импорт требует проверки.`;
        return await sendStaffPush(this.env, title, body, { event: 'hotel_import', jobID, hotelID });
      } catch (error) {
        console.error('BUSINESS_PUSH_FAILED', String(error?.message || error));
        return { ok: false };
      }
    });

    return finalState;
  }
}

async function storeRemoteHotelImage(env, jobID, hotelID, item, fallbackPosition) {
  const sourceURL = cleanURL(item?.url);
  if (!sourceURL) throw new Error('INVALID_IMAGE_URL');
  const category = validImageCategory(item?.category) || 'gallery';
  const isCover = item?.isCover === true ? 1 : 0;
  const optimizedSourceURL = optimizeProviderImageURL(sourceURL, category, isCover === 1);
  const headers = new Headers({
    'user-agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_6 like Mac OS X) AppleWebKit/605.1.15 Version/17.6 Mobile/15E148 Safari/604.1',
    'accept': 'image/avif,image/webp,image/jpeg,image/png,image/*;q=0.8',
    'accept-language': 'en-US,en;q=0.9'
  });
  if (cleanURL(item?.sourcePageURL)) headers.set('referer', item.sourcePageURL);

  const response = await fetch(optimizedSourceURL, { headers, redirect: 'follow' });
  if (!response.ok) throw new Error(`IMAGE_HTTP_${response.status}`);
  const sourceContentType = (response.headers.get('content-type') || '').split(';')[0].trim().toLowerCase();
  if (!['image/jpeg','image/jpg','image/png','image/webp','image/avif'].includes(sourceContentType)) {
    throw new Error(`UNSUPPORTED_IMAGE_TYPE_${sourceContentType || 'unknown'}`);
  }
  const announced = Number(response.headers.get('content-length') || 0);
  if (announced > 12 * 1024 * 1024) throw new Error('IMAGE_TOO_LARGE');
  const sourceBytes = await response.arrayBuffer();
  if (!sourceBytes.byteLength) throw new Error('EMPTY_IMAGE');
  if (sourceBytes.byteLength > 12 * 1024 * 1024) throw new Error('IMAGE_TOO_LARGE');

  const provider = cleanText(item?.provider, 80) || 'unknown';
  const label = cleanText(item?.label, 600);
  const roomName = cleanText(item?.roomName, 260);
  const position = boundedInteger(item?.position, 0, 10000, fallbackPosition);
  const sourceDedupeKey = canonicalImageSourceKey(sourceURL);

  await updateImportJobStage(env, jobID, 'optimizing_image');
  const transformed = await optimizeHotelImageBytes(env, sourceBytes, { category, isCover: isCover === 1, sourceContentType });
  await updateImportJobStage(env, jobID, 'saving_to_r2');
  const contentHash = await sha256HexBytes(transformed.bytes);

  const existing = await env.HOTELS_DB.prepare(`
    SELECT id, object_key FROM hotel_images
    WHERE hotel_id=? AND (content_hash=? OR (? IS NOT NULL AND source_dedupe_key=?))
    LIMIT 1
  `).bind(hotelID, contentHash, sourceDedupeKey, sourceDedupeKey).first();
  if (existing?.id) {
    if (isCover) {
      await env.HOTELS_DB.batch([
        env.HOTELS_DB.prepare('UPDATE hotel_images SET is_cover=0 WHERE hotel_id=?').bind(hotelID),
        env.HOTELS_DB.prepare('UPDATE hotel_images SET is_cover=1, category=?, label=COALESCE(?, label), room_name=COALESCE(?, room_name), position=? WHERE id=?')
          .bind(category, label, roomName, position, existing.id)
      ]);
    }
    return { ok: true, imageID: existing.id, byteSize: transformed.bytes.byteLength, deduplicated: true, compressionMode: transformed.transformVersion };
  }

  const imageID = crypto.randomUUID();
  const objectKey = `hotels/${hotelID}/${contentHash.slice(0, 32)}.${transformed.extension}`;
  await env.HOTELS_MEDIA.put(objectKey, transformed.bytes, {
    httpMetadata: {
      contentType: transformed.contentType,
      cacheControl: 'public, max-age=31536000, immutable'
    },
    customMetadata: {
      hotelID,
      provider,
      category,
      roomName: roomName || '',
      source: 'background-import',
      contentHash,
      transformVersion: transformed.transformVersion
    }
  });

  try {
    const statements = [];
    if (isCover) statements.push(env.HOTELS_DB.prepare('UPDATE hotel_images SET is_cover=0 WHERE hotel_id=?').bind(hotelID));
    statements.push(env.HOTELS_DB.prepare(`
      INSERT INTO hotel_images (
        id, hotel_id, object_key, source_provider, source_url, category, label, room_name,
        content_type, byte_size, position, is_cover, content_hash, width, height,
        original_byte_size, transform_version, source_dedupe_key
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    `).bind(
      imageID,
      hotelID,
      objectKey,
      provider,
      sourceURL,
      category,
      label,
      roomName,
      transformed.contentType,
      transformed.bytes.byteLength,
      position,
      isCover,
      contentHash,
      transformed.width,
      transformed.height,
      sourceBytes.byteLength,
      transformed.transformVersion,
      sourceDedupeKey
    ));
    await env.HOTELS_DB.batch(statements);
  } catch (error) {
    // Concurrent imports can legitimately race on the deterministic content-hash object key.
    // If another transaction already claimed the same optimized image, treat this write as
    // an idempotent success and never delete the shared R2 object out from under the winner.
    const concurrent = await env.HOTELS_DB.prepare(`
      SELECT id FROM hotel_images
      WHERE hotel_id=? AND (content_hash=? OR object_key=?)
      LIMIT 1
    `).bind(hotelID, contentHash, objectKey).first().catch(() => null);
    if (concurrent?.id) {
      if (isCover) {
        await env.HOTELS_DB.batch([
          env.HOTELS_DB.prepare('UPDATE hotel_images SET is_cover=0 WHERE hotel_id=?').bind(hotelID),
          env.HOTELS_DB.prepare('UPDATE hotel_images SET is_cover=1, category=?, label=COALESCE(?, label), room_name=COALESCE(?, room_name), position=? WHERE id=?')
            .bind(category, label, roomName, position, concurrent.id)
        ]).catch(() => {});
      }
      return { ok: true, imageID: concurrent.id, byteSize: transformed.bytes.byteLength, deduplicated: true, raced: true, compressionMode: transformed.transformVersion };
    }
    await env.HOTELS_MEDIA.delete(objectKey).catch(() => {});
    throw error;
  }

  return {
    ok: true,
    imageID,
    byteSize: transformed.bytes.byteLength,
    originalByteSize: sourceBytes.byteLength,
    width: transformed.width,
    height: transformed.height,
    contentHash,
    compressionMode: transformed.transformVersion
  };
}

async function updateImportJobStage(env, jobID, stage) {
  if (!safeID(jobID)) return;
  await env.HOTELS_DB.prepare('UPDATE hotel_import_jobs SET stage=?, updated_at=?, heartbeat_at=? WHERE id=?')
    .bind(stage, new Date().toISOString(), new Date().toISOString(), jobID).run().catch(() => {});
}

async function optimizeHotelImageBytes(env, sourceBytes, { category = 'gallery', isCover = false, sourceContentType = 'image/jpeg' } = {}) {
  const primary = imageTransformProfile(category, isCover, false);
  if (env.IMAGES) {
    try {
      let result = await runImageTransform(env, sourceBytes, primary);
      if (result.bytes.byteLength > primary.maxBytes) {
        const fallback = imageTransformProfile(category, isCover, true);
        result = await runImageTransform(env, sourceBytes, fallback);
        if (result.bytes.byteLength > fallback.maxBytes) throw new Error('OPTIMIZED_IMAGE_TOO_LARGE');
      }
      return { ...result, contentType: 'image/webp', extension: 'webp' };
    } catch (error) {
      console.warn('CLOUDFLARE_IMAGE_TRANSFORM_FALLBACK', String(error?.message || error));
    }
  }

  // Resilient fallback: the source URL itself is requested at a bounded provider
  // resolution. If that already-compressed representation fits our R2 budget, keep
  // it; never fall back to a multi-megabyte original.
  const fallback = imageTransformProfile(category, isCover, true);
  if (sourceBytes.byteLength > fallback.maxBytes) throw new Error('IMAGE_COMPRESSION_UNAVAILABLE_AND_SOURCE_TOO_LARGE');
  const normalizedType = sourceContentType === 'image/jpg' ? 'image/jpeg' : sourceContentType;
  const extension = normalizedType === 'image/png' ? 'png' : normalizedType === 'image/webp' ? 'webp' : normalizedType === 'image/avif' ? 'avif' : 'jpg';
  return {
    bytes: sourceBytes,
    width: null,
    height: null,
    transformVersion: 'provider-sized-fallback-v1',
    contentType: normalizedType,
    extension
  };
}

function imageTransformProfile(category, isCover, fallback) {
  const detailed = ['room','bathroom','restaurant','breakfast','lobby','view','spa','gym','pool','lounge'].includes(category);
  if (isCover) {
    return fallback
      ? { width: 1440, height: 1080, quality: 74, maxBytes: 700_000, transformVersion: 'cf-webp-cover-v3' }
      : { width: 1600, height: 1200, quality: 80, maxBytes: 900_000, transformVersion: 'cf-webp-cover-v3' };
  }
  return fallback
    ? { width: detailed ? 1120 : 1024, height: detailed ? 840 : 768, quality: 70, maxBytes: 480_000, transformVersion: 'cf-webp-standard-v3' }
    : { width: detailed ? 1280 : 1120, height: detailed ? 960 : 840, quality: 76, maxBytes: 650_000, transformVersion: 'cf-webp-standard-v3' };
}

async function runImageTransform(env, sourceBytes, profile) {
  const sourceStream = new Blob([sourceBytes]).stream();
  const transformedResponse = (
    await env.IMAGES
      .input(sourceStream)
      .transform({ width: profile.width, height: profile.height, fit: 'scale-down' })
      .output({ format: 'image/webp', quality: profile.quality, anim: false })
  ).response();

  if (!transformedResponse.ok) throw new Error(`IMAGE_TRANSFORM_HTTP_${transformedResponse.status}`);
  const bytes = await transformedResponse.arrayBuffer();
  if (!bytes.byteLength) throw new Error('IMAGE_TRANSFORM_EMPTY');
  const info = await env.IMAGES.info(new Blob([bytes], { type: 'image/webp' }).stream()).catch(() => null);
  return {
    bytes,
    width: nullableInteger(info?.width, 1, 20000),
    height: nullableInteger(info?.height, 1, 20000),
    transformVersion: profile.transformVersion
  };
}

function optimizeProviderImageURL(value, category = 'gallery', isCover = false) {
  try {
    const url = new URL(value);
    const host = url.hostname.toLowerCase();
    const detailed = ['room','bathroom','restaurant','breakfast','lobby','view','spa','gym','pool','lounge'].includes(category);
    const width = isCover ? 1600 : (detailed ? 1280 : 1120);
    const height = isCover ? 1200 : (detailed ? 960 : 840);
    if (host.includes('trvl-media.com') || host.includes('expedia')) {
      url.searchParams.set('impolicy', 'resizecrop');
      url.searchParams.set('rw', String(width));
      url.searchParams.set('ra', 'fit');
    }
    if (host.includes('bstatic.com') || host.includes('booking.com')) {
      url.pathname = url.pathname.replace(/\/(?:max|square|smart)[0-9x_-]+\//ig, `/max${width}x${height}/`);
    }
    return url.toString();
  } catch {
    return value;
  }
}

function canonicalImageSourceKey(value) {
  try {
    const url = new URL(String(value || ''));
    url.hash = '';
    url.hostname = url.hostname.toLowerCase();
    url.pathname = url.pathname.replace(/\/(?:max|square|smart)[0-9x_-]+\//ig, '/SIZE/');
    for (const key of [...url.searchParams.keys()]) {
      if (['rw','ra','quality','impolicy','w','h','width','height'].includes(key.toLowerCase())) url.searchParams.delete(key);
    }
    return cleanText(url.toString(), 3000);
  } catch {
    return null;
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

  try {
    const result = await getOrCreateHotelTranslation(env, hotelID, locale, hotelResponse);
    return json({ ok: true, locale, cached: result.cached, translation: result.translation }, 200, PUBLIC_CACHE_HEADERS);
  } catch (error) {
    console.error('HOTEL_TRANSLATION_FAILED', { hotelID, locale, error: String(error?.message || error) });
    return json({ ok: false, error: 'TRANSLATION_UNAVAILABLE' }, 503);
  }
}

async function getOrCreateHotelTranslation(env, hotelID, locale, hotelResponse) {
  if (locale === 'en') return { cached: true, translation: hotelResponse };

  const version = locale === 'uz-Cyrl' ? 'uz-cyrl-deterministic-v1' : 'ai-json-v2';
  const sourceHash = await sha256Hex(`${version}|${JSON.stringify(hotelResponse)}`);
  const cached = await env.HOTELS_DB.prepare('SELECT source_hash, payload_json FROM hotel_translations WHERE hotel_id=? AND locale=?')
    .bind(hotelID, locale).first();
  if (cached?.source_hash === sourceHash) {
    try {
      return { cached: true, translation: JSON.parse(cached.payload_json) };
    } catch {}
  }

  let translated;
  if (locale === 'uz-Cyrl') {
    // Uzbek Cyrillic is derived from the cached/validated Uzbek Latin payload so
    // we do not spend a second LLM request and do not get two semantically
    // divergent Uzbek translations for one hotel.
    const latin = await getOrCreateHotelTranslation(env, hotelID, 'uz-Latn', hotelResponse);
    translated = transliterateUzbekObject(latin.translation);
  } else {
    const languageName = locale === 'ru' ? 'Russian' : 'Uzbek in Latin script';
    const system = `You are a hotel localization engine. Translate all human-readable hotel content in the supplied JSON into ${languageName}. Preserve JSON keys, IDs, URLs, numbers, measurements, times, hotel/brand/chain names and source provenance. Never invent missing information, amenities, fees, room data or distances. Do not summarize. Return ONLY valid JSON with exactly the same structure.`;
    const ai = await env.AI.run('@cf/zai-org/glm-4.7-flash', {
      messages: [
        { role: 'system', content: system },
        { role: 'user', content: JSON.stringify(hotelResponse) }
      ],
      max_tokens: 14000,
      temperature: 0.03
    });
    const answer = ai?.response ?? ai?.result?.response ?? ai?.choices?.[0]?.message?.content;
    translated = parseJSONEnvelope(answer);
    if (!translated || typeof translated !== 'object') throw new Error('TRANSLATION_INVALID');
  }

  const now = new Date().toISOString();
  await env.HOTELS_DB.prepare(`
    INSERT INTO hotel_translations (hotel_id, locale, source_hash, payload_json, created_at, updated_at)
    VALUES (?, ?, ?, ?, ?, ?)
    ON CONFLICT(hotel_id, locale) DO UPDATE SET source_hash=excluded.source_hash, payload_json=excluded.payload_json, updated_at=excluded.updated_at
  `).bind(hotelID, locale, sourceHash, JSON.stringify(translated), now, now).run();
  return { cached: false, translation: translated };
}

async function prewarmHotelTranslations(env, hotelID) {
  const hotelResponse = await hotelDataForTranslation(env, hotelID);
  if (!hotelResponse) return;
  await getOrCreateHotelTranslation(env, hotelID, 'ru', hotelResponse);
  await getOrCreateHotelTranslation(env, hotelID, 'uz-Latn', hotelResponse);
  await getOrCreateHotelTranslation(env, hotelID, 'uz-Cyrl', hotelResponse);
}

function transliterateUzbekObject(value, key = '') {
  if (Array.isArray(value)) return value.map(item => transliterateUzbekObject(item, key));
  if (value && typeof value === 'object') {
    const out = {};
    for (const [childKey, child] of Object.entries(value)) out[childKey] = transliterateUzbekObject(child, childKey);
    return out;
  }
  if (typeof value !== 'string') return value;
  const preserveKeys = new Set(['id','url','sourceURL','canonicalURL','googleMapsURL','name','brand','chain','postalCode']);
  if (preserveKeys.has(key) || /^https?:\/\//i.test(value)) return value;
  return uzbekLatinToCyrillic(value);
}

function uzbekLatinToCyrillic(input) {
  const replacements = [
    [/O[‘’ʻʼ'`]/g, 'Ў'], [/o[‘’ʻʼ'`]/g, 'ў'],
    [/G[‘’ʻʼ'`]/g, 'Ғ'], [/g[‘’ʻʼ'`]/g, 'ғ'],
    [/Sh/g, 'Ш'], [/SH/g, 'Ш'], [/sh/g, 'ш'],
    [/Ch/g, 'Ч'], [/CH/g, 'Ч'], [/ch/g, 'ч'],
    [/Yo/g, 'Ё'], [/YO/g, 'Ё'], [/yo/g, 'ё'],
    [/Yu/g, 'Ю'], [/YU/g, 'Ю'], [/yu/g, 'ю'],
    [/Ya/g, 'Я'], [/YA/g, 'Я'], [/ya/g, 'я'],
    [/Ts/g, 'Ц'], [/TS/g, 'Ц'], [/ts/g, 'ц']
  ];
  let text = String(input || '');
  for (const [pattern, replacement] of replacements) text = text.replace(pattern, replacement);
  const map = {
    A:'А', B:'Б', C:'С', D:'Д', E:'Е', F:'Ф', G:'Г', H:'Ҳ', I:'И', J:'Ж', K:'К', L:'Л', M:'М', N:'Н', O:'О', P:'П', Q:'Қ', R:'Р', S:'С', T:'Т', U:'У', V:'В', W:'В', X:'Х', Y:'Й', Z:'З',
    a:'а', b:'б', c:'с', d:'д', e:'е', f:'ф', g:'г', h:'ҳ', i:'и', j:'ж', k:'к', l:'л', m:'м', n:'н', o:'о', p:'п', q:'қ', r:'р', s:'с', t:'т', u:'у', v:'в', w:'в', x:'х', y:'й', z:'з'
  };
  return [...text].map(ch => map[ch] || ch).join('');
}

async function hotelDataForTranslation(env, hotelID) {
  const hotel = await env.HOTELS_DB.prepare("SELECT * FROM hotels WHERE id=? AND status='published'").bind(hotelID).first();
  if (!hotel) return null;
  const [amenities, rooms] = await Promise.all([
    env.HOTELS_DB.prepare('SELECT amenity FROM hotel_amenities WHERE hotel_id=? ORDER BY position').bind(hotelID).all(),
    env.HOTELS_DB.prepare('SELECT id,name,max_guests,size_m2,beds,view,description,amenities_json,smoking,accessibility_json,category,bathroom_json FROM hotel_rooms WHERE hotel_id=? ORDER BY position').bind(hotelID).all()
  ]);
  return {
    name: hotel.name,
    city: hotel.city,
    country: hotel.country,
    propertyType: hotel.property_type || null,
    brand: hotel.brand || null,
    chain: hotel.chain_name || null,
    postalCode: hotel.postal_code || null,
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
    highlights: parseJSONArray(hotel.highlights_json),
    importantInformation: parseJSONArray(hotel.important_information_json),
    food: parseJSONArray(hotel.food_json),
    parkingTransport: parseJSONArray(hotel.parking_transport_json),
    accessibility: parseJSONArray(hotel.accessibility_json),
    rooms: (rooms.results || []).map(row => ({
      id: row.id,
      name: row.name,
      maxGuests: row.max_guests == null ? null : Number(row.max_guests),
      sizeM2: row.size_m2 == null ? null : Number(row.size_m2),
      beds: row.beds || null,
      view: row.view || null,
      description: row.description || null,
      amenities: parseJSONArray(row.amenities_json),
      smoking: row.smoking || null,
      accessibility: parseJSONArray(row.accessibility_json),
      category: row.category || null,
      bathroom: parseJSONArray(row.bathroom_json)
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
  return sha256HexBytes(bytes);
}

async function sha256HexBytes(value) {
  const bytes = value instanceof ArrayBuffer
    ? value
    : ArrayBuffer.isView(value)
      ? value.buffer.slice(value.byteOffset, value.byteOffset + value.byteLength)
      : new Uint8Array(value).buffer;
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
  if (!['image/jpeg', 'image/jpg', 'image/png', 'image/webp', 'image/avif'].includes(contentType)) {
    return json({ ok: false, error: 'UNSUPPORTED_IMAGE_TYPE' }, 415);
  }

  const sourceBytes = await request.arrayBuffer();
  if (!sourceBytes.byteLength) return json({ ok: false, error: 'EMPTY_IMAGE' }, 400);
  if (sourceBytes.byteLength > 12 * 1024 * 1024) return json({ ok: false, error: 'IMAGE_TOO_LARGE' }, 413);

  const provider = cleanText(request.headers.get('x-iumrah-source'), 80) || 'manual';
  const category = validImageCategory(request.headers.get('x-iumrah-category')) || 'gallery';
  const sourceURL = cleanURL(request.headers.get('x-iumrah-source-url'));
  const label = cleanText(request.headers.get('x-iumrah-label'), 600);
  const roomName = cleanText(request.headers.get('x-iumrah-room'), 260);
  const position = boundedInteger(request.headers.get('x-iumrah-position'), 0, 10000, 0);
  const isCover = request.headers.get('x-iumrah-cover') === '1' ? 1 : 0;

  const transformed = await optimizeHotelImageBytes(env, sourceBytes, { category, isCover: isCover === 1, sourceContentType: contentType });
  const contentHash = await sha256HexBytes(transformed.bytes);
  const sourceDedupeKey = sourceURL ? canonicalImageSourceKey(sourceURL) : null;
  const existing = await env.HOTELS_DB.prepare('SELECT id FROM hotel_images WHERE hotel_id=? AND content_hash=? LIMIT 1')
    .bind(hotelID, contentHash).first();
  if (existing?.id) {
    if (isCover) {
      await env.HOTELS_DB.batch([
        env.HOTELS_DB.prepare('UPDATE hotel_images SET is_cover=0 WHERE hotel_id=?').bind(hotelID),
        env.HOTELS_DB.prepare('UPDATE hotel_images SET is_cover=1, category=?, label=COALESCE(?, label), room_name=COALESCE(?, room_name), position=? WHERE id=?')
          .bind(category, label, roomName, position, existing.id)
      ]);
    }
    return json({ ok: true, deduplicated: true, image: { id: existing.id, url: publicImagePath(hotelID, existing.id) } }, 200);
  }

  const imageID = crypto.randomUUID();
  const objectKey = `hotels/${hotelID}/${contentHash.slice(0, 32)}.${transformed.extension}`;
  await env.HOTELS_MEDIA.put(objectKey, transformed.bytes, {
    httpMetadata: { contentType: transformed.contentType, cacheControl: 'public, max-age=31536000, immutable' },
    customMetadata: { hotelID, provider, category, roomName: roomName || '', contentHash, transformVersion: transformed.transformVersion }
  });

  const statements = [];
  if (isCover) statements.push(env.HOTELS_DB.prepare('UPDATE hotel_images SET is_cover = 0 WHERE hotel_id = ?').bind(hotelID));
  statements.push(
    env.HOTELS_DB.prepare(`
      INSERT INTO hotel_images (
        id, hotel_id, object_key, source_provider, source_url, category, label, room_name, content_type,
        byte_size, position, is_cover, content_hash, width, height, original_byte_size, transform_version, source_dedupe_key
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    `).bind(
      imageID, hotelID, objectKey, provider, sourceURL, category, label, roomName, transformed.contentType,
      transformed.bytes.byteLength, position, isCover, contentHash, transformed.width, transformed.height,
      sourceBytes.byteLength, transformed.transformVersion, sourceDedupeKey
    )
  );
  statements.push(env.HOTELS_DB.prepare("UPDATE hotels SET updated_at = strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id = ?").bind(hotelID));

  try {
    await env.HOTELS_DB.batch(statements);
  } catch (error) {
    // Same race protection as the background workflow: a unique content-hash collision
    // means the optimized object is already owned by this hotel, not that R2 should delete it.
    const concurrent = await env.HOTELS_DB.prepare(`
      SELECT id FROM hotel_images
      WHERE hotel_id=? AND (content_hash=? OR object_key=?)
      LIMIT 1
    `).bind(hotelID, contentHash, objectKey).first().catch(() => null);
    if (concurrent?.id) {
      if (isCover) {
        await env.HOTELS_DB.batch([
          env.HOTELS_DB.prepare('UPDATE hotel_images SET is_cover=0 WHERE hotel_id=?').bind(hotelID),
          env.HOTELS_DB.prepare('UPDATE hotel_images SET is_cover=1, category=?, label=COALESCE(?, label), room_name=COALESCE(?, room_name), position=? WHERE id=?')
            .bind(category, label, roomName, position, concurrent.id)
        ]).catch(() => {});
      }
      return json({ ok: true, deduplicated: true, raced: true, image: { id: concurrent.id, url: publicImagePath(hotelID, concurrent.id) } }, 200);
    }
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
      roomName: roomName || '',
      width: transformed.width,
      height: transformed.height,
      byteSize: transformed.bytes.byteLength,
      originalByteSize: sourceBytes.byteLength,
      format: transformed.extension
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
  const hotel = await env.HOTELS_DB.prepare('SELECT id FROM hotels WHERE id=?').bind(hotelID).first();
  if (!hotel) return json({ ok: false, error: 'HOTEL_NOT_FOUND' }, 404);

  const [images, jobs] = await Promise.all([
    env.HOTELS_DB.prepare('SELECT object_key FROM hotel_images WHERE hotel_id = ?').bind(hotelID).all(),
    env.HOTELS_DB.prepare("SELECT * FROM hotel_import_jobs WHERE hotel_id=? AND status IN ('queued','running')").bind(hotelID).all()
  ]);

  // Never delete a canonical row while a workflow can still write into it.
  for (const job of jobs.results || []) await terminateWorkflowForJob(env, job);

  const result = await env.HOTELS_DB.prepare('DELETE FROM hotels WHERE id = ?').bind(hotelID).run();
  if (!result.meta?.changes) return json({ ok: false, error: 'HOTEL_NOT_FOUND' }, 404);

  await Promise.allSettled((images.results || []).map(row => env.HOTELS_MEDIA.delete(row.object_key)));
  return json({ ok: true, deletedHotelID: hotelID });
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
      h.lifecycle_state,
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
    lifecycleState: row.lifecycle_state || row.status,
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
    brand: row.brand || null,
    chain: row.chain_name || null,
    postalCode: row.postal_code || null,
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
    highlights: parseJSONArray(row.highlights_json),
    importantInformation: parseJSONArray(row.important_information_json),
    food: parseJSONArray(row.food_json),
    parkingTransport: parseJSONArray(row.parking_transport_json),
    accessibility: parseJSONArray(row.accessibility_json),
    rawIdentity: parseJSONObject(row.raw_identity_json),
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


function isStructuredNoiseText(value) {
  const text = String(value || '').trim();
  if (!text) return false;
  const lower = text.toLowerCase();
  const tokens = [
    '\\"', '__typename', 'agencybusinessmodels', 'availability_group',
    'bedroomfilter', 'bed_type_group', 'startdate', 'trip-type',
    'shoppingproductcontent', 'egdsplaintext'
  ];
  if (tokens.some(token => lower.includes(token))) return true;
  if (text.includes('{') && (text.includes('"') || text.includes(':'))) return true;
  if (text.includes('[') && text.includes('"')) return true;
  if (lower.includes('see all about this property') && lower.includes('explore the area')) return true;
  if (lower.includes('free wififree cribs') || lower.includes('breakfast for a feerestaurant')) return true;
  return false;
}

function safeHumanText(value, maxLength = 1200) {
  const text = cleanText(value, maxLength);
  if (!text || isStructuredNoiseText(text)) return null;
  return text.replace(/\s+/g, ' ').trim();
}

function canonicalAmenity(value) {
  const text = safeHumanText(value, 240);
  if (!text) return null;
  const lower = text.toLowerCase();
  if (/free wi[- ]?fi|complimentary wi[- ]?fi/.test(lower)) return 'Free WiFi';
  if (/wi[- ]?fi|wireless internet/.test(lower)) return 'Wi‑Fi';
  if (/restaurants?/.test(lower)) return 'Restaurant';
  if (/coffee shop|café|cafe/.test(lower)) return 'Coffee shop';
  if (/24[- ]hour front desk|24 hour front desk/.test(lower)) return '24-hour front desk';
  if (/fitness cent(?:er|re)|\bgym\b/.test(lower)) return 'Fitness center';
  if (/swimming pool|outdoor pool|indoor pool/.test(lower)) return 'Swimming pool';
  if (/airport shuttle|shuttle service/.test(lower)) return 'Airport shuttle';
  if (/valet parking/.test(lower)) return 'Valet parking';
  if (/luggage storage|baggage storage/.test(lower)) return 'Luggage storage';
  return text;
}

function canonicalAmenities(value, maxItems = 320) {
  if (!Array.isArray(value)) return [];
  const result = [];
  const seen = new Set();
  for (const raw of value) {
    const item = canonicalAmenity(raw);
    if (!item) continue;
    const key = item.toLowerCase();
    if (key === 'wi‑fi' && seen.has('free wifi')) continue;
    if (key === 'free wifi') {
      const index = result.findIndex(x => x.toLowerCase() === 'wi‑fi');
      if (index >= 0) result.splice(index, 1);
      seen.delete('wi‑fi');
    }
    if (seen.has(key)) continue;
    seen.add(key);
    result.push(item);
    if (result.length >= maxItems) break;
  }
  return result;
}

function uniqueStrings(value, maxItems, maxLength) {
  if (!Array.isArray(value)) return [];
  const result = [];
  const seen = new Set();
  for (const item of value) {
    const text = safeHumanText(item, maxLength);
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
    let rejected = false;
    for (const [key, raw] of Object.entries(item)) {
      const safeKey = String(key).replace(/[^A-Za-z0-9_-]/g, '').slice(0, 64);
      if (!safeKey) continue;
      if (typeof raw === 'string') {
        const text = safeHumanText(raw, 1200);
        if (!text && String(raw || '').trim()) { rejected = true; break; }
        clean[safeKey] = text;
      } else if (typeof raw === 'number' && Number.isFinite(raw)) clean[safeKey] = raw;
      else if (typeof raw === 'boolean') clean[safeKey] = raw;
      else if (raw == null) clean[safeKey] = null;
    }
    if (rejected) continue;
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

function sanitizeObject(value, maxBytes = 30_000) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return {};
  const clean = {};
  for (const [key, raw] of Object.entries(value)) {
    const safeKey = String(key).replace(/[^A-Za-z0-9_-]/g, '').slice(0, 64);
    if (!safeKey) continue;
    if (typeof raw === 'string') clean[safeKey] = cleanText(raw, 2000);
    else if (typeof raw === 'number' && Number.isFinite(raw)) clean[safeKey] = raw;
    else if (typeof raw === 'boolean') clean[safeKey] = raw;
    else if (raw == null) clean[safeKey] = null;
  }
  const encoded = JSON.stringify(clean);
  return encoded.length <= maxBytes ? clean : {};
}

function cleanLifecycleState(value) {
  const state = cleanText(value, 40);
  return ['draft','importing','ready','published','failed','archived'].includes(state) ? state : null;
}

function parseJSONObject(value) {
  try {
    const parsed = typeof value === 'string' ? JSON.parse(value || '{}') : value;
    return parsed && typeof parsed === 'object' && !Array.isArray(parsed) ? parsed : {};
  } catch {
    return {};
  }
}

function validImageCategory(value) {
  const category = cleanText(typeof value === 'string' ? value : value?.rawValue, 30);
  return ['exterior','room','bathroom','lobby','restaurant','breakfast','gym','spa','pool','lounge','facility','amenity','view','gallery','other'].includes(category) ? category : null;
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
    'access-control-allow-headers': 'Content-Type,Idempotency-Key,X-Iumrah-Allow-Possible-Duplicate,X-Iumrah-Source,X-Iumrah-Position,X-Iumrah-Cover,X-Iumrah-Category,X-Iumrah-Source-URL,X-Iumrah-Label,X-Iumrah-Room',
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
