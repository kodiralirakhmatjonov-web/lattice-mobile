const JSON_HEADERS = {
  'content-type': 'application/json; charset=utf-8',
  'cache-control': 'no-store'
};

const PUBLIC_CACHE_HEADERS = {
  'cache-control': 'public, max-age=60, s-maxage=300'
};

const CITIES = new Set(['Madinah', 'Makkah', 'Jeddah']);
const CATEGORIES = new Set(['mosque', 'mountain', 'cemetery', 'historical', 'garden', 'beach', 'restaurant', 'picnic', 'museum', 'landmark', 'other']);
const VISIT_TYPES = new Set(['enter', 'stop', 'view', 'pass']);

export async function handleZiyaratAdmin(request, env, url, user) {
  const parts = pathParts(url.pathname, '/api/admin/ziyarats');

  if (parts.length === 0) {
    if (request.method === 'GET') return adminCatalog(env, url);
    if (request.method === 'POST') return createPlace(request, env, user);
    return methodNotAllowed();
  }

  if (parts[0] !== 'places') return json({ ok: false, error: 'NOT_FOUND' }, 404);
  const placeID = safeID(parts[1]);
  if (!placeID) return json({ ok: false, error: 'INVALID_ZIYARAT_ID' }, 400);

  if (parts.length === 2) {
    if (request.method === 'GET') return adminPlace(env, placeID);
    if (request.method === 'PUT' || request.method === 'PATCH') return updatePlace(request, env, placeID, user);
    if (request.method === 'DELETE') return deletePlace(env, placeID);
    return methodNotAllowed();
  }

  if (parts[2] === 'images') {
    if (parts.length === 3 && request.method === 'POST') return uploadPlaceImage(request, env, placeID);
    const imageID = safeID(parts[3]);
    if (!imageID) return json({ ok: false, error: 'INVALID_ZIYARAT_IMAGE_ID' }, 400);
    if (parts.length === 4 && request.method === 'GET') return servePlaceImage(env, placeID, imageID, true);
    if (parts.length === 4 && request.method === 'DELETE') return deletePlaceImage(env, placeID, imageID);
  }

  return methodNotAllowed();
}

export async function handleZiyaratCatalog(request, env, url) {
  const parts = pathParts(url.pathname, '/api/catalog/ziyarats');
  if (parts.length === 0) {
    if (request.method !== 'GET') return methodNotAllowed();
    return publicCatalog(env, url);
  }

  if (parts[0] !== 'places') return json({ ok: false, error: 'NOT_FOUND' }, 404);
  const placeID = safeID(parts[1]);
  if (!placeID) return json({ ok: false, error: 'INVALID_ZIYARAT_ID' }, 400);

  if (parts.length === 2 && request.method === 'GET') return publicPlace(env, placeID);
  if (parts.length === 4 && parts[2] === 'images' && request.method === 'GET') {
    const imageID = safeID(parts[3]);
    if (!imageID) return new Response('Not Found', { status: 404 });
    return servePlaceImage(env, placeID, imageID, false);
  }
  return methodNotAllowed();
}

async function adminCatalog(env, url) {
  const city = normalizeCity(url.searchParams.get('city'));
  const statement = env.HOTELS_DB.prepare(`
    SELECT * FROM ziyarat_routes
    ${city ? 'WHERE city=?' : ''}
    ORDER BY CASE city WHEN 'Madinah' THEN 0 WHEN 'Makkah' THEN 1 WHEN 'Jeddah' THEN 2 ELSE 9 END, title
  `);
  const routeRows = city ? await statement.bind(city).all() : await statement.all();

  const routes = [];
  for (const route of routeRows.results || []) {
    routes.push(await hydrateRoute(env, route, false));
  }
  return json({ ok: true, routes });
}

async function publicCatalog(env, url) {
  const city = normalizeCity(url.searchParams.get('city')) || 'Madinah';
  const route = await env.HOTELS_DB.prepare(`
    SELECT * FROM ziyarat_routes
    WHERE city=? AND status='published'
    ORDER BY updated_at DESC LIMIT 1
  `).bind(city).first();
  if (!route) return json({ ok: true, route: null }, 200, PUBLIC_CACHE_HEADERS);
  return json({ ok: true, route: await hydrateRoute(env, route, true) }, 200, PUBLIC_CACHE_HEADERS);
}

async function adminPlace(env, placeID) {
  const row = await env.HOTELS_DB.prepare(`
    SELECT p.*, r.city, r.country, r.title AS route_title
    FROM ziyarat_places p JOIN ziyarat_routes r ON r.id=p.route_id
    WHERE p.id=? LIMIT 1
  `).bind(placeID).first();
  if (!row) return json({ ok: false, error: 'ZIYARAT_NOT_FOUND' }, 404);
  return json({ ok: true, place: await mapPlace(env, row, false) });
}

async function publicPlace(env, placeID) {
  const row = await env.HOTELS_DB.prepare(`
    SELECT p.*, r.city, r.country, r.title AS route_title
    FROM ziyarat_places p JOIN ziyarat_routes r ON r.id=p.route_id
    WHERE p.id=? AND p.status='published' AND r.status='published' LIMIT 1
  `).bind(placeID).first();
  if (!row) return json({ ok: false, error: 'ZIYARAT_NOT_FOUND' }, 404);
  return json({ ok: true, place: await mapPlace(env, row, true) }, 200, PUBLIC_CACHE_HEADERS);
}

async function hydrateRoute(env, route, publishedOnly) {
  const rows = await env.HOTELS_DB.prepare(`
    SELECT p.*, ? AS city, ? AS country, ? AS route_title
    FROM ziyarat_places p
    WHERE p.route_id=? ${publishedOnly ? "AND p.status='published'" : ''}
    ORDER BY p.route_order ASC, p.created_at ASC
  `).bind(route.city, route.country, route.title, route.id).all();
  const places = [];
  for (const row of rows.results || []) places.push(await mapPlace(env, row, publishedOnly));
  const stopMinutes = places.reduce((sum, item) => sum + Number(item.durationMinutes || 0), 0);
  const travelMinutes = Math.max(0, places.length - 1) * 18;
  return {
    id: route.id,
    slug: route.slug,
    city: route.city,
    country: route.country,
    title: route.title,
    subtitle: route.subtitle || '',
    transportMode: route.transport_mode || 'car',
    status: route.status,
    estimatedMinutes: stopMinutes + travelMinutes,
    stopCount: places.length,
    places
  };
}

async function mapPlace(env, row, publicMode) {
  const images = await env.HOTELS_DB.prepare(`
    SELECT id, content_type, byte_size, width, height, position
    FROM ziyarat_images WHERE place_id=? ORDER BY position ASC, created_at ASC LIMIT 5
  `).bind(row.id).all();
  return {
    id: row.id,
    routeID: row.route_id,
    slug: row.slug,
    city: row.city,
    country: row.country,
    title: row.title,
    titleArabic: row.title_ar || '',
    category: row.category,
    shortDescription: row.short_description || '',
    longDescription: row.long_description || '',
    interestingFacts: parseStringArray(row.interesting_facts_json),
    visitNotes: row.visit_notes || '',
    visitType: row.visit_type,
    durationMinutes: Number(row.duration_minutes || 0),
    latitude: Number(row.latitude),
    longitude: Number(row.longitude),
    address: row.address || '',
    mapLabel: row.map_label || '',
    routeOrder: Number(row.route_order || 0),
    status: row.status,
    images: (images.results || []).map(image => ({
      id: image.id,
      url: `${publicMode ? '/api/catalog/ziyarats' : '/api/admin/ziyarats'}/places/${encodeURIComponent(row.id)}/images/${encodeURIComponent(image.id)}`,
      position: Number(image.position || 0),
      byteSize: image.byte_size == null ? null : Number(image.byte_size),
      width: image.width == null ? null : Number(image.width),
      height: image.height == null ? null : Number(image.height)
    }))
  };
}

async function createPlace(request, env, user) {
  const payload = await request.json().catch(() => null);
  if (!payload) return json({ ok: false, error: 'INVALID_JSON' }, 400);
  const normalized = normalizePlacePayload(payload, true);
  if (!normalized.ok) return json({ ok: false, error: normalized.error }, 400);
  const value = normalized.value;
  const route = await ensureCityRoute(env, value.city);
  const id = safeID(payload.id) || `ziyarat-${crypto.randomUUID()}`;
  const slug = await uniquePlaceSlug(env, id, value.title);
  const now = new Date().toISOString();
  await env.HOTELS_DB.prepare(`
    INSERT INTO ziyarat_places (
      id,route_id,slug,title,title_ar,category,short_description,long_description,interesting_facts_json,
      visit_notes,visit_type,duration_minutes,latitude,longitude,address,map_label,route_order,status,created_by,created_at,updated_at
    ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
  `).bind(
    id, route.id, slug, value.title, value.titleArabic, value.category, value.shortDescription,
    value.longDescription, JSON.stringify(value.interestingFacts), value.visitNotes, value.visitType,
    value.durationMinutes, value.latitude, value.longitude, value.address, value.mapLabel,
    value.routeOrder, value.status, cleanText(user?.login, 180), now, now
  ).run();
  return adminPlace(env, id);
}

async function updatePlace(request, env, placeID, user) {
  const existing = await env.HOTELS_DB.prepare(`
    SELECT p.*, r.city FROM ziyarat_places p JOIN ziyarat_routes r ON r.id=p.route_id WHERE p.id=? LIMIT 1
  `).bind(placeID).first();
  if (!existing) return json({ ok: false, error: 'ZIYARAT_NOT_FOUND' }, 404);
  const payload = await request.json().catch(() => null);
  if (!payload) return json({ ok: false, error: 'INVALID_JSON' }, 400);
  const merged = {
    city: payload.city ?? existing.city,
    title: payload.title ?? existing.title,
    titleArabic: payload.titleArabic ?? existing.title_ar,
    category: payload.category ?? existing.category,
    shortDescription: payload.shortDescription ?? existing.short_description,
    longDescription: payload.longDescription ?? existing.long_description,
    interestingFacts: payload.interestingFacts ?? parseStringArray(existing.interesting_facts_json),
    visitNotes: payload.visitNotes ?? existing.visit_notes,
    visitType: payload.visitType ?? existing.visit_type,
    durationMinutes: payload.durationMinutes ?? existing.duration_minutes,
    latitude: payload.latitude ?? existing.latitude,
    longitude: payload.longitude ?? existing.longitude,
    address: payload.address ?? existing.address,
    mapLabel: payload.mapLabel ?? existing.map_label,
    routeOrder: payload.routeOrder ?? existing.route_order,
    status: payload.status ?? existing.status
  };
  const normalized = normalizePlacePayload(merged, true);
  if (!normalized.ok) return json({ ok: false, error: normalized.error }, 400);
  const value = normalized.value;
  const route = await ensureCityRoute(env, value.city);
  const now = new Date().toISOString();
  await env.HOTELS_DB.prepare(`
    UPDATE ziyarat_places SET route_id=?,title=?,title_ar=?,category=?,short_description=?,long_description=?,
      interesting_facts_json=?,visit_notes=?,visit_type=?,duration_minutes=?,latitude=?,longitude=?,address=?,map_label=?,
      route_order=?,status=?,created_by=COALESCE(created_by,?),updated_at=? WHERE id=?
  `).bind(
    route.id, value.title, value.titleArabic, value.category, value.shortDescription, value.longDescription,
    JSON.stringify(value.interestingFacts), value.visitNotes, value.visitType, value.durationMinutes,
    value.latitude, value.longitude, value.address, value.mapLabel, value.routeOrder, value.status,
    cleanText(user?.login, 180), now, placeID
  ).run();
  return adminPlace(env, placeID);
}

async function deletePlace(env, placeID) {
  const images = await env.HOTELS_DB.prepare('SELECT object_key FROM ziyarat_images WHERE place_id=?').bind(placeID).all();
  const result = await env.HOTELS_DB.prepare('DELETE FROM ziyarat_places WHERE id=?').bind(placeID).run();
  if (!result.meta?.changes) return json({ ok: false, error: 'ZIYARAT_NOT_FOUND' }, 404);
  await Promise.allSettled((images.results || []).map(row => env.HOTELS_MEDIA.delete(row.object_key)));
  return json({ ok: true, deletedPlaceID: placeID });
}

async function uploadPlaceImage(request, env, placeID) {
  const place = await env.HOTELS_DB.prepare('SELECT id FROM ziyarat_places WHERE id=? LIMIT 1').bind(placeID).first();
  if (!place) return json({ ok: false, error: 'ZIYARAT_NOT_FOUND' }, 404);
  const count = await env.HOTELS_DB.prepare('SELECT COUNT(*) AS count FROM ziyarat_images WHERE place_id=?').bind(placeID).first();
  if (Number(count?.count || 0) >= 5) return json({ ok: false, error: 'ZIYARAT_IMAGE_LIMIT' }, 409);

  const contentType = (request.headers.get('content-type') || '').split(';')[0].trim().toLowerCase();
  if (!['image/jpeg','image/jpg','image/png','image/webp','image/avif'].includes(contentType)) {
    return json({ ok: false, error: 'UNSUPPORTED_IMAGE_TYPE' }, 415);
  }
  const source = await request.arrayBuffer();
  if (!source.byteLength) return json({ ok: false, error: 'EMPTY_IMAGE' }, 400);
  if (source.byteLength > 12 * 1024 * 1024) return json({ ok: false, error: 'IMAGE_TOO_LARGE' }, 413);

  let transformed;
  try {
    transformed = await optimizeZiyaratImageBytes(env, source, contentType);
  } catch (error) {
    const code = String(error?.message || 'ZIYARAT_IMAGE_OPTIMIZATION_FAILED');
    return json({ ok: false, error: code }, code === 'ZIYARAT_IMAGE_COMPRESSION_UNAVAILABLE' ? 422 : 400);
  }
  const hash = await sha256HexBytes(transformed.bytes);
  const existing = await env.HOTELS_DB.prepare('SELECT id FROM ziyarat_images WHERE place_id=? AND object_key LIKE ? LIMIT 1')
    .bind(placeID, `%${hash.slice(0, 32)}.%`).first();
  if (existing?.id) return json({ ok: true, deduplicated: true, imageID: existing.id });

  const imageID = crypto.randomUUID();
  const position = boundedInteger(request.headers.get('x-iumrah-position'), 0, 4, Number(count?.count || 0));
  const objectKey = `ziyarats/${placeID}/${hash.slice(0, 32)}.${transformed.extension}`;
  await env.HOTELS_MEDIA.put(objectKey, transformed.bytes, {
    httpMetadata: { contentType: transformed.contentType, cacheControl: 'public, max-age=31536000, immutable' },
    customMetadata: { placeID, transformVersion: transformed.transformVersion }
  });
  const now = new Date().toISOString();
  await env.HOTELS_DB.prepare(`
    INSERT INTO ziyarat_images(id,place_id,object_key,content_type,byte_size,width,height,position,created_at)
    VALUES(?,?,?,?,?,?,?,?,?)
  `).bind(imageID, placeID, objectKey, transformed.contentType, transformed.bytes.byteLength, transformed.width, transformed.height, position, now).run();
  return json({ ok: true, image: { id: imageID, url: publicImagePath(placeID, imageID), position, byteSize: transformed.bytes.byteLength, width: transformed.width, height: transformed.height } }, 201);
}

async function deletePlaceImage(env, placeID, imageID) {
  const row = await env.HOTELS_DB.prepare('SELECT object_key FROM ziyarat_images WHERE place_id=? AND id=? LIMIT 1').bind(placeID, imageID).first();
  if (!row) return json({ ok: false, error: 'ZIYARAT_IMAGE_NOT_FOUND' }, 404);
  await env.HOTELS_DB.prepare('DELETE FROM ziyarat_images WHERE place_id=? AND id=?').bind(placeID, imageID).run();
  await env.HOTELS_MEDIA.delete(row.object_key).catch(() => {});
  return json({ ok: true });
}

async function servePlaceImage(env, placeID, imageID, admin) {
  const row = await env.HOTELS_DB.prepare(`
    SELECT i.object_key,i.content_type,p.status AS place_status,r.status AS route_status
    FROM ziyarat_images i
    JOIN ziyarat_places p ON p.id=i.place_id
    JOIN ziyarat_routes r ON r.id=p.route_id
    WHERE i.place_id=? AND i.id=? LIMIT 1
  `).bind(placeID, imageID).first();
  if (!row) return new Response('Not Found', { status: 404 });
  if (!admin && (row.place_status !== 'published' || row.route_status !== 'published')) return new Response('Not Found', { status: 404 });
  const object = await env.HOTELS_MEDIA.get(row.object_key);
  if (!object) return new Response('Not Found', { status: 404 });
  const headers = new Headers();
  object.writeHttpMetadata(headers);
  headers.set('content-type', row.content_type || headers.get('content-type') || 'image/jpeg');
  headers.set('cache-control', admin ? 'private, max-age=60' : 'public, max-age=86400, s-maxage=604800');
  if (object.httpEtag) headers.set('etag', object.httpEtag);
  return new Response(object.body, { headers });
}

async function ensureCityRoute(env, city) {
  let route = await env.HOTELS_DB.prepare('SELECT * FROM ziyarat_routes WHERE city=? ORDER BY created_at ASC LIMIT 1').bind(city).first();
  if (route) return route;
  const id = `${city.toLowerCase()}-main`;
  const title = `${city === 'Madinah' ? 'Medina' : city} Ziyarat`;
  const now = new Date().toISOString();
  await env.HOTELS_DB.prepare(`
    INSERT INTO ziyarat_routes(id,slug,city,country,title,subtitle,transport_mode,status,created_at,updated_at)
    VALUES(?,?,?,?,?,?,?,?,?,?)
  `).bind(id, `${city.toLowerCase()}-ziyarat`, city, 'Saudi Arabia', title, 'Sacred and historic places', 'car', 'published', now, now).run();
  return env.HOTELS_DB.prepare('SELECT * FROM ziyarat_routes WHERE id=?').bind(id).first();
}

function normalizePlacePayload(payload) {
  const city = normalizeCity(payload.city);
  if (!city) return { ok: false, error: 'INVALID_ZIYARAT_CITY' };
  const title = cleanText(payload.title, 180);
  if (!title) return { ok: false, error: 'ZIYARAT_TITLE_REQUIRED' };
  const latitude = Number(payload.latitude);
  const longitude = Number(payload.longitude);
  if (!Number.isFinite(latitude) || latitude < -90 || latitude > 90 || !Number.isFinite(longitude) || longitude < -180 || longitude > 180) {
    return { ok: false, error: 'ZIYARAT_COORDINATES_REQUIRED' };
  }
  const category = CATEGORIES.has(String(payload.category || '').toLowerCase()) ? String(payload.category).toLowerCase() : 'historical';
  const visitType = VISIT_TYPES.has(String(payload.visitType || '').toLowerCase()) ? String(payload.visitType).toLowerCase() : 'stop';
  const status = String(payload.status || '').toLowerCase() === 'published' ? 'published' : 'draft';
  const interestingFacts = Array.isArray(payload.interestingFacts)
    ? payload.interestingFacts.map(value => cleanText(value, 300)).filter(Boolean).slice(0, 8)
    : [];
  return { ok: true, value: {
    city,
    title,
    titleArabic: cleanText(payload.titleArabic, 180) || '',
    category,
    shortDescription: cleanText(payload.shortDescription, 700) || '',
    longDescription: cleanText(payload.longDescription, 8000) || '',
    interestingFacts,
    visitNotes: cleanText(payload.visitNotes, 1200) || '',
    visitType,
    durationMinutes: boundedInteger(payload.durationMinutes, 5, 480, 30),
    latitude,
    longitude,
    address: cleanText(payload.address, 600) || '',
    mapLabel: cleanText(payload.mapLabel, 220) || '',
    routeOrder: boundedInteger(payload.routeOrder, 1, 999, 1),
    status
  }};
}

function normalizeCity(value) {
  const raw = String(value || '').trim().toLowerCase();
  const city = raw === 'medina' || raw === 'madinah' ? 'Madinah' : raw === 'makkah' || raw === 'mecca' ? 'Makkah' : raw === 'jeddah' || raw === 'jidda' ? 'Jeddah' : null;
  return city && CITIES.has(city) ? city : null;
}

async function uniquePlaceSlug(env, placeID, seed) {
  const base = slugify(seed) || `ziyarat-${placeID}`;
  let candidate = base;
  for (let index = 0; index < 20; index += 1) {
    const row = await env.HOTELS_DB.prepare('SELECT id FROM ziyarat_places WHERE slug=? AND id<>? LIMIT 1').bind(candidate, placeID).first();
    if (!row) return candidate;
    candidate = `${base}-${index + 2}`;
  }
  return `${base}-${crypto.randomUUID().slice(0, 8)}`;
}

async function optimizeZiyaratImageBytes(env, sourceBytes, sourceContentType) {
  const primary = { width: 2048, height: 2048, quality: 92, maxBytes: 1_300_000 };
  const fallback = { width: 1800, height: 1800, quality: 88, maxBytes: 1_100_000 };
  if (env.IMAGES) {
    try {
      let result = await runImageTransform(env, sourceBytes, primary, 'cf-webp-ziyarat-hd-v1');
      if (result.bytes.byteLength > primary.maxBytes) result = await runImageTransform(env, sourceBytes, fallback, 'cf-webp-ziyarat-hd-v1');
      if (result.bytes.byteLength <= 1_300_000) return { ...result, contentType: 'image/webp', extension: 'webp' };
    } catch (error) {
      console.warn('ZIYARAT_IMAGE_TRANSFORM_FALLBACK', String(error?.message || error));
    }
  }
  if (sourceBytes.byteLength > 1_300_000) throw new Error('ZIYARAT_IMAGE_COMPRESSION_UNAVAILABLE');
  const normalized = sourceContentType === 'image/jpg' ? 'image/jpeg' : sourceContentType;
  const extension = normalized === 'image/png' ? 'png' : normalized === 'image/webp' ? 'webp' : normalized === 'image/avif' ? 'avif' : 'jpg';
  return { bytes: sourceBytes, width: null, height: null, transformVersion: 'client-hd-fallback-v1', contentType: normalized, extension };
}

async function runImageTransform(env, sourceBytes, profile, transformVersion) {
  const response = (await env.IMAGES
    .input(new Blob([sourceBytes]).stream())
    .transform({ width: profile.width, height: profile.height, fit: 'scale-down' })
    .output({ format: 'image/webp', quality: profile.quality, anim: false })).response();
  if (!response.ok) throw new Error(`ZIYARAT_IMAGE_TRANSFORM_HTTP_${response.status}`);
  const bytes = await response.arrayBuffer();
  if (!bytes.byteLength) throw new Error('ZIYARAT_IMAGE_TRANSFORM_EMPTY');
  const info = await env.IMAGES.info(new Blob([bytes], { type: 'image/webp' }).stream()).catch(() => null);
  return { bytes, width: nullableInteger(info?.width, 1, 20000), height: nullableInteger(info?.height, 1, 20000), transformVersion };
}

function publicImagePath(placeID, imageID) {
  return `/api/catalog/ziyarats/places/${encodeURIComponent(placeID)}/images/${encodeURIComponent(imageID)}`;
}

function parseStringArray(value) {
  try {
    const parsed = JSON.parse(String(value || '[]'));
    return Array.isArray(parsed) ? parsed.map(x => String(x)).filter(Boolean).slice(0, 8) : [];
  } catch { return []; }
}

async function sha256HexBytes(value) {
  const bytes = value instanceof ArrayBuffer ? value : new Uint8Array(value).buffer;
  const digest = await crypto.subtle.digest('SHA-256', bytes);
  return [...new Uint8Array(digest)].map(x => x.toString(16).padStart(2, '0')).join('');
}

function slugify(value) {
  return String(value || '').normalize('NFKD').toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 90);
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
  return text ? text.slice(0, maxLength) : null;
}

function boundedInteger(value, min, max, fallback) {
  const number = Number(value);
  if (!Number.isFinite(number)) return fallback;
  return Math.max(min, Math.min(max, Math.trunc(number)));
}

function nullableInteger(value, min, max) {
  const number = Number(value);
  if (!Number.isFinite(number)) return null;
  return Math.max(min, Math.min(max, Math.trunc(number)));
}

function methodNotAllowed() { return json({ ok: false, error: 'METHOD_NOT_ALLOWED' }, 405); }

function json(value, status = 200, extraHeaders = {}) {
  return new Response(JSON.stringify(value), { status, headers: { ...JSON_HEADERS, ...extraHeaders } });
}
