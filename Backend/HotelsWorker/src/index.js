import { WorkflowEntrypoint } from 'cloudflare:workers';
import {
  HOTEL_PRICE_TTL_MS,
  HOTEL_PRICE_RETRY_MS,
  buildHotelPriceProbeURLs,
  quoteContextFromProbeURL,
  extractHotelPriceFromHTML
} from './hotel-price.js';

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
        const registrationPath = url.pathname.replace(/\/+$/, '') === '/api/admin/hotels/security/sessions/register'
          && request.method === 'POST';
        const staff = await requireStaff(request, env, { allowSessionRegistration: registrationPath });
        if (!staff.ok) return staff.response;
        return withCors(await handleAdmin(request, env, url, staff.user, staff.businessSession), request);
      }

      if (url.pathname.startsWith('/api/catalog/hotels')) {
        return withCors(await handleCatalog(request, env, url), request);
      }

      return json({ ok: false, error: 'NOT_FOUND' }, 404);
    } catch (error) {
      console.error('HOTELS_API_UNHANDLED', error);
      return json({ ok: false, error: 'INTERNAL_ERROR' }, 500);
    }
  },

  async scheduled(_controller, env, ctx) {
    ctx.waitUntil(runHotelPriceScheduler(env));
  }
};

async function handleAdmin(request, env, url, user, businessSession = null) {
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
    return handleBusinessPush(request, env, parts.slice(1), user, businessSession);
  }

  if (parts[0] === 'security') {
    return handleBusinessSecurity(request, env, parts.slice(1), user, businessSession);
  }

  if (parts[0] === 'operations') {
    return handleBusinessOperations(request, env, url, parts.slice(1), user);
  }

  const hotelID = safeID(parts[0]);
  if (!hotelID) return json({ ok: false, error: 'INVALID_HOTEL_ID' }, 400);

  if (parts.length === 1) {
    if (request.method === 'GET') return hotelDetail(env, hotelID, true, url);
    if (request.method === 'DELETE') return deleteHotel(env, hotelID);
    return methodNotAllowed();
  }

  if (parts.length === 2 && parts[1] === 'price') {
    if (request.method !== 'GET') return methodNotAllowed();
    return hotelPriceDetail(env, hotelID);
  }

  if (parts.length === 3 && parts[1] === 'price' && parts[2] === 'refresh') {
    if (request.method !== 'POST') return methodNotAllowed();
    return refreshHotelPriceResponse(env, hotelID);
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
  const bookingID = cleanText(parts[0], 180);
  if (!bookingID) return json({ ok: false, error: 'INVALID_BOOKING_ID' }, 400);
  if (parts.length === 1 && request.method === 'GET') return chatMessages(env, bookingID, true);
  if (parts.length === 2 && parts[1] === 'messages') {
    if (request.method === 'GET') return chatMessages(env, bookingID, true);
    if (request.method === 'POST') return sendChatMessage(request, env, bookingID, user);
  }
  if (parts.length === 2 && parts[1] === 'attachments' && request.method === 'POST') {
    return sendChatAttachment(request, env, bookingID, user, true);
  }
  if (parts.length === 3 && parts[1] === 'media' && request.method === 'GET') {
    return serveChatAttachment(env, bookingID, parts[2]);
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

async function chatMessages(env, bookingID, admin = true) {
  const result = await env.HOTELS_DB.prepare(`
    SELECT id, booking_id, sender_type, sender_name, body, created_at, read_by_staff, message_type, attachment_id
    FROM business_chat_messages WHERE booking_id=? ORDER BY created_at ASC LIMIT 500
  `).bind(bookingID).all();
  return json({
    ok: true,
    bookingID,
    messages: (result.results || []).map(row => mapChatMessage(row, admin))
  });
}

function mapChatMessage(row, admin = true) {
  const attachmentID = row.attachment_id || null;
  return {
    id: row.id,
    bookingID: row.booking_id,
    senderType: row.sender_type,
    senderName: row.sender_name || null,
    body: row.body || '',
    messageType: row.message_type || 'text',
    attachmentID,
    attachmentURL: attachmentID ? (admin ? `/api/admin/hotels/chats/${encodeURIComponent(row.booking_id)}/media/${encodeURIComponent(attachmentID)}` : `/api/catalog/hotels/client/chats/${encodeURIComponent(row.booking_id)}/media/${encodeURIComponent(attachmentID)}`) : null,
    createdAt: row.created_at,
    readByStaff: Number(row.read_by_staff || 0) === 1
  };
}

async function staffDisplayName(env, user) {
  const login = cleanText(user?.login, 180);
  if (login) {
    const row = await env.HOTELS_DB.prepare('SELECT first_name, last_name, role_title FROM team_members WHERE staff_login=? LIMIT 1').bind(login).first().catch(() => null);
    if (row) {
      const name = [row.first_name, row.last_name].filter(Boolean).join(' ').trim();
      if (name) return safeHumanText(name, 160) || 'iumrah Business';
      if (row.role_title) return safeHumanText(row.role_title, 160) || 'iumrah Business';
    }
  }
  return safeHumanText(user?.displayName || user?.login || 'iumrah Business', 160) || 'iumrah Business';
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
  const senderName = await staffDisplayName(env, user);
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
  await sendClientPush(env, bookingID, 'iumrah Care', body.slice(0, 180), { type: 'chat_message', bookingID }).catch(() => {});
  return chatMessageDetail(env, id, 201);
}

async function chatMessageDetail(env, id, status = 200, admin = true) {
  const row = await env.HOTELS_DB.prepare('SELECT * FROM business_chat_messages WHERE id=?').bind(id).first();
  if (!row) return json({ ok: false, error: 'MESSAGE_NOT_FOUND' }, 404);
  return json({ ok: true, message: mapChatMessage(row, admin) }, status);
}

async function handleBusinessPush(request, env, parts, user, businessSession = null) {
  if (parts.length === 1 && parts[0] === 'devices' && request.method === 'POST') {
    const payload = await request.json().catch(() => null);
    const token = cleanText(payload?.deviceToken, 256)?.toLowerCase();
    if (!token || !/^[0-9a-f]{32,256}$/.test(token)) return json({ ok: false, error: 'INVALID_DEVICE_TOKEN' }, 400);
    const environment = payload?.environment === 'development' ? 'development' : 'production';
    const now = new Date().toISOString();
    await env.HOTELS_DB.prepare(`
      INSERT INTO business_push_devices (device_token, staff_login, environment, app_bundle_id, enabled, created_at, updated_at, last_error, installation_id)
      VALUES (?, ?, ?, 'com.iumrah.business', 1, ?, ?, NULL, ?)
      ON CONFLICT(device_token) DO UPDATE SET staff_login=excluded.staff_login, environment=excluded.environment,
        app_bundle_id=excluded.app_bundle_id, enabled=1, updated_at=excluded.updated_at, last_error=NULL,
        installation_id=excluded.installation_id
    `).bind(token, cleanText(user?.login, 180), environment, now, now, businessSession?.installation_id || null).run();
    return json({ ok: true, ready: apnsConfigured(env) });
  }
  if (parts.length === 1 && parts[0] === 'status' && request.method === 'GET') {
    const row = await env.HOTELS_DB.prepare('SELECT COUNT(*) AS count FROM business_push_devices WHERE enabled=1').first();
    return json({ ok: true, configured: apnsConfigured(env), devices: Number(row?.count || 0) });
  }
  return methodNotAllowed();
}

const BUSINESS_SESSION_TTL_MS = 180 * 24 * 60 * 60_000;

function businessSessionToken(request) {
  return cleanText(request.headers.get('x-iumrah-business-session'), 512);
}

function businessStaffLogin(user) {
  return cleanText(user?.login, 180)?.toLowerCase() || '';
}

function businessRequestLocation(request) {
  return {
    city: safeHumanText(request.cf?.city || '', 120) || '',
    countryCode: cleanText(request.cf?.country, 8)?.toUpperCase() || ''
  };
}

function businessDevicePayload(payload, request) {
  const location = businessRequestLocation(request);
  return {
    installationID: cleanText(payload?.installationID, 128),
    installationSecret: cleanText(payload?.installationSecret, 256),
    deviceName: safeHumanText(payload?.deviceName || '', 180) || '',
    deviceModel: safeHumanText(payload?.deviceModel || '', 120) || '',
    hardwareIdentifier: cleanText(payload?.hardwareIdentifier, 120) || '',
    platform: cleanText(payload?.platform, 32)?.toLowerCase() || 'ios',
    osName: safeHumanText(payload?.osName || 'iOS', 40) || 'iOS',
    osVersion: cleanText(payload?.osVersion, 40) || '',
    appVersion: cleanText(payload?.appVersion, 40) || '',
    appBuild: cleanText(payload?.appBuild, 40) || '',
    locale: cleanText(payload?.locale, 40) || '',
    timeZone: cleanText(payload?.timeZone, 80) || '',
    city: location.city,
    countryCode: location.countryCode
  };
}

function validBusinessInstallation(value) {
  return typeof value === 'string' && /^[A-Za-z0-9._:-]{16,128}$/.test(value);
}

function validBusinessInstallationSecret(value) {
  return typeof value === 'string' && /^[A-Za-z0-9_-]{32,256}$/.test(value);
}

function mapBusinessSession(row, currentSessionID = '') {
  const isPrimary = Number(row.is_primary || 0) === 1;
  const trusted = Number(row.trusted || 0) === 1;
  return {
    id: row.session_id,
    deviceID: row.device_id,
    deviceName: row.device_name || '',
    deviceModel: row.device_model || '',
    hardwareIdentifier: row.hardware_identifier || '',
    platform: row.platform || 'ios',
    osName: row.os_name || 'iOS',
    osVersion: row.os_version || '',
    appVersion: row.app_version || '',
    appBuild: row.app_build || '',
    locale: row.locale || '',
    timeZone: row.time_zone || '',
    city: row.city || '',
    countryCode: row.country_code || '',
    isCurrent: row.session_id === currentSessionID,
    isPrimary,
    trusted,
    trustLevel: isPrimary ? 'primary' : (trusted ? 'trusted' : 'new'),
    createdAt: row.session_created_at,
    lastActiveAt: row.session_last_seen_at,
    expiresAt: row.expires_at
  };
}

const BUSINESS_SESSION_SELECT = `
  SELECT
    s.id AS session_id,
    s.staff_login,
    s.device_id,
    s.created_at AS session_created_at,
    s.last_seen_at AS session_last_seen_at,
    s.expires_at,
    d.installation_id,
    d.device_name,
    d.device_model,
    d.hardware_identifier,
    d.platform,
    d.os_name,
    d.os_version,
    d.app_version,
    d.app_build,
    d.locale,
    d.time_zone,
    d.city,
    d.country_code,
    d.is_primary,
    d.trusted
  FROM business_staff_sessions s
  JOIN business_security_devices d ON d.id=s.device_id
`;

async function businessSessionForRequest(request, env, user) {
  const token = businessSessionToken(request);
  if (!token) return null;
  const tokenHash = await sha256Hex(token);
  const staffLogin = businessStaffLogin(user);
  const now = new Date();
  const row = await env.HOTELS_DB.prepare(`${BUSINESS_SESSION_SELECT}
    WHERE s.token_hash=? AND s.staff_login=? AND s.revoked_at IS NULL AND s.expires_at>?
      AND d.revoked_at IS NULL
    LIMIT 1
  `).bind(tokenHash, staffLogin, now.toISOString()).first();
  if (!row) return null;

  const previous = Date.parse(row.session_last_seen_at || '');
  if (!Number.isFinite(previous) || now.getTime() - previous >= 60_000) {
    const seenAt = now.toISOString();
    const expiresAt = new Date(now.getTime() + BUSINESS_SESSION_TTL_MS).toISOString();
    const location = businessRequestLocation(request);
    await env.HOTELS_DB.batch([
      env.HOTELS_DB.prepare('UPDATE business_staff_sessions SET last_seen_at=?, expires_at=? WHERE id=? AND revoked_at IS NULL')
        .bind(seenAt, expiresAt, row.session_id),
      env.HOTELS_DB.prepare('UPDATE business_security_devices SET last_seen_at=?, city=?, country_code=? WHERE id=? AND revoked_at IS NULL')
        .bind(seenAt, location.city, location.countryCode, row.device_id)
    ]).catch(() => {});
    row.session_last_seen_at = seenAt;
    row.expires_at = expiresAt;
    row.city = location.city || row.city;
    row.country_code = location.countryCode || row.country_code;
  }
  return { ...row, tokenHash };
}

async function requireBusinessSession(request, env, user) {
  const session = await businessSessionForRequest(request, env, user);
  if (session) return { ok: true, session };

  const staffLogin = businessStaffLogin(user);
  const row = await env.HOTELS_DB.prepare(`
    SELECT COUNT(*) AS count FROM business_security_devices
    WHERE staff_login=? AND revoked_at IS NULL
  `).bind(staffLogin).first().catch(() => null);

  // Backward-compatible rollout: the old application continues to work until
  // this account registers its first protected device. From that moment onward,
  // every admin call requires an active per-device credential.
  if (Number(row?.count || 0) === 0) return { ok: true, session: null, legacy: true };
  return { ok: false, response: json({ ok: false, error: 'BUSINESS_SESSION_REQUIRED' }, 401) };
}

async function registerBusinessSession(request, env, user) {
  const payload = await request.json().catch(() => null);
  if (!payload) return json({ ok: false, error: 'INVALID_JSON' }, 400);
  const value = businessDevicePayload(payload, request);
  if (!validBusinessInstallation(value.installationID) || !validBusinessInstallationSecret(value.installationSecret)) {
    return json({ ok: false, error: 'INVALID_DEVICE_IDENTITY' }, 400);
  }

  const staffLogin = businessStaffLogin(user);
  if (!staffLogin) return json({ ok: false, error: 'INVALID_STAFF_SESSION' }, 401);
  const now = new Date();
  const nowISO = now.toISOString();
  const secretHash = await sha256Hex(value.installationSecret);
  let device = await env.HOTELS_DB.prepare(`
    SELECT * FROM business_security_devices WHERE staff_login=? AND installation_id=? LIMIT 1
  `).bind(staffLogin, value.installationID).first();
  let createdDevice = false;

  if (device) {
    if (!constantTimeEqual(device.installation_secret_hash, secretHash)) {
      return json({ ok: false, error: 'DEVICE_PROOF_INVALID' }, 403);
    }
    if (device.revoked_at) return json({ ok: false, error: 'DEVICE_BLOCKED' }, 403);
    await env.HOTELS_DB.prepare(`
      UPDATE business_security_devices SET
        device_name=?, device_model=?, hardware_identifier=?, platform=?, os_name=?, os_version=?,
        app_version=?, app_build=?, locale=?, time_zone=?, city=?, country_code=?, last_seen_at=?
      WHERE id=?
    `).bind(
      value.deviceName, value.deviceModel, value.hardwareIdentifier, value.platform, value.osName,
      value.osVersion, value.appVersion, value.appBuild, value.locale, value.timeZone,
      value.city, value.countryCode, nowISO, device.id
    ).run();
  } else {
    const primary = await env.HOTELS_DB.prepare(`
      SELECT id FROM business_security_devices WHERE staff_login=? AND is_primary=1 AND revoked_at IS NULL LIMIT 1
    `).bind(staffLogin).first();
    let isPrimary = primary ? 0 : 1;
    const deviceID = crypto.randomUUID();
    const insert = primaryValue => env.HOTELS_DB.prepare(`
      INSERT INTO business_security_devices (
        id, staff_login, installation_id, installation_secret_hash, device_name, device_model,
        hardware_identifier, platform, os_name, os_version, app_version, app_build, locale,
        time_zone, city, country_code, is_primary, trusted, created_at, last_seen_at
      ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
    `).bind(
      deviceID, staffLogin, value.installationID, secretHash, value.deviceName, value.deviceModel,
      value.hardwareIdentifier, value.platform, value.osName, value.osVersion, value.appVersion,
      value.appBuild, value.locale, value.timeZone, value.city, value.countryCode,
      primaryValue, primaryValue, nowISO, nowISO
    ).run();
    try {
      await insert(isPrimary);
    } catch (error) {
      if (!isPrimary) throw error;
      isPrimary = 0;
      await insert(0);
    }
    device = await env.HOTELS_DB.prepare('SELECT * FROM business_security_devices WHERE id=?').bind(deviceID).first();
    createdDevice = true;
  }

  const presented = await businessSessionForRequest(request, env, user);
  if (presented) {
    if (presented.device_id !== device.id) return json({ ok: false, error: 'SESSION_DEVICE_MISMATCH' }, 403);
    const current = mapBusinessSession(presented, presented.session_id);
    return json({ ok: true, sessionToken: null, currentSession: current });
  }

  await env.HOTELS_DB.prepare(`
    UPDATE business_staff_sessions SET revoked_at=?, revocation_reason='replaced'
    WHERE device_id=? AND revoked_at IS NULL
  `).bind(nowISO, device.id).run();

  const token = randomToken(32);
  const tokenHash = await sha256Hex(token);
  const sessionID = crypto.randomUUID();
  const expiresAt = new Date(now.getTime() + BUSINESS_SESSION_TTL_MS).toISOString();
  await env.HOTELS_DB.prepare(`
    INSERT INTO business_staff_sessions (id,staff_login,device_id,token_hash,created_at,last_seen_at,expires_at)
    VALUES (?,?,?,?,?,?,?)
  `).bind(sessionID, staffLogin, device.id, tokenHash, nowISO, nowISO, expiresAt).run();

  const row = await env.HOTELS_DB.prepare(`${BUSINESS_SESSION_SELECT} WHERE s.id=? LIMIT 1`).bind(sessionID).first();
  if (createdDevice && Number(device.is_primary || 0) !== 1) {
    const location = [value.city, value.countryCode].filter(Boolean).join(', ');
    const label = value.deviceModel || value.deviceName || 'Новое устройство';
    await sendBusinessSecurityPush(
      env,
      staffLogin,
      value.installationID,
      'Новый вход в iumrah Business',
      location ? `${label} · ${location}` : label,
      { type: 'security_new_session', sessionID }
    ).catch(error => console.error('SECURITY_PUSH_FAILED', error));
  }
  return json({ ok: true, sessionToken: token, currentSession: mapBusinessSession(row, sessionID) }, 201);
}

async function listBusinessSessions(env, user, currentSession) {
  const now = new Date().toISOString();
  const rows = await env.HOTELS_DB.prepare(`${BUSINESS_SESSION_SELECT}
    WHERE s.staff_login=? AND s.revoked_at IS NULL AND s.expires_at>? AND d.revoked_at IS NULL
    ORDER BY d.is_primary DESC, (s.id=?) DESC, s.last_seen_at DESC
  `).bind(businessStaffLogin(user), now, currentSession.session_id).all();
  return json({
    ok: true,
    currentSessionID: currentSession.session_id,
    sessions: (rows.results || []).map(row => mapBusinessSession(row, currentSession.session_id)),
    inactivityDays: 180,
    policy: 'primary_only_revocation'
  });
}

async function revokeBusinessSession(env, user, currentSession, targetSessionID) {
  const staffLogin = businessStaffLogin(user);
  const target = await env.HOTELS_DB.prepare(`${BUSINESS_SESSION_SELECT}
    WHERE s.id=? AND s.staff_login=? AND s.revoked_at IS NULL AND d.revoked_at IS NULL LIMIT 1
  `).bind(targetSessionID, staffLogin).first();
  if (!target) return json({ ok: false, error: 'SESSION_NOT_FOUND' }, 404);
  const now = new Date().toISOString();

  if (target.session_id === currentSession.session_id) {
    await env.HOTELS_DB.prepare(`
      UPDATE business_staff_sessions SET revoked_at=?, revoked_by_session_id=?, revocation_reason='self_logout'
      WHERE id=? AND revoked_at IS NULL
    `).bind(now, currentSession.session_id, target.session_id).run();
    return json({ ok: true, signedOut: true });
  }

  if (Number(currentSession.is_primary || 0) !== 1) {
    return json({ ok: false, error: 'PRIMARY_SESSION_REQUIRED' }, 403);
  }
  if (Number(target.is_primary || 0) === 1) {
    return json({ ok: false, error: 'PRIMARY_SESSION_PROTECTED' }, 403);
  }

  await env.HOTELS_DB.batch([
    env.HOTELS_DB.prepare(`
      UPDATE business_staff_sessions SET revoked_at=?, revoked_by_session_id=?, revocation_reason='revoked_by_primary'
      WHERE id=? AND revoked_at IS NULL
    `).bind(now, currentSession.session_id, target.session_id),
    env.HOTELS_DB.prepare(`
      UPDATE business_security_devices SET revoked_at=?, revoked_by_device_id=?
      WHERE id=? AND is_primary=0 AND revoked_at IS NULL
    `).bind(now, currentSession.device_id, target.device_id)
  ]);
  return json({ ok: true, signedOut: false });
}

async function revokeOtherBusinessSessions(env, user, currentSession) {
  if (Number(currentSession.is_primary || 0) !== 1) {
    return json({ ok: false, error: 'PRIMARY_SESSION_REQUIRED' }, 403);
  }
  const staffLogin = businessStaffLogin(user);
  const now = new Date().toISOString();
  await env.HOTELS_DB.batch([
    env.HOTELS_DB.prepare(`
      UPDATE business_staff_sessions SET revoked_at=?, revoked_by_session_id=?, revocation_reason='revoked_by_primary'
      WHERE staff_login=? AND id<>? AND revoked_at IS NULL
    `).bind(now, currentSession.session_id, staffLogin, currentSession.session_id),
    env.HOTELS_DB.prepare(`
      UPDATE business_security_devices SET revoked_at=?, revoked_by_device_id=?
      WHERE staff_login=? AND id<>? AND is_primary=0 AND revoked_at IS NULL
    `).bind(now, currentSession.device_id, staffLogin, currentSession.device_id)
  ]);
  return json({ ok: true });
}

async function approveBusinessDevice(env, user, currentSession, targetSessionID) {
  if (Number(currentSession.is_primary || 0) !== 1) {
    return json({ ok: false, error: 'PRIMARY_SESSION_REQUIRED' }, 403);
  }
  const target = await env.HOTELS_DB.prepare(`${BUSINESS_SESSION_SELECT}
    WHERE s.id=? AND s.staff_login=? AND s.revoked_at IS NULL AND d.revoked_at IS NULL LIMIT 1
  `).bind(targetSessionID, businessStaffLogin(user)).first();
  if (!target) return json({ ok: false, error: 'SESSION_NOT_FOUND' }, 404);
  if (Number(target.is_primary || 0) === 1) return json({ ok: true });
  const now = new Date().toISOString();
  await env.HOTELS_DB.prepare(`
    UPDATE business_security_devices SET trusted=1, approved_at=?, approved_by_device_id=?
    WHERE id=? AND revoked_at IS NULL
  `).bind(now, currentSession.device_id, target.device_id).run();
  return json({ ok: true });
}

async function handleBusinessSecurity(request, env, parts, user, currentSession) {
  if (parts[0] !== 'sessions') return json({ ok: false, error: 'NOT_FOUND' }, 404);
  if (parts.length === 2 && parts[1] === 'register' && request.method === 'POST') {
    return registerBusinessSession(request, env, user);
  }
  if (!currentSession) return json({ ok: false, error: 'BUSINESS_SESSION_REQUIRED' }, 401);
  if (parts.length === 1 && request.method === 'GET') return listBusinessSessions(env, user, currentSession);
  if (parts.length === 2 && parts[1] === 'current' && request.method === 'DELETE') {
    return revokeBusinessSession(env, user, currentSession, currentSession.session_id);
  }
  if (parts.length === 2 && parts[1] === 'others' && request.method === 'DELETE') {
    return revokeOtherBusinessSessions(env, user, currentSession);
  }
  const sessionID = safeID(parts[1]);
  if (!sessionID) return json({ ok: false, error: 'INVALID_SESSION_ID' }, 400);
  if (parts.length === 2 && request.method === 'DELETE') {
    return revokeBusinessSession(env, user, currentSession, sessionID);
  }
  if (parts.length === 3 && parts[2] === 'approve' && request.method === 'POST') {
    return approveBusinessDevice(env, user, currentSession, sessionID);
  }
  return methodNotAllowed();
}

async function sendBusinessSecurityPush(env, staffLogin, excludedInstallationID, title, body, data = {}) {
  if (!apnsConfigured(env)) return { ok: false, skipped: 'APNS_NOT_CONFIGURED' };
  const devices = await env.HOTELS_DB.prepare(`
    SELECT device_token, environment, COALESCE(NULLIF(app_bundle_id,''), 'com.iumrah.business') AS app_bundle_id
    FROM business_push_devices
    WHERE enabled=1 AND LOWER(COALESCE(staff_login,''))=?
      AND (installation_id IS NULL OR installation_id<>?)
    LIMIT 50
  `).bind(staffLogin, excludedInstallationID).all();
  return sendAPNsToRows(env, devices.results || [], title, body, data, async (device, result) => {
    const now = new Date().toISOString();
    if (result.ok) {
      await env.HOTELS_DB.prepare('UPDATE business_push_devices SET last_success_at=?, last_error=NULL, updated_at=? WHERE device_token=?')
        .bind(now, now, device.device_token).run().catch(() => {});
    } else if (result.response) {
      await env.HOTELS_DB.prepare('UPDATE business_push_devices SET enabled=?, last_error=?, updated_at=? WHERE device_token=?')
        .bind(result.disable ? 0 : 1, result.error.slice(0, 900), now, device.device_token).run().catch(() => {});
    }
  });
}

function apnsConfigured(env) {
  return !!(env.APNS_PRIVATE_KEY && env.APNS_KEY_ID && env.APPLE_TEAM_ID);
}

async function sendStaffPush(env, title, body, data = {}) {
  if (!apnsConfigured(env)) return { ok: false, skipped: 'APNS_NOT_CONFIGURED' };
  const devices = await env.HOTELS_DB.prepare(`
    SELECT device_token, environment, COALESCE(NULLIF(app_bundle_id,''), 'com.iumrah.business') AS app_bundle_id
    FROM business_push_devices WHERE enabled=1 LIMIT 100
  `).all();
  return sendAPNsToRows(env, devices.results || [], title, body, data, async (device, result) => {
    const now = new Date().toISOString();
    if (result.ok) {
      await env.HOTELS_DB.prepare('UPDATE business_push_devices SET last_success_at=?, last_error=NULL, updated_at=? WHERE device_token=?')
        .bind(now, now, device.device_token).run().catch(() => {});
    } else if (result.response) {
      await env.HOTELS_DB.prepare('UPDATE business_push_devices SET enabled=?, last_error=?, updated_at=? WHERE device_token=?')
        .bind(result.disable ? 0 : 1, result.error.slice(0, 900), now, device.device_token).run().catch(() => {});
    }
  });
}

async function sendClientPush(env, bookingID, title, body, data = {}) {
  if (!apnsConfigured(env)) return { ok: false, skipped: 'APNS_NOT_CONFIGURED' };
  const devices = await env.HOTELS_DB.prepare(`
    SELECT device_token, environment, app_bundle_id, locale
    FROM client_push_subscriptions
    WHERE booking_id=? AND enabled=1
    ORDER BY updated_at DESC LIMIT 50
  `).bind(bookingID).all().catch(() => ({ results: [] }));
  return sendAPNsToRows(env, devices.results || [], title, body, { ...data, bookingID }, async (device, result) => {
    const now = new Date().toISOString();
    if (result.ok) {
      await env.HOTELS_DB.prepare('UPDATE client_push_subscriptions SET last_success_at=?, last_error=NULL, updated_at=? WHERE device_token=? AND booking_id=?')
        .bind(now, now, device.device_token, bookingID).run().catch(() => {});
    } else if (result.response) {
      await env.HOTELS_DB.prepare('UPDATE client_push_subscriptions SET enabled=?, last_error=?, updated_at=? WHERE device_token=? AND booking_id=?')
        .bind(result.disable ? 0 : 1, result.error.slice(0, 900), now, device.device_token, bookingID).run().catch(() => {});
    }
  });
}

async function sendAPNsToRows(env, rows, title, body, data, persistResult) {
  if (!rows.length) return { ok: false, skipped: 'NO_DEVICES' };
  const jwt = await apnsJWT(env);
  let sent = 0;
  for (const device of rows) {
    const base = device.environment === 'development' ? 'https://api.sandbox.push.apple.com' : 'https://api.push.apple.com';
    const topic = cleanText(device.app_bundle_id, 220) || 'com.iumrah.business';
    const response = await fetch(`${base}/3/device/${device.device_token}`, {
      method: 'POST',
      headers: {
        authorization: `bearer ${jwt}`,
        'apns-topic': topic,
        'apns-push-type': 'alert',
        'apns-priority': '10',
        'apns-expiration': '0',
        'content-type': 'application/json'
      },
      body: JSON.stringify({
        aps: {
          alert: { title, body },
          sound: 'default',
          'thread-id': cleanText(data?.bookingID, 180) || 'iumrah'
        },
        ...data
      })
    }).catch(() => null);
    if (response?.ok) {
      sent += 1;
      await persistResult(device, { ok: true, response });
    } else if (response) {
      const text = await response.text().catch(() => '');
      const disable = response.status === 410 || /BadDeviceToken|Unregistered|DeviceTokenNotForTopic/i.test(text);
      await persistResult(device, { ok: false, response, disable, error: `${response.status}:${text}` });
    }
  }
  return { ok: sent > 0, sent, total: rows.length };
}

function clientNotificationCopy(localeRaw, type, value) {
  const locale = String(localeRaw || 'ru').toLowerCase();
  const lang = locale.startsWith('uz-cyrl') ? 'uz-cyrl' : locale.startsWith('uz') ? 'uz' : locale.startsWith('en') ? 'en' : 'ru';
  if (type === 'status') {
    const labels = {
      ru: { availability_check:'Новый пакет создан · Проверка наличия', payment_pending:'Наличие подтверждено · Оплата и данные паломников', booking_confirmed:'Оплачено · Бронирование подтверждено', ready_to_travel:'Документы готовы · Готово к поездке', in_trip:'Паломник в поездке', completed:'Поездка завершена', cancelled:'Отменено' },
      en: { availability_check:'New package created · Availability check', payment_pending:'Availability confirmed · Payment & pilgrim details', booking_confirmed:'Paid · Booking confirmed', ready_to_travel:'Documents ready · Ready to travel', in_trip:'Pilgrim in trip', completed:'Trip completed', cancelled:'Cancelled' },
      uz: { availability_check:'Yangi paket yaratildi · Mavjudlik tekshiruvi', payment_pending:'Mavjudlik tasdiqlandi · To‘lov va ziyoratchi ma’lumotlari', booking_confirmed:'To‘langan · Bron tasdiqlandi', ready_to_travel:'Hujjatlar tayyor · Safarga tayyor', in_trip:'Ziyoratchi safarda', completed:'Safar yakunlandi', cancelled:'Bekor qilindi' },
      'uz-cyrl': { availability_check:'Янги пакет яратилди · Мавжудлик текшируви', payment_pending:'Мавжудлик тасдиқланди · Тўлов ва зиёратчи маълумотлари', booking_confirmed:'Тўланган · Брон тасдиқланди', ready_to_travel:'Ҳужжатлар тайёр · Сафарга тайёр', in_trip:'Зиёратчи сафарда', completed:'Сафар якунланди', cancelled:'Бекор қилинди' }
    };
    const titles = { ru:'Статус поездки обновлён', en:'Trip status updated', uz:'Safar holati yangilandi', 'uz-cyrl':'Сафар ҳолати янгиланди' };
    return { title: titles[lang], body: labels[lang][value] || String(value || '') };
  }
  return { title: 'iumrah Care', body: String(value || '') };
}

async function sendClientStatusPush(env, bookingID, status) {
  if (!apnsConfigured(env)) return { ok: false, skipped: 'APNS_NOT_CONFIGURED' };
  const devices = await env.HOTELS_DB.prepare(`
    SELECT device_token, environment, app_bundle_id, locale
    FROM client_push_subscriptions WHERE booking_id=? AND enabled=1
    ORDER BY updated_at DESC LIMIT 50
  `).bind(bookingID).all().catch(() => ({ results: [] }));
  const groups = new Map();
  for (const device of devices.results || []) {
    const copy = clientNotificationCopy(device.locale, 'status', status);
    const key = `${copy.title}\n${copy.body}`;
    if (!groups.has(key)) groups.set(key, { copy, rows: [] });
    groups.get(key).rows.push(device);
  }
  let sent = 0;
  let total = 0;
  for (const { copy, rows } of groups.values()) {
    const result = await sendAPNsToRows(env, rows, copy.title, copy.body, { type: 'booking_status', bookingID, status }, async (device, delivery) => {
      const now = new Date().toISOString();
      if (delivery.ok) {
        await env.HOTELS_DB.prepare('UPDATE client_push_subscriptions SET last_success_at=?, last_error=NULL, updated_at=? WHERE device_token=? AND booking_id=?')
          .bind(now, now, device.device_token, bookingID).run().catch(() => {});
      } else if (delivery.response) {
        await env.HOTELS_DB.prepare('UPDATE client_push_subscriptions SET enabled=?, last_error=?, updated_at=? WHERE device_token=? AND booking_id=?')
          .bind(delivery.disable ? 0 : 1, delivery.error.slice(0, 900), now, device.device_token, bookingID).run().catch(() => {});
      }
    });
    sent += Number(result.sent || 0);
    total += Number(result.total || 0);
  }
  return { ok: sent > 0, sent, total };
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
  const normalized = String(pem || '').replace(/\\n/g, '\n');
  const base64 = normalized.replace(/-----BEGIN PRIVATE KEY-----|-----END PRIVATE KEY-----|\s+/g, '');
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

  if (parts[0] === 'team') {
    if (request.method !== 'GET') return methodNotAllowed();
    return publicTeam(env, parts.slice(1));
  }

  if (parts.length === 1 && parts[0] === 'primary') {
    if (request.method !== 'GET') return methodNotAllowed();
    return publicPrimaryHotels(env, url);
  }

  if (parts[0] === 'client') {
    return handleClientOperations(request, env, parts.slice(1));
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


const TRIP_STATUSES = new Set(['availability_check','payment_pending','booking_confirmed','ready_to_travel','in_trip','completed','cancelled']);
const TRIP_TRANSITIONS = {
  availability_check: new Set(['availability_check','payment_pending','cancelled']),
  payment_pending: new Set(['payment_pending','availability_check','booking_confirmed','cancelled']),
  booking_confirmed: new Set(['booking_confirmed','payment_pending','ready_to_travel','cancelled']),
  ready_to_travel: new Set(['ready_to_travel','booking_confirmed','in_trip','cancelled']),
  in_trip: new Set(['in_trip','completed','cancelled']),
  completed: new Set(['completed']),
  cancelled: new Set(['cancelled'])
};

async function handleBusinessOperations(request, env, url, parts, user) {
  if (parts.length === 1 && parts[0] === 'ignav-usage') {
    if (request.method === 'GET') return businessIgnavUsage(env);
    return methodNotAllowed();
  }

  if (parts.length === 1 && parts[0] === 'me') {
    if (request.method === 'GET') return businessProfileMe(env, user);
    if (request.method === 'PUT') return saveBusinessProfileMe(request, env, user);
    return methodNotAllowed();
  }

  if (parts[0] === 'team') {
    if (parts.length === 1 && request.method === 'GET') return adminTeam(env);
    if (parts.length === 1 && request.method === 'POST') return createTeamMember(request, env);
    const memberID = safeID(parts[1]);
    if (!memberID) return json({ ok: false, error: 'INVALID_TEAM_MEMBER_ID' }, 400);
    if (parts.length === 2 && request.method === 'GET') return adminTeamMember(env, memberID);
    if (parts.length === 2 && request.method === 'PUT') return updateTeamMember(request, env, memberID);
    if (parts.length === 2 && request.method === 'DELETE') return deleteTeamMember(env, memberID);
    return methodNotAllowed();
  }

  if (parts[0] === 'flight-verify') {
    if (parts.length !== 1 || request.method !== 'POST') return methodNotAllowed();
    return verifyBusinessFlight(request, env);
  }

  if (parts[0] === 'notifications') {
    if (parts.length === 1 && request.method === 'GET') return listClientSystemNotifications(env);
    if (parts.length === 1 && request.method === 'POST') return createClientSystemNotification(request, env, user);
    if (parts.length === 2 && parts[1] === 'audience' && request.method === 'GET') return clientNotificationAudience(env);
    return methodNotAllowed();
  }

  if (parts[0] === 'bookings') {
    if (parts.length === 1 && request.method === 'GET') return operationsBookings(request, env);
    const bookingID = cleanText(parts[1], 180);
    if (!bookingID) return json({ ok: false, error: 'INVALID_BOOKING_ID' }, 400);
    if (parts.length === 2 && request.method === 'GET') return operationsBookingDetail(request, env, bookingID);
    if (parts.length === 2 && request.method === 'PATCH') return updateOperationsBooking(request, env, bookingID, user);
    if (parts.length === 2 && request.method === 'DELETE') return deleteOperationsBooking(request, env, bookingID, user);
    if (parts.length === 3 && parts[2] === 'itinerary') {
      if (request.method === 'GET') return bookingItineraryDetail(env, bookingID);
      if (request.method === 'PUT') return saveBookingItinerary(request, env, bookingID);
      return methodNotAllowed();
    }
    if (parts.length === 3 && parts[2] === 'pricing') {
      if (request.method === 'GET') return bookingPricingOverrideDetail(request, env, bookingID);
      if (request.method === 'PUT') return saveBookingPricingOverride(request, env, bookingID, user);
      return methodNotAllowed();
    }
    if (parts.length === 3 && parts[2] === 'assignments' && request.method === 'PATCH') return updateBookingAssignments(request, env, bookingID);
    if (parts.length === 3 && parts[2] === 'esims') {
      if (request.method === 'GET') return adminBookingEsims(env, bookingID);
      if (request.method === 'POST') return saveBookingEsim(request, env, bookingID, null, user);
      return methodNotAllowed();
    }
    if (parts.length === 4 && parts[2] === 'esims') {
      if (request.method === 'PUT') return saveBookingEsim(request, env, bookingID, parts[3], user);
      if (request.method === 'DELETE') return deleteBookingEsim(env, bookingID, parts[3]);
      return methodNotAllowed();
    }
    if (parts.length === 5 && parts[2] === 'esims' && parts[4] === 'sync' && request.method === 'POST') {
      return syncBookingEsim(request, env, bookingID, parts[3]);
    }
    if (parts.length === 3 && parts[2] === 'payment' && request.method === 'PUT') return saveBookingPaymentInstructions(request, env, bookingID, user);
    if (parts.length === 3 && parts[2] === 'payment-qr' && request.method === 'POST') return uploadBookingPaymeQR(request, env, bookingID, user);
    if (parts.length === 4 && parts[2] === 'receipt' && parts[3] === 'media' && request.method === 'GET') return serveAdminPaymentReceipt(env, bookingID, url.searchParams.get('id'));
    if (parts.length === 5 && parts[2] === 'travelers' && parts[4] === 'passport' && request.method === 'GET') return serveAdminTravelerPassport(env, bookingID, Number(parts[3]));
    if (parts.length === 3 && parts[2] === 'documents' && request.method === 'POST') return uploadBookingTravelDocument(request, env, bookingID, user, url);
    if (parts.length === 4 && parts[2] === 'documents' && request.method === 'GET') return serveAdminTravelDocument(env, bookingID, parts[3]);
    if (parts.length === 4 && parts[2] === 'flights' && request.method === 'PUT') return saveVerifiedBookingFlight(request, env, bookingID, parts[3]);
    if (parts.length === 4 && parts[2] === 'flights' && request.method === 'DELETE') return deleteBookingFlight(env, bookingID, parts[3]);
    return methodNotAllowed();
  }

  if (parts[0] === 'pilgrims') {
    if (parts.length === 1 && request.method === 'GET') return listPilgrims(env, url);
    const publicID = cleanText(parts[1], 80);
    if (!publicID) return json({ ok: false, error: 'INVALID_PILGRIM_ID' }, 400);
    if (parts.length === 2 && request.method === 'GET') return pilgrimDetail(env, publicID);
    return methodNotAllowed();
  }

  if (parts[0] === 'primary-hotels') {
    if (parts.length !== 1) return json({ ok: false, error: 'NOT_FOUND' }, 404);
    if (request.method === 'GET') return adminPrimaryHotels(env, url);
    if (request.method === 'PUT') return savePrimaryHotels(request, env);
    return methodNotAllowed();
  }

  return json({ ok: false, error: 'NOT_FOUND' }, 404);
}


const FLIGHT_DIRECTIONS = new Set(['outbound','return']);

function normalizedFlightNumber(value) {
  const text = String(value || '').toUpperCase().replace(/[^A-Z0-9]/g, '');
  if (!/^[A-Z0-9]{2,4}\d{1,4}[A-Z]?$/.test(text)) return '';
  return text;
}

function validLocalDate(value) {
  const text = String(value || '').trim();
  if (!/^\d{4}-\d{2}-\d{2}$/.test(text)) return '';
  const parsed = Date.parse(`${text}T00:00:00Z`);
  return Number.isFinite(parsed) ? text : '';
}

function movementTime(movement, key, utc = false) {
  if (!movement || typeof movement !== 'object') return '';
  const legacyKey = `${key}${utc ? 'Utc' : 'Local'}`;
  const legacy = movement[legacyKey];
  if (typeof legacy === 'string' && legacy.trim()) return legacy.trim();
  const structured = movement[key];
  if (structured && typeof structured === 'object') {
    const value = structured[utc ? 'utc' : 'local'];
    if (typeof value === 'string' && value.trim()) return value.trim();
  }
  return '';
}

function airportFromMovement(movement) {
  const airport = movement?.airport && typeof movement.airport === 'object' ? movement.airport : {};
  return {
    iata: cleanText(airport.iata, 12) || '',
    icao: cleanText(airport.icao, 12) || '',
    name: safeHumanText(airport.name || airport.shortName || airport.municipalityName || '', 240) || ''
  };
}

function normalizedAeroCandidate(item, index) {
  const departure = item?.departure && typeof item.departure === 'object' ? item.departure : {};
  const arrival = item?.arrival && typeof item.arrival === 'object' ? item.arrival : {};
  const depAirport = airportFromMovement(departure);
  const arrAirport = airportFromMovement(arrival);
  return {
    id: `candidate-${index + 1}`,
    flightNumber: safeHumanText(item?.number || '', 40) || '',
    callSign: safeHumanText(item?.callSign || '', 40) || '',
    airlineName: safeHumanText(item?.airline?.name || '', 180) || '',
    airlineIATA: cleanText(item?.airline?.iata, 12) || '',
    airlineICAO: cleanText(item?.airline?.icao, 12) || '',
    departureAirportIATA: depAirport.iata,
    departureAirportICAO: depAirport.icao,
    departureAirportName: depAirport.name,
    arrivalAirportIATA: arrAirport.iata,
    arrivalAirportICAO: arrAirport.icao,
    arrivalAirportName: arrAirport.name,
    scheduledDepartureLocal: movementTime(departure, 'scheduledTime', false),
    scheduledDepartureUTC: movementTime(departure, 'scheduledTime', true),
    scheduledArrivalLocal: movementTime(arrival, 'scheduledTime', false),
    scheduledArrivalUTC: movementTime(arrival, 'scheduledTime', true),
    departureTerminal: safeHumanText(departure.terminal || '', 40) || '',
    arrivalTerminal: safeHumanText(arrival.terminal || '', 40) || '',
    departureGate: safeHumanText(departure.gate || '', 40) || '',
    arrivalGate: safeHumanText(arrival.gate || '', 40) || '',
    status: safeHumanText(item?.status || '', 80) || '',
    lastUpdatedUTC: cleanText(item?.lastUpdatedUtc || item?.lastUpdatedUTC || '', 80) || ''
  };
}

function flightCacheTTL(dateLocal) {
  const target = Date.parse(`${dateLocal}T00:00:00Z`);
  const delta = Math.abs(target - Date.now());
  return delta <= 2 * 86400_000 ? 5 * 60_000 : 6 * 60 * 60_000;
}

async function verifyFlightWithAeroDataBox(env, flightNumber, dateLocal, force = false) {
  const normalized = normalizedFlightNumber(flightNumber);
  const date = validLocalDate(dateLocal);
  if (!normalized) return { ok: false, response: json({ ok: false, error: 'INVALID_FLIGHT_NUMBER' }, 400) };
  if (!date) return { ok: false, response: json({ ok: false, error: 'INVALID_FLIGHT_DATE' }, 400) };
  const cacheKey = `${normalized}|${date}`;
  const now = new Date();
  if (!force) {
    const cached = await env.HOTELS_DB.prepare('SELECT * FROM flight_verification_cache WHERE cache_key=? LIMIT 1').bind(cacheKey).first();
    if (cached && Date.parse(cached.expires_at) > now.getTime()) {
      return { ok: true, cacheKey, cached: true, checkedAt: cached.checked_at, candidates: parseJSONArray(cached.candidates_json) };
    }
  }
  const apiKey = String(env.AERODATABOX_RAPIDAPI_KEY || '').trim();
  if (!apiKey) return { ok: false, response: json({ ok: false, error: 'AERODATABOX_NOT_CONFIGURED' }, 503) };
  const endpoint = `https://aerodatabox.p.rapidapi.com/flights/number/${encodeURIComponent(normalized)}/${encodeURIComponent(date)}?withAircraftImage=false&withLocation=false&dateLocalRole=Departure`;
  let response;
  try {
    response = await fetch(endpoint, {
      method: 'GET',
      headers: {
        'accept': 'application/json',
        'X-RapidAPI-Key': apiKey,
        'X-RapidAPI-Host': 'aerodatabox.p.rapidapi.com'
      }
    });
  } catch (error) {
    console.error('AERODATABOX_NETWORK_ERROR', error);
    return { ok: false, response: json({ ok: false, error: 'FLIGHT_PROVIDER_UNAVAILABLE' }, 502) };
  }
  if (response.status === 429) return { ok: false, response: json({ ok: false, error: 'AERODATABOX_QUOTA_EXCEEDED' }, 429) };
  if (response.status === 401 || response.status === 403) return { ok: false, response: json({ ok: false, error: 'AERODATABOX_AUTH_FAILED' }, 502) };
  if (!response.ok) {
    const body = (await response.text().catch(() => '')).slice(0, 500);
    console.warn('AERODATABOX_HTTP_ERROR', response.status, body);
    return { ok: false, response: json({ ok: false, error: `AERODATABOX_HTTP_${response.status}` }, 502) };
  }
  const payload = await response.json().catch(() => null);
  const items = Array.isArray(payload) ? payload : [];
  const candidates = items
    .filter(item => normalizedFlightNumber(item?.number || '') === normalized)
    .slice(0, 8)
    .map((item, index) => normalizedAeroCandidate(item, index));
  const checkedAt = now.toISOString();
  const expiresAt = new Date(now.getTime() + flightCacheTTL(date)).toISOString();
  await env.HOTELS_DB.prepare(`
    INSERT INTO flight_verification_cache (cache_key, flight_number, date_local, candidates_json, checked_at, expires_at, provider)
    VALUES (?, ?, ?, ?, ?, ?, 'aerodatabox')
    ON CONFLICT(cache_key) DO UPDATE SET candidates_json=excluded.candidates_json, checked_at=excluded.checked_at, expires_at=excluded.expires_at, provider='aerodatabox'
  `).bind(cacheKey, normalized, date, JSON.stringify(candidates), checkedAt, expiresAt).run();
  await env.HOTELS_DB.prepare("DELETE FROM flight_verification_cache WHERE julianday(expires_at) < julianday('now','-7 days')").run().catch(() => {});
  return { ok: true, cacheKey, cached: false, checkedAt, candidates };
}

async function verifyBusinessFlight(request, env) {
  const payload = await request.json().catch(() => null);
  if (!payload) return json({ ok: false, error: 'INVALID_JSON' }, 400);
  const result = await verifyFlightWithAeroDataBox(env, payload.flightNumber, payload.dateLocal, payload.force === true);
  if (!result.ok) return result.response;
  if (!result.candidates.length) return json({ ok: false, error: 'FLIGHT_NOT_FOUND', flightNumber: normalizedFlightNumber(payload.flightNumber), dateLocal: validLocalDate(payload.dateLocal) }, 404);
  return json({ ok: true, provider: 'AeroDataBox', verificationKey: result.cacheKey, cached: result.cached, checkedAt: result.checkedAt, candidates: result.candidates });
}

function mapTripFlight(row) {
  if (!row) return null;
  return {
    direction: row.direction,
    flightNumber: row.flight_number || '',
    callSign: row.call_sign || '',
    airlineName: row.airline_name || '',
    airlineIATA: row.airline_iata || '',
    airlineICAO: row.airline_icao || '',
    departureAirportIATA: row.departure_airport_iata || '',
    departureAirportICAO: row.departure_airport_icao || '',
    departureAirportName: row.departure_airport_name || '',
    arrivalAirportIATA: row.arrival_airport_iata || '',
    arrivalAirportICAO: row.arrival_airport_icao || '',
    arrivalAirportName: row.arrival_airport_name || '',
    scheduledDepartureLocal: row.scheduled_departure_local || '',
    scheduledDepartureUTC: row.scheduled_departure_utc || '',
    scheduledArrivalLocal: row.scheduled_arrival_local || '',
    scheduledArrivalUTC: row.scheduled_arrival_utc || '',
    departureTerminal: row.departure_terminal || '',
    arrivalTerminal: row.arrival_terminal || '',
    departureGate: row.departure_gate || '',
    arrivalGate: row.arrival_gate || '',
    status: row.status || '',
    verificationProvider: row.verification_provider || 'aerodatabox',
    verifiedAt: row.verified_at || null,
    lastCheckedAt: row.last_checked_at || null
  };
}

async function saveVerifiedBookingFlight(request, env, bookingID, directionRaw) {
  const direction = String(directionRaw || '').toLowerCase();
  if (!FLIGHT_DIRECTIONS.has(direction)) return json({ ok: false, error: 'INVALID_FLIGHT_DIRECTION' }, 400);
  const trip = await env.HOTELS_DB.prepare('SELECT id FROM pilgrim_trips WHERE booking_id=? LIMIT 1').bind(bookingID).first();
  if (!trip) return json({ ok: false, error: 'BOOKING_NOT_SYNCED' }, 404);
  const payload = await request.json().catch(() => null);
  const verificationKey = cleanText(payload?.verificationKey, 120);
  const candidateID = cleanText(payload?.candidateID, 80);
  if (!verificationKey || !candidateID) return json({ ok: false, error: 'VERIFICATION_REQUIRED' }, 400);
  const cached = await env.HOTELS_DB.prepare('SELECT * FROM flight_verification_cache WHERE cache_key=? LIMIT 1').bind(verificationKey).first();
  if (!cached || Date.now() - Date.parse(cached.checked_at) > 24 * 60 * 60_000) return json({ ok: false, error: 'FLIGHT_VERIFICATION_EXPIRED' }, 409);
  const candidates = parseJSONArray(cached.candidates_json);
  const candidate = candidates.find(item => item?.id === candidateID);
  if (!candidate) return json({ ok: false, error: 'FLIGHT_CANDIDATE_NOT_FOUND' }, 404);
  const now = new Date().toISOString();
  await env.HOTELS_DB.prepare(`
    INSERT INTO trip_flights (
      booking_id, direction, flight_number, call_sign, airline_name, airline_iata, airline_icao,
      departure_airport_iata, departure_airport_icao, departure_airport_name,
      arrival_airport_iata, arrival_airport_icao, arrival_airport_name,
      scheduled_departure_local, scheduled_departure_utc, scheduled_arrival_local, scheduled_arrival_utc,
      departure_terminal, arrival_terminal, departure_gate, arrival_gate, status,
      verification_provider, verification_key, verified_at, last_checked_at, created_at, updated_at
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'aerodatabox', ?, ?, ?, ?, ?)
    ON CONFLICT(booking_id, direction) DO UPDATE SET
      flight_number=excluded.flight_number, call_sign=excluded.call_sign, airline_name=excluded.airline_name,
      airline_iata=excluded.airline_iata, airline_icao=excluded.airline_icao,
      departure_airport_iata=excluded.departure_airport_iata, departure_airport_icao=excluded.departure_airport_icao,
      departure_airport_name=excluded.departure_airport_name, arrival_airport_iata=excluded.arrival_airport_iata,
      arrival_airport_icao=excluded.arrival_airport_icao, arrival_airport_name=excluded.arrival_airport_name,
      scheduled_departure_local=excluded.scheduled_departure_local, scheduled_departure_utc=excluded.scheduled_departure_utc,
      scheduled_arrival_local=excluded.scheduled_arrival_local, scheduled_arrival_utc=excluded.scheduled_arrival_utc,
      departure_terminal=excluded.departure_terminal, arrival_terminal=excluded.arrival_terminal,
      departure_gate=excluded.departure_gate, arrival_gate=excluded.arrival_gate, status=excluded.status,
      verification_provider='aerodatabox', verification_key=excluded.verification_key,
      verified_at=excluded.verified_at, last_checked_at=excluded.last_checked_at, updated_at=excluded.updated_at
  `).bind(
    bookingID, direction, candidate.flightNumber || '', candidate.callSign || '', candidate.airlineName || '', candidate.airlineIATA || '', candidate.airlineICAO || '',
    candidate.departureAirportIATA || '', candidate.departureAirportICAO || '', candidate.departureAirportName || '',
    candidate.arrivalAirportIATA || '', candidate.arrivalAirportICAO || '', candidate.arrivalAirportName || '',
    candidate.scheduledDepartureLocal || '', candidate.scheduledDepartureUTC || '', candidate.scheduledArrivalLocal || '', candidate.scheduledArrivalUTC || '',
    candidate.departureTerminal || '', candidate.arrivalTerminal || '', candidate.departureGate || '', candidate.arrivalGate || '', candidate.status || '',
    verificationKey, now, now, now, now
  ).run();
  return json({ ok: true, flight: mapTripFlight(await env.HOTELS_DB.prepare('SELECT * FROM trip_flights WHERE booking_id=? AND direction=?').bind(bookingID, direction).first()) });
}

async function deleteBookingFlight(env, bookingID, directionRaw) {
  const direction = String(directionRaw || '').toLowerCase();
  if (!FLIGHT_DIRECTIONS.has(direction)) return json({ ok: false, error: 'INVALID_FLIGHT_DIRECTION' }, 400);
  await env.HOTELS_DB.prepare('DELETE FROM trip_flights WHERE booking_id=? AND direction=?').bind(bookingID, direction).run();
  return json({ ok: true });
}

async function assignmentHotelSummary(env, hotelID) {
  if (!hotelID) return null;
  return hotelSummary(await summaryRow(env, hotelID));
}

async function bookingAssignmentDetail(env, bookingID) {
  const row = await env.HOTELS_DB.prepare('SELECT * FROM trip_assignments WHERE booking_id=? LIMIT 1').bind(bookingID).first();
  const primaryGuide = await env.HOTELS_DB.prepare("SELECT * FROM team_members WHERE role_kind='guide' AND active=1 ORDER BY sort_order ASC, created_at ASC LIMIT 1").first();
  if (!row) {
    return { makkahHotelID: null, madinahHotelID: null, guideID: primaryGuide?.id || null, makkahHotel: null, madinahHotel: null, guide: primaryGuide ? mapTeamMember(primaryGuide, true) : null, guideIsPrimary: !!primaryGuide };
  }
  const guide = row.guide_team_member_id
    ? await env.HOTELS_DB.prepare('SELECT * FROM team_members WHERE id=? LIMIT 1').bind(row.guide_team_member_id).first()
    : primaryGuide;
  return {
    makkahHotelID: row.makkah_hotel_id || null,
    madinahHotelID: row.madinah_hotel_id || null,
    guideID: guide?.id || null,
    makkahHotel: await assignmentHotelSummary(env, row.makkah_hotel_id),
    madinahHotel: await assignmentHotelSummary(env, row.madinah_hotel_id),
    guide: guide ? mapTeamMember(guide, true) : null,
    guideIsPrimary: !row.guide_team_member_id && !!primaryGuide
  };
}

async function clientBookingAssignmentDetail(env, bookingID) {
  const detail = await bookingAssignmentDetail(env, bookingID);
  const guide = detail?.guide;
  return {
    guide: guide ? {
      id: String(guide.id || ''),
      displayName: String(guide.displayName || ''),
      roleTitle: String(guide.roleTitle || ''),
      phoneUZ: String(guide.phoneUZ || ''),
      phoneSA: String(guide.phoneSA || ''),
      telegram: String(guide.telegram || ''),
      whatsapp: String(guide.whatsapp || ''),
      bio: String(guide.bio || '')
    } : null
  };
}

async function updateBookingAssignments(request, env, bookingID) {
  const trip = await env.HOTELS_DB.prepare('SELECT id FROM pilgrim_trips WHERE booking_id=? LIMIT 1').bind(bookingID).first();
  if (!trip) return json({ ok: false, error: 'BOOKING_NOT_SYNCED' }, 404);
  const payload = await request.json().catch(() => null);
  if (!payload || typeof payload !== 'object') return json({ ok: false, error: 'INVALID_JSON' }, 400);
  const current = await env.HOTELS_DB.prepare('SELECT * FROM trip_assignments WHERE booking_id=? LIMIT 1').bind(bookingID).first();
  const makkahID = payload.makkahHotelID === null ? null : (cleanText(payload.makkahHotelID, 180) || current?.makkah_hotel_id || null);
  const madinahID = payload.madinahHotelID === null ? null : (cleanText(payload.madinahHotelID, 180) || current?.madinah_hotel_id || null);
  const guideID = payload.guideID === null ? null : (cleanText(payload.guideID, 180) || current?.guide_team_member_id || null);
  for (const [id, city] of [[makkahID, 'Makkah'], [madinahID, 'Madinah']]) {
    if (!id) continue;
    const hotel = await env.HOTELS_DB.prepare("SELECT id, city, status FROM hotels WHERE id=? AND status='published' LIMIT 1").bind(id).first();
    if (!hotel) return json({ ok: false, error: 'HOTEL_NOT_AVAILABLE', hotelID: id }, 409);
    if (hotel.city && String(hotel.city).toLowerCase() !== city.toLowerCase()) return json({ ok: false, error: 'HOTEL_CITY_MISMATCH', hotelID: id, expectedCity: city }, 409);
  }
  if (guideID) {
    const guide = await env.HOTELS_DB.prepare("SELECT id FROM team_members WHERE id=? AND role_kind='guide' AND active=1 LIMIT 1").bind(guideID).first();
    if (!guide) return json({ ok: false, error: 'GUIDE_NOT_AVAILABLE' }, 409);
  }
  const now = new Date().toISOString();
  await env.HOTELS_DB.prepare(`
    INSERT INTO trip_assignments (booking_id, makkah_hotel_id, madinah_hotel_id, guide_team_member_id, created_at, updated_at)
    VALUES (?, ?, ?, ?, ?, ?)
    ON CONFLICT(booking_id) DO UPDATE SET makkah_hotel_id=excluded.makkah_hotel_id, madinah_hotel_id=excluded.madinah_hotel_id, guide_team_member_id=excluded.guide_team_member_id, updated_at=excluded.updated_at
  `).bind(bookingID, makkahID, madinahID, guideID, now, now).run();
  return json({ ok: true, assignment: await bookingAssignmentDetail(env, bookingID) });
}

async function sourceBookingDeleteTargets(db) {
  const tables = await db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'").all();
  const targets = [];
  for (const row of tables.results || []) {
    const table = String(row?.name || '');
    if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(table) || table === 'bookings') continue;
    const columns = await db.prepare(`PRAGMA table_info("${table}")`).all().catch(() => ({ results: [] }));
    const bookingColumn = (columns.results || []).find(column => String(column?.name || '') === 'booking_id');
    if (bookingColumn) {
      targets.push({ table, column: 'booking_id' });
      continue;
    }
    const foreignKeys = await db.prepare(`PRAGMA foreign_key_list("${table}")`).all().catch(() => ({ results: [] }));
    const bookingFK = (foreignKeys.results || []).find(fk => String(fk?.table || '') === 'bookings' && String(fk?.to || '') === 'id');
    const column = String(bookingFK?.from || '');
    if (/^[A-Za-z_][A-Za-z0-9_]*$/.test(column)) targets.push({ table, column });
  }
  return targets;
}

async function hardDeleteSourceBooking(env, bookingID) {
  if (!env.BOOKINGS_DB) return { configured: false, deleted: false };
  const existing = await env.BOOKINGS_DB.prepare('SELECT id FROM bookings WHERE id=? LIMIT 1').bind(bookingID).first();
  if (!existing) return { configured: true, deleted: false };

  const targets = await sourceBookingDeleteTargets(env.BOOKINGS_DB);
  const statements = targets.map(({ table, column }) =>
    env.BOOKINGS_DB.prepare(`DELETE FROM "${table}" WHERE "${column}"=?`).bind(bookingID)
  );
  statements.push(env.BOOKINGS_DB.prepare('DELETE FROM bookings WHERE id=?').bind(bookingID));
  await env.BOOKINGS_DB.batch(statements);

  const remaining = await env.BOOKINGS_DB.prepare('SELECT id FROM bookings WHERE id=? LIMIT 1').bind(bookingID).first();
  if (remaining) throw new Error('BOOKING_SOURCE_DELETE_NOT_PERSISTED');
  return { configured: true, deleted: true };
}

async function purgeOperationalBooking(env, bookingID) {
  await ensureBookingItinerarySchema(env);
  const trip = await env.HOTELS_DB.prepare('SELECT pilgrim_id FROM pilgrim_trips WHERE booking_id=? LIMIT 1').bind(bookingID).first().catch(() => null);
  const attachments = await env.HOTELS_DB.prepare('SELECT object_key FROM business_chat_attachments WHERE booking_id=?').bind(bookingID).all().catch(() => ({ results: [] }));
  const now = new Date().toISOString();

  await env.HOTELS_DB.batch([
    env.HOTELS_DB.prepare('DELETE FROM client_push_subscriptions WHERE booking_id=?').bind(bookingID),
    env.HOTELS_DB.prepare('DELETE FROM business_chat_messages WHERE booking_id=?').bind(bookingID),
    env.HOTELS_DB.prepare('DELETE FROM business_chat_attachments WHERE booking_id=?').bind(bookingID),
    env.HOTELS_DB.prepare('DELETE FROM business_chat_threads WHERE booking_id=?').bind(bookingID),
    env.HOTELS_DB.prepare('DELETE FROM booking_status_history WHERE booking_id=?').bind(bookingID),
    env.HOTELS_DB.prepare('DELETE FROM trip_flights WHERE booking_id=?').bind(bookingID),
    env.HOTELS_DB.prepare('DELETE FROM booking_itinerary_items WHERE booking_id=?').bind(bookingID),
    env.HOTELS_DB.prepare('DELETE FROM trip_assignments WHERE booking_id=?').bind(bookingID),
    env.HOTELS_DB.prepare('DELETE FROM booking_esims WHERE booking_id=?').bind(bookingID),
    env.HOTELS_DB.prepare('DELETE FROM pilgrim_trips WHERE booking_id=?').bind(bookingID),
    env.HOTELS_DB.prepare('DELETE FROM booking_tombstones WHERE booking_id=?').bind(bookingID)
  ]);

  await Promise.allSettled((attachments.results || []).map(row => env.HOTELS_MEDIA.delete(row.object_key)));

  if (trip?.pilgrim_id) {
    const pilgrim = await env.HOTELS_DB.prepare('SELECT * FROM pilgrims WHERE id=? LIMIT 1').bind(trip.pilgrim_id).first().catch(() => null);
    const stats = await env.HOTELS_DB.prepare('SELECT COUNT(*) AS count, MAX(COALESCE(end_date, created_at)) AS last_trip FROM pilgrim_trips WHERE pilgrim_id=?').bind(trip.pilgrim_id).first();
    const count = Number(stats?.count || 0);
    if (count === 0 && pilgrim && !(await env.HOTELS_DB.prepare('SELECT pilgrim_id FROM iumrah_accounts WHERE pilgrim_id=?').bind(trip.pilgrim_id).first().catch(() => null))) {
      await env.HOTELS_DB.prepare('DELETE FROM pilgrims WHERE id=?').bind(trip.pilgrim_id).run();
    } else {
      // The pilgrim identity is permanent. Deleting one trip must never recycle its six-digit iumrah ID.
      await env.HOTELS_DB.prepare('UPDATE pilgrims SET total_trips=?, last_trip_at=?, updated_at=? WHERE id=?')
        .bind(count, stats?.last_trip || null, now, trip.pilgrim_id).run();
    }
  }
}

async function deleteOperationsBooking(request, env, bookingID, user) {
  try {
    const direct = await hardDeleteSourceBooking(env, bookingID);
    if (!direct.configured) return json({ ok: false, error: 'BOOKINGS_DB_NOT_CONFIGURED' }, 503);
    if (!direct.deleted) return json({ ok: false, error: 'BOOKING_NOT_FOUND_IN_SOURCE_DB' }, 404);
  } catch (error) {
    console.error('BOOKING_SOURCE_DELETE_FAILED', bookingID, error);
    return json({ ok: false, error: cleanText(error?.message, 180) || 'BOOKING_SOURCE_DELETE_FAILED' }, 500);
  }

  await purgeOperationalBooking(env, bookingID);
  return json({ ok: true, deletedBookingID: bookingID, deletedBy: cleanText(user?.login, 180) || null });
}

async function deleteClientBooking(request, env, bookingID, auth) {
  // requireClientBooking has already verified x-booking-token against the live
  // booking service. Delete the same source row directly through the D1 binding
  // so client and staff deletion cannot drift through separate HTTP routes.
  try {
    const direct = await hardDeleteSourceBooking(env, bookingID);
    if (!direct.configured) return json({ ok: false, error: 'BOOKINGS_DB_NOT_CONFIGURED' }, 503);
    if (!direct.deleted) return json({ ok: false, error: 'BOOKING_NOT_FOUND_IN_SOURCE_DB' }, 404);
  } catch (error) {
    console.error('CLIENT_BOOKING_SOURCE_DELETE_FAILED', bookingID, error);
    return json({ ok: false, error: cleanText(error?.message, 180) || 'BOOKING_SOURCE_DELETE_FAILED' }, 500);
  }

  await purgeOperationalBooking(env, bookingID);
  return json({ ok: true, deleted: true, pilgrimID: auth?.trip?.pilgrim_id ? pilgrimPublicID(auth.trip.pilgrim_id) : null });
}

function teamMemberPayload(payload, defaults = {}) {
  const firstName = safeHumanText(payload?.firstName ?? defaults.firstName ?? '', 120) || '';
  const lastName = safeHumanText(payload?.lastName ?? defaults.lastName ?? '', 120) || '';
  const roleKindRaw = String(payload?.roleKind ?? defaults.roleKind ?? 'guide').toLowerCase();
  const roleKind = ['owner','guide','manager','operations'].includes(roleKindRaw) ? roleKindRaw : 'guide';
  const publicSlugInput = cleanText(payload?.publicSlug ?? defaults.publicSlug, 120);
  const slugBase = publicSlugInput || `${firstName}-${lastName}` || `team-${crypto.randomUUID().slice(0, 8)}`;
  return {
    firstName,
    lastName,
    roleKind,
    roleTitle: safeHumanText(payload?.roleTitle ?? defaults.roleTitle ?? '', 160) || '',
    phoneUZ: cleanText(payload?.phoneUZ ?? defaults.phoneUZ ?? '', 80) || '',
    phoneSA: cleanText(payload?.phoneSA ?? defaults.phoneSA ?? '', 80) || '',
    telegram: cleanText(payload?.telegram ?? defaults.telegram ?? '', 160) || '',
    whatsapp: cleanText(payload?.whatsapp ?? defaults.whatsapp ?? '', 160) || '',
    instagram: cleanText(payload?.instagram ?? defaults.instagram ?? '', 160) || '',
    bio: safeHumanText(payload?.bio ?? defaults.bio ?? '', 1800) || '',
    publicSlug: slugify(slugBase) || `team-${crypto.randomUUID().slice(0, 8)}`,
    publicVisible: payload?.publicVisible == null ? (defaults.publicVisible ?? true) : !!payload.publicVisible,
    active: payload?.active == null ? (defaults.active ?? true) : !!payload.active
  };
}

function mapTeamMember(row, admin = true) {
  if (!row) return null;
  const base = {
    id: row.id,
    firstName: row.first_name || '',
    lastName: row.last_name || '',
    displayName: [row.first_name, row.last_name].filter(Boolean).join(' ').trim() || row.role_title || 'iumrah',
    roleKind: row.role_kind || 'guide',
    roleTitle: row.role_title || '',
    phoneUZ: row.phone_uz || '',
    phoneSA: row.phone_sa || '',
    telegram: row.telegram || '',
    whatsapp: row.whatsapp || '',
    instagram: row.instagram || '',
    bio: row.bio || '',
    publicSlug: row.public_slug,
    publicVisible: Number(row.public_visible || 0) === 1,
    active: Number(row.active || 0) === 1,
    isOwner: Number(row.is_owner || 0) === 1,
    photoURL: row.photo_object_key ? `/api/catalog/hotels/team/${encodeURIComponent(row.public_slug)}/photo` : null
  };
  if (admin) base.staffLogin = row.staff_login || null;
  return base;
}

async function ensureOwnerProfile(env, user) {
  const login = cleanText(user?.login, 180) || 'owner';
  let row = await env.HOTELS_DB.prepare('SELECT * FROM team_members WHERE staff_login=? LIMIT 1').bind(login).first();
  if (row) return row;
  const id = `team-${crypto.randomUUID()}`;
  const display = safeHumanText(user?.displayName || '', 200) || '';
  const pieces = display.split(/\s+/).filter(Boolean);
  const firstName = pieces[0] || '';
  const lastName = pieces.slice(1).join(' ');
  let slug = slugify(display || login) || `owner-${crypto.randomUUID().slice(0,8)}`;
  const exists = await env.HOTELS_DB.prepare('SELECT id FROM team_members WHERE public_slug=? LIMIT 1').bind(slug).first();
  if (exists) slug = `${slug}-${crypto.randomUUID().slice(0,6)}`;
  const now = new Date().toISOString();
  await env.HOTELS_DB.prepare(`
    INSERT INTO team_members (id, staff_login, first_name, last_name, role_kind, role_title, public_slug, public_visible, active, is_owner, sort_order, created_at, updated_at)
    VALUES (?, ?, ?, ?, 'owner', 'Owner · iumrah', ?, 1, 1, 1, 0, ?, ?)
  `).bind(id, login, firstName, lastName, slug, now, now).run();
  return env.HOTELS_DB.prepare('SELECT * FROM team_members WHERE id=?').bind(id).first();
}

async function businessProfileMe(env, user) {
  return json({ ok: true, member: mapTeamMember(await ensureOwnerProfile(env, user), true) });
}

async function saveBusinessProfileMe(request, env, user) {
  const existing = await ensureOwnerProfile(env, user);
  const payload = await request.json().catch(() => null);
  if (!payload) return json({ ok: false, error: 'INVALID_JSON' }, 400);
  const value = teamMemberPayload(payload, mapTeamMember(existing, true));
  const duplicate = await env.HOTELS_DB.prepare('SELECT id FROM team_members WHERE public_slug=? AND id<>? LIMIT 1').bind(value.publicSlug, existing.id).first();
  if (duplicate) return json({ ok: false, error: 'PUBLIC_SLUG_TAKEN' }, 409);
  const now = new Date().toISOString();
  await env.HOTELS_DB.prepare(`
    UPDATE team_members SET first_name=?, last_name=?, role_kind='owner', role_title=?, phone_uz=?, phone_sa=?, telegram=?, whatsapp=?, instagram=?, bio=?, public_slug=?, public_visible=?, active=1, is_owner=1, updated_at=? WHERE id=?
  `).bind(value.firstName, value.lastName, value.roleTitle, value.phoneUZ, value.phoneSA, value.telegram, value.whatsapp, value.instagram, value.bio, value.publicSlug, value.publicVisible ? 1 : 0, now, existing.id).run();
  return businessProfileMe(env, user);
}

async function adminTeam(env) {
  const result = await env.HOTELS_DB.prepare('SELECT * FROM team_members ORDER BY is_owner DESC, sort_order ASC, last_name COLLATE NOCASE, first_name COLLATE NOCASE').all();
  return json({ ok: true, members: (result.results || []).map(row => mapTeamMember(row, true)) });
}

async function adminTeamMember(env, memberID) {
  const row = await env.HOTELS_DB.prepare('SELECT * FROM team_members WHERE id=?').bind(memberID).first();
  if (!row) return json({ ok: false, error: 'TEAM_MEMBER_NOT_FOUND' }, 404);
  return json({ ok: true, member: mapTeamMember(row, true) });
}

async function createTeamMember(request, env) {
  const payload = await request.json().catch(() => null);
  if (!payload) return json({ ok: false, error: 'INVALID_JSON' }, 400);
  const value = teamMemberPayload(payload);
  if (!value.firstName && !value.lastName) return json({ ok: false, error: 'NAME_REQUIRED' }, 400);
  const duplicate = await env.HOTELS_DB.prepare('SELECT id FROM team_members WHERE public_slug=? LIMIT 1').bind(value.publicSlug).first();
  if (duplicate) return json({ ok: false, error: 'PUBLIC_SLUG_TAKEN' }, 409);
  const id = `team-${crypto.randomUUID()}`;
  const now = new Date().toISOString();
  const max = await env.HOTELS_DB.prepare('SELECT COALESCE(MAX(sort_order), 0) AS max_order FROM team_members').first();
  await env.HOTELS_DB.prepare(`
    INSERT INTO team_members (id, first_name, last_name, role_kind, role_title, phone_uz, phone_sa, telegram, whatsapp, instagram, bio, public_slug, public_visible, active, is_owner, sort_order, created_at, updated_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?)
  `).bind(id, value.firstName, value.lastName, value.roleKind, value.roleTitle, value.phoneUZ, value.phoneSA, value.telegram, value.whatsapp, value.instagram, value.bio, value.publicSlug, value.publicVisible ? 1 : 0, value.active ? 1 : 0, Number(max?.max_order || 0) + 1, now, now).run();
  return adminTeamMember(env, id);
}

async function updateTeamMember(request, env, memberID) {
  const row = await env.HOTELS_DB.prepare('SELECT * FROM team_members WHERE id=?').bind(memberID).first();
  if (!row) return json({ ok: false, error: 'TEAM_MEMBER_NOT_FOUND' }, 404);
  const payload = await request.json().catch(() => null);
  if (!payload) return json({ ok: false, error: 'INVALID_JSON' }, 400);
  const value = teamMemberPayload(payload, mapTeamMember(row, true));
  const duplicate = await env.HOTELS_DB.prepare('SELECT id FROM team_members WHERE public_slug=? AND id<>? LIMIT 1').bind(value.publicSlug, memberID).first();
  if (duplicate) return json({ ok: false, error: 'PUBLIC_SLUG_TAKEN' }, 409);
  const now = new Date().toISOString();
  await env.HOTELS_DB.prepare(`
    UPDATE team_members SET first_name=?, last_name=?, role_kind=?, role_title=?, phone_uz=?, phone_sa=?, telegram=?, whatsapp=?, instagram=?, bio=?, public_slug=?, public_visible=?, active=?, updated_at=? WHERE id=?
  `).bind(value.firstName, value.lastName, row.is_owner ? 'owner' : value.roleKind, value.roleTitle, value.phoneUZ, value.phoneSA, value.telegram, value.whatsapp, value.instagram, value.bio, value.publicSlug, value.publicVisible ? 1 : 0, value.active ? 1 : 0, now, memberID).run();
  return adminTeamMember(env, memberID);
}

async function deleteTeamMember(env, memberID) {
  const row = await env.HOTELS_DB.prepare('SELECT is_owner FROM team_members WHERE id=?').bind(memberID).first();
  if (!row) return json({ ok: true });
  if (Number(row.is_owner || 0) === 1) return json({ ok: false, error: 'OWNER_CANNOT_BE_DELETED' }, 409);
  await env.HOTELS_DB.prepare('DELETE FROM team_members WHERE id=?').bind(memberID).run();
  return json({ ok: true });
}

async function publicTeam(env, parts) {
  if (parts.length === 2 && parts[1] === 'photo') {
    const slug = cleanText(parts[0], 120);
    if (!slug) return json({ ok: false, error: 'INVALID_PROFILE' }, 400);
    const row = await env.HOTELS_DB.prepare('SELECT photo_object_key,photo_content_type FROM team_members WHERE public_slug=? AND active=1 AND public_visible=1 LIMIT 1').bind(slug).first();
    if (!row?.photo_object_key) return json({ ok: false, error: 'PHOTO_NOT_FOUND' }, 404);
    const object = await env.HOTELS_MEDIA.get(row.photo_object_key);
    if (!object) return json({ ok: false, error: 'PHOTO_NOT_FOUND' }, 404);
    return new Response(object.body, { headers: { 'content-type': row.photo_content_type || 'image/jpeg', 'cache-control': 'public, max-age=3600' } });
  }
  if (parts.length === 0) {
    const result = await env.HOTELS_DB.prepare(`SELECT * FROM team_members WHERE active=1 AND public_visible=1 ORDER BY is_owner DESC, sort_order ASC, last_name COLLATE NOCASE, first_name COLLATE NOCASE`).all();
    return json({ ok: true, members: (result.results || []).map(row => mapTeamMember(row, false)) }, 200, PUBLIC_CACHE_HEADERS);
  }
  const slug = cleanText(parts[0], 120);
  if (!slug) return json({ ok: false, error: 'INVALID_PROFILE' }, 400);
  const row = await env.HOTELS_DB.prepare('SELECT * FROM team_members WHERE public_slug=? AND active=1 AND public_visible=1 LIMIT 1').bind(slug).first();
  if (!row) return json({ ok: false, error: 'PROFILE_NOT_FOUND' }, 404);
  return json({ ok: true, member: mapTeamMember(row, false) }, 200, PUBLIC_CACHE_HEADERS);
}

async function fetchUpstreamBookings(request, env) {
  const cookie = request.headers.get('cookie') || '';
  const response = await fetch(env.BOOKINGS_ADMIN_URL || 'https://iumrah.app/api/admin/bookings', {
    method: 'GET',
    headers: {
      'cookie': cookie,
      'accept': 'application/json',
      'user-agent': request.headers.get('user-agent') || 'iumrah-business'
    },
    redirect: 'manual'
  });
  if (!response.ok) throw new Error(`BOOKINGS_UPSTREAM_${response.status}`);
  const payload = await response.json().catch(() => null);
  return Array.isArray(payload?.bookings) ? payload.bookings : [];
}

function deepScalar(root, candidates) {
  const wanted = new Set(candidates.map(value => value.toLowerCase()));
  const queue = [{ value: root, depth: 0 }];
  const seen = new Set();
  while (queue.length) {
    const { value, depth } = queue.shift();
    if (!value || typeof value !== 'object' || depth > 4 || seen.has(value)) continue;
    seen.add(value);
    for (const [key, child] of Object.entries(value)) {
      if (wanted.has(key.toLowerCase()) && (typeof child === 'string' || typeof child === 'number')) {
        const text = String(child).trim();
        if (text) return text;
      }
    }
    for (const child of Object.values(value)) {
      if (child && typeof child === 'object') queue.push({ value: child, depth: depth + 1 });
    }
  }
  return '';
}

function bookingIdentity(raw) {
  const firstName = deepScalar(raw, ['firstName','first_name','givenName']);
  const lastName = deepScalar(raw, ['lastName','last_name','familyName','surname']);
  const explicitName = deepScalar(raw, ['clientName','customerName','travelerName','travellerName','fullName','displayName']);
  const email = deepScalar(raw, ['email','emailAddress']);
  const phone = deepScalar(raw, ['phone','phoneNumber','mobile','whatsapp']);
  const displayName = [firstName, lastName].filter(Boolean).join(' ').trim() || explicitName || '';
  return { firstName, lastName, displayName, email, phone };
}

function extractPricingSnapshot(raw) {
  if (!raw || typeof raw !== 'object') return {};
  const directKeys = ['pricingSnapshot','pricing_snapshot','pricing','priceBreakdown','pricingBreakdown','costBreakdown','generationReport','packagePricing'];
  const containers = [raw, raw.booking, raw.data, raw.payload, raw.quote].filter(value => value && typeof value === 'object');
  for (const container of containers) {
    if (validGeneratorPricingReport(container)) return container;
    for (const key of directKeys) {
      const value = container[key];
      if (value && typeof value === 'object' && validGeneratorPricingReport(value)) return value;
    }
  }
  return {};
}

function finiteNonNegative(value) {
  const number = Number(value);
  return Number.isFinite(number) && number >= 0 ? number : null;
}

function nearlyEqualPricing(a, b, tolerance = 0.08) {
  return Number.isFinite(a) && Number.isFinite(b) && Math.abs(a - b) <= tolerance;
}

function validGeneratorPricingReport(value) {
  if (!(value && typeof value === 'object' && cleanText(value.quoteId, 180))) return false;
  if (!(value.context && typeof value.context === 'object')) return false;
  if (!(value.selectedPricingInputs && typeof value.selectedPricingInputs === 'object')) return false;
  if (!(Array.isArray(value.components) && value.components.length > 0)) return false;
  if (!(value.totals && typeof value.totals === 'object')) return false;

  let componentSum = 0;
  for (const component of value.components) {
    if (!component || typeof component !== 'object' || !cleanText(component.code, 120) || !cleanText(component.label, 240)) return false;
    const amount = finiteNonNegative(component.supplierCostUsd);
    if (amount == null) return false;
    componentSum += amount;
  }

  const supplier = finiteNonNegative(value.totals.supplierCostUsd);
  const markupRate = finiteNonNegative(value.totals.markupRate);
  const markupAmount = finiteNonNegative(value.totals.markupAmountUsd);
  const subtotal = finiteNonNegative(value.totals.subtotalAfterMarkupUsd);
  const feeRate = finiteNonNegative(value.totals.paymentFeeRate);
  const calculated = finiteNonNegative(value.totals.calculatedSellingPriceUsd);
  const publicTotal = finiteNonNegative(value.totals.publicTotalUsd);
  const perPilgrim = finiteNonNegative(value.totals.publicPricePerPilgrimUsd);
  if ([supplier,markupRate,markupAmount,subtotal,feeRate,calculated,publicTotal,perPilgrim].some(v => v == null)) return false;
  if (supplier <= 0 || publicTotal <= 0 || perPilgrim <= 0 || markupRate > 5 || feeRate >= 1) return false;
  if (!nearlyEqualPricing(componentSum, supplier)) return false;
  if (!nearlyEqualPricing(supplier * markupRate, markupAmount)) return false;
  if (!nearlyEqualPricing(supplier + markupAmount, subtotal)) return false;
  if (!nearlyEqualPricing(subtotal / (1 - feeRate), calculated)) return false;
  return true;
}

function normalizedTripStatus(value) {
  const raw = String(value || '').toUpperCase();
  const map = {
    NEW:'availability_check', AVAILABILITY_CHECK:'availability_check',
    PAYMENT_PENDING:'payment_pending', PAID:'booking_confirmed', BOOKING_CONFIRMED:'booking_confirmed',
    DOCUMENTS_READY:'ready_to_travel', READY_TO_TRAVEL:'ready_to_travel',
    IN_TRIP:'in_trip', COMPLETED:'completed', CANCELLED:'cancelled'
  };
  return map[raw] || (TRIP_STATUSES.has(String(value || '').toLowerCase()) ? String(value).toLowerCase() : 'availability_check');
}

function tripStatusFromBooking(raw) { return normalizedTripStatus(raw?.status); }

async function createPilgrim(env, identity) {
  const now = new Date().toISOString();
  const result = await env.HOTELS_DB.prepare(`INSERT INTO pilgrims (first_name,last_name,display_name,phone,email,created_at,updated_at) VALUES (?,?,?,?,?,?,?)`)
    .bind(identity.firstName || '', identity.lastName || '', identity.displayName || 'Паломник', identity.phone || '', identity.email || '', now, now).run();
  return env.HOTELS_DB.prepare('SELECT * FROM pilgrims WHERE id=?').bind(Number(result?.meta?.last_row_id || 0)).first();
}

function pilgrimPublicID(id) { return String(Number(id || 0)).padStart(6, '0'); }
function bookingPublicNumber(value) {
  const number = Number(value || 0);
  if (!Number.isFinite(number) || number <= 0) return null;
  return `#${String(Math.trunc(number)).padStart(4, '0')}`;
}
async function allocateBookingNumber(env) {
  const row = await env.HOTELS_DB.prepare('UPDATE booking_number_sequence SET next_number=next_number+1 WHERE id=1 RETURNING next_number-1 AS booking_number').first();
  const number = Number(row?.booking_number || 0);
  if (!number) throw new Error('BOOKING_NUMBER_ALLOCATION_FAILED');
  return number;
}

function tripMap(row) {
  if (!row) return null;
  return { tripID:row.id, bookingID:row.booking_id, bookingNumber:Number(row.booking_number||0)||null, bookingDisplayNumber:bookingPublicNumber(row.booking_number), pilgrimID:pilgrimPublicID(row.pilgrim_id), status:normalizedTripStatus(row.status), paymentStatus:row.payment_status||'', confirmationNumber:row.confirmation_number||'', internalNotes:row.internal_notes||'', startDate:row.start_date||null, endDate:row.end_date||null, createdAt:row.created_at, updatedAt:row.updated_at, completedAt:row.completed_at||null };
}

async function sourceBookingPayload(env, bookingID) {
  if (!env.BOOKINGS_DB) return {};
  const row = await env.BOOKINGS_DB.prepare('SELECT payload_json FROM bookings WHERE id=? LIMIT 1').bind(bookingID).first().catch(() => null);
  return parseJSONObject(row?.payload_json);
}

function mergeSourceBooking(raw, sourcePayload) {
  const source = sourcePayload && typeof sourcePayload === 'object' ? sourcePayload : {};
  const merged = { ...source, ...(raw && typeof raw === 'object' ? raw : {}) };
  if ((!raw?.pilgrimProfile || typeof raw.pilgrimProfile !== 'object') && source?.pilgrimProfile) merged.pilgrimProfile = source.pilgrimProfile;
  if ((!raw?.selection || typeof raw.selection !== 'object') && source?.selection) merged.selection = source.selection;
  if ((!raw?.hotelNames || typeof raw.hotelNames !== 'object') && source?.hotelNames) merged.hotelNames = source.hotelNames;
  return merged;
}

async function updatePilgrimIdentityFields(env, pilgrim, identity) {
  if (!pilgrim) return null;
  const now = new Date().toISOString();
  await env.HOTELS_DB.prepare(`UPDATE pilgrims SET first_name=CASE WHEN ?<>'' THEN ? ELSE first_name END,last_name=CASE WHEN ?<>'' THEN ? ELSE last_name END,display_name=CASE WHEN ?<>'' THEN ? ELSE display_name END,phone=CASE WHEN ?<>'' THEN ? ELSE phone END,email=CASE WHEN ?<>'' THEN ? ELSE email END,updated_at=? WHERE id=?`)
    .bind(identity.firstName||'',identity.firstName||'',identity.lastName||'',identity.lastName||'',identity.displayName||'',identity.displayName||'',identity.phone||'',identity.phone||'',identity.email||'',identity.email||'',now,pilgrim.id).run();
  return env.HOTELS_DB.prepare('SELECT * FROM pilgrims WHERE id=?').bind(pilgrim.id).first();
}

async function syncBookingTrip(env, raw) {
  const bookingID = cleanText(raw?.id, 180); if (!bookingID) return null;
  const tombstone = await env.HOTELS_DB.prepare('SELECT booking_id FROM booking_tombstones WHERE booking_id=? LIMIT 1').bind(bookingID).first().catch(()=>null);
  if (tombstone) return { deleted:true, pilgrim:null, trip:null };
  const sourcePayload = await sourceBookingPayload(env, bookingID);
  const effectiveRaw = mergeSourceBooking(raw, sourcePayload);
  let trip = await env.HOTELS_DB.prepare('SELECT * FROM pilgrim_trips WHERE booking_id=? LIMIT 1').bind(bookingID).first();
  const now = new Date().toISOString();
  const identity = bookingIdentity(effectiveRaw);
  const pricing = extractPricingSnapshot(effectiveRaw);
  const startDate = cleanText(effectiveRaw?.startDate,64); const endDate = cleanText(effectiveRaw?.endDate,64);
  let pilgrim;
  if (!trip) {
    pilgrim = await createPilgrim(env, identity); if (!pilgrim) return null;
    const bookingNumber = await allocateBookingNumber(env);
    await env.HOTELS_DB.prepare(`INSERT INTO pilgrim_trips (id,booking_id,booking_number,pilgrim_id,status,start_date,end_date,booking_snapshot_json,pricing_snapshot_json,created_at,updated_at) VALUES (?,?,?,?,?,?,?,?,?,?,?)`)
      .bind(`trip-${crypto.randomUUID()}`,bookingID,bookingNumber,pilgrim.id,tripStatusFromBooking(effectiveRaw),startDate,endDate,JSON.stringify(effectiveRaw),JSON.stringify(pricing),now,now).run();
  } else {
    pilgrim = await env.HOTELS_DB.prepare('SELECT * FROM pilgrims WHERE id=?').bind(trip.pilgrim_id).first();
    pilgrim = await updatePilgrimIdentityFields(env,pilgrim,identity);
    const previous = parseJSONObject(trip.booking_snapshot_json); const merged={...previous,...effectiveRaw};
    const priceJSON = pricing && Object.keys(pricing).length ? JSON.stringify(pricing) : (trip.pricing_snapshot_json||'{}');
    await env.HOTELS_DB.prepare(`UPDATE pilgrim_trips SET start_date=COALESCE(?,start_date),end_date=COALESCE(?,end_date),booking_snapshot_json=?,pricing_snapshot_json=?,updated_at=? WHERE booking_id=?`)
      .bind(startDate,endDate,JSON.stringify(merged),priceJSON,now,bookingID).run();
  }
  trip=await env.HOTELS_DB.prepare('SELECT * FROM pilgrim_trips WHERE booking_id=?').bind(bookingID).first();
  pilgrim=pilgrim||await env.HOTELS_DB.prepare('SELECT * FROM pilgrims WHERE id=?').bind(trip.pilgrim_id).first();
  const stats=await env.HOTELS_DB.prepare('SELECT COUNT(*) AS count,MAX(COALESCE(end_date,created_at)) AS last_trip FROM pilgrim_trips WHERE pilgrim_id=?').bind(pilgrim.id).first();
  await env.HOTELS_DB.prepare('UPDATE pilgrims SET total_trips=?,last_trip_at=?,updated_at=? WHERE id=?').bind(Number(stats?.count||0),stats?.last_trip||null,now,pilgrim.id).run();
  return {pilgrim,trip};
}

function canonicalPilgrimName(pilgrim, identity=null) {
  const firstName=safeHumanText(pilgrim?.first_name||identity?.firstName||'',120)||''; const lastName=safeHumanText(pilgrim?.last_name||identity?.lastName||'',120)||'';
  return [firstName,lastName].filter(Boolean).join(' ').trim() || safeHumanText(pilgrim?.display_name||identity?.displayName||'',220) || 'Паломник';
}
async function bookingPilgrimName(env,bookingID,fallback='') { const row=await env.HOTELS_DB.prepare(`SELECT p.first_name,p.last_name,p.display_name FROM pilgrim_trips t JOIN pilgrims p ON p.id=t.pilgrim_id WHERE t.booking_id=? LIMIT 1`).bind(bookingID).first().catch(()=>null); return canonicalPilgrimName(row,{displayName:fallback}); }
function augmentBooking(raw,linked) { const identity=bookingIdentity(raw); return {...raw,clientName:canonicalPilgrimName(linked?.pilgrim,identity),pilgrimID:linked?.pilgrim?pilgrimPublicID(linked.pilgrim.id):null,bookingNumber:Number(linked?.trip?.booking_number||0)||null,bookingDisplayNumber:bookingPublicNumber(linked?.trip?.booking_number),tripID:linked?.trip?.id||null,operationStatus:linked?.trip?.status||tripStatusFromBooking(raw)}; }
async function cleanupOrphanLegacyPilgrims(env) { await env.HOTELS_DB.prepare(`DELETE FROM pilgrims WHERE NOT EXISTS (SELECT 1 FROM pilgrim_trips t WHERE t.pilgrim_id=pilgrims.id) AND NOT EXISTS (SELECT 1 FROM iumrah_accounts a WHERE a.pilgrim_id=pilgrims.id)`).run().catch(()=>{}); }

async function operationsBookings(request, env) {
  let bookings;
  try { bookings = await fetchUpstreamBookings(request, env); }
  catch (error) { return json({ ok: false, error: String(error?.message || 'BOOKINGS_UNAVAILABLE') }, 502); }
  const deletedRows = await env.HOTELS_DB.prepare('SELECT booking_id FROM booking_tombstones').all().catch(() => ({ results: [] }));
  const deletedIDs = new Set((deletedRows.results || []).map(row => String(row.booking_id || '')));
  const source = bookings.filter(item => !deletedIDs.has(String(item?.id || ''))).slice(0, 500);
  const output = new Array(source.length);
  const chunkSize = 8;
  for (let offset = 0; offset < source.length; offset += chunkSize) {
    const chunk = source.slice(offset, offset + chunkSize);
    let linkedChunk;
    try {
      linkedChunk = await Promise.all(chunk.map(async raw => {
        try { return await syncBookingTrip(env, raw); }
        catch (error) {
          const wrapped = new Error(`BOOKING_SYNC_FAILED:${cleanText(raw?.id, 180) || 'UNKNOWN'}:${cleanText(error?.message, 220) || 'ERROR'}`);
          wrapped.cause = error;
          throw wrapped;
        }
      }));
    } catch (error) {
      console.error('BOOKING_OPERATION_SYNC_FAILED', error);
      return json({ ok: false, error: cleanText(error?.message, 420) || 'BOOKING_OPERATION_SYNC_FAILED' }, 500);
    }
    chunk.forEach((raw, index) => { output[offset + index] = augmentBooking(raw, linkedChunk[index]); });
  }
  await cleanupOrphanLegacyPilgrims(env);
  return json({ bookings: output });
}


async function ensureBookingItinerarySchema(env) {
  await env.HOTELS_DB.prepare(`
    CREATE TABLE IF NOT EXISTS booking_itinerary_items (
      id TEXT PRIMARY KEY,
      booking_id TEXT NOT NULL,
      date_local TEXT NOT NULL,
      sort_order INTEGER NOT NULL DEFAULT 0,
      title TEXT NOT NULL,
      subtitle TEXT NOT NULL DEFAULT '',
      icon TEXT NOT NULL DEFAULT 'calendar',
      location TEXT NOT NULL DEFAULT '',
      notes TEXT NOT NULL DEFAULT '',
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
  `).run();
  await env.HOTELS_DB.prepare('CREATE INDEX IF NOT EXISTS idx_booking_itinerary_booking_date ON booking_itinerary_items(booking_id, date_local, sort_order)').run();
}

function itineraryDay(value) {
  const text = String(value || '').trim();
  if (!/^\d{4}-\d{2}-\d{2}$/.test(text)) return '';
  const parsed = Date.parse(`${text}T12:00:00Z`);
  return Number.isFinite(parsed) ? text : '';
}

function addItineraryDays(day, offset) {
  const valid = itineraryDay(day);
  if (!valid) return '';
  const date = new Date(`${valid}T12:00:00Z`);
  date.setUTCDate(date.getUTCDate() + Number(offset || 0));
  return date.toISOString().slice(0, 10);
}

function itineraryItemMap(row) {
  return {
    id: row.id,
    bookingID: row.booking_id,
    dateLocal: row.date_local,
    sortOrder: Number(row.sort_order || 0),
    title: row.title || '',
    subtitle: row.subtitle || '',
    icon: row.icon || 'calendar',
    location: row.location || '',
    notes: row.notes || '',
    createdAt: row.created_at || '',
    updatedAt: row.updated_at || ''
  };
}

async function seedBookingItineraryIfNeeded(env, bookingID, trip = null) {
  await ensureBookingItinerarySchema(env);
  const count = await env.HOTELS_DB.prepare('SELECT COUNT(*) AS count FROM booking_itinerary_items WHERE booking_id=?').bind(bookingID).first();
  if (Number(count?.count || 0) > 0) return;

  const resolvedTrip = trip || await env.HOTELS_DB.prepare('SELECT * FROM pilgrim_trips WHERE booking_id=? LIMIT 1').bind(bookingID).first();
  if (!resolvedTrip) return;
  const snapshot = parseJSONObject(resolvedTrip.booking_snapshot_json);
  const input = snapshot?.input && typeof snapshot.input === 'object' ? snapshot.input : {};
  const stay = snapshot?.stay && typeof snapshot.stay === 'object' ? snapshot.stay : {};
  const route = snapshot?.route && typeof snapshot.route === 'object' ? snapshot.route : {};
  const hotelNames = snapshot?.hotelNames && typeof snapshot.hotelNames === 'object' ? snapshot.hotelNames : {};
  const customization = snapshot?.customization && typeof snapshot.customization === 'object' ? snapshot.customization : {};
  const trace = snapshot?.generatorTrace && typeof snapshot.generatorTrace === 'object' ? snapshot.generatorTrace : {};

  const start = itineraryDay(resolvedTrip.start_date || input.startDate || snapshot.startDate);
  const end = itineraryDay(resolvedTrip.end_date || input.endDate || snapshot.endDate);
  if (!start) return;

  const events = [];
  const push = (dateLocal, title, subtitle = '', icon = 'calendar', location = '', notes = '') => {
    const day = itineraryDay(dateLocal);
    if (!day) return;
    events.push({ id: `iti-${crypto.randomUUID()}`, dateLocal: day, sortOrder: events.filter(item => item.dateLocal === day).length, title, subtitle, icon, location, notes });
  };

  const outbound = trace?.outbound || {};
  const inbound = trace?.inbound || {};
  const outboundLabel = [safeHumanText(outbound.airline || '', 120), safeHumanText(outbound.flightNumbers || '', 120)].filter(Boolean).join(' · ');
  const inboundLabel = [safeHumanText(inbound.airline || '', 120), safeHumanText(inbound.flightNumbers || '', 120)].filter(Boolean).join(' · ');
  const origin = cleanText(route.originCode || input.originCode, 12) || '';
  const destination = cleanText(route.outboundDestination || input.arrivalAirportCode, 12) || '';

  push(start, 'Прилёт и встреча', outboundLabel || `${origin} → ${destination}`, 'airplane.arrival', destination);
  if (hotelNames.makkah) push(start, 'Заселение в отель', safeHumanText(hotelNames.makkah, 220) || '', 'building.2.fill', 'Makkah');

  const umrahDay = addItineraryDays(start, 1);
  if (!end || umrahDay <= end) push(umrahDay, 'Умра', 'Ихрам · таваф · са’й', 'moon.stars.fill', 'Masjid al-Haram');

  if (customization.ziyaratMakkah !== false) {
    const ziyaratMakkahDay = addItineraryDays(start, 2);
    if (!end || ziyaratMakkahDay <= end) push(ziyaratMakkahDay, 'Зиярат в Мекке', 'Маршрут святых мест', 'mappin.and.ellipse', 'Makkah');
  }

  const madinahCheckIn = itineraryDay(stay.madinahCheckIn);
  if (madinahCheckIn) {
    push(madinahCheckIn, 'Переезд в Медину', 'Междугородний трансфер', 'car.side.fill', 'Madinah');
    if (hotelNames.madinah) push(madinahCheckIn, 'Заселение в отель', safeHumanText(hotelNames.madinah, 220) || '', 'building.2.fill', 'Madinah');
    const madinahVisit = addItineraryDays(madinahCheckIn, 1);
    if (!end || madinahVisit <= end) push(madinahVisit, 'Зиярат в Медине', 'Мечеть Пророка ﷺ и места зиярата', 'building.columns.fill', 'Madinah');
  }

  if (end) push(end, 'Обратный рейс', inboundLabel || `${cleanText(route.returnOrigin, 12) || destination} → ${origin}`, 'airplane.departure', cleanText(route.returnOrigin, 12) || destination);

  if (!events.length) return;
  const now = new Date().toISOString();
  await env.HOTELS_DB.batch(events.map(item => env.HOTELS_DB.prepare(`INSERT INTO booking_itinerary_items (id,booking_id,date_local,sort_order,title,subtitle,icon,location,notes,created_at,updated_at) VALUES (?,?,?,?,?,?,?,?,?,?,?)`).bind(item.id, bookingID, item.dateLocal, item.sortOrder, item.title, item.subtitle, item.icon, item.location, item.notes, now, now)));
}

async function bookingItineraryDetail(env, bookingID, trip = null) {
  await seedBookingItineraryIfNeeded(env, bookingID, trip);
  const rows = await env.HOTELS_DB.prepare('SELECT * FROM booking_itinerary_items WHERE booking_id=? ORDER BY date_local ASC, sort_order ASC, created_at ASC').bind(bookingID).all();
  return json({ ok: true, bookingID, items: (rows.results || []).map(itineraryItemMap) });
}

async function saveBookingItinerary(request, env, bookingID) {
  await ensureBookingItinerarySchema(env);
  const trip = await env.HOTELS_DB.prepare('SELECT * FROM pilgrim_trips WHERE booking_id=? LIMIT 1').bind(bookingID).first();
  if (!trip) return json({ ok: false, error: 'BOOKING_NOT_SYNCED' }, 404);
  const payload = await request.json().catch(() => null);
  const rawItems = Array.isArray(payload?.items) ? payload.items : null;
  if (!rawItems) return json({ ok: false, error: 'ITEMS_REQUIRED' }, 400);
  if (rawItems.length > 80) return json({ ok: false, error: 'TOO_MANY_ITINERARY_ITEMS' }, 400);

  const snapshot = parseJSONObject(trip.booking_snapshot_json);
  const start = itineraryDay(trip.start_date || snapshot?.input?.startDate || snapshot?.startDate);
  const end = itineraryDay(trip.end_date || snapshot?.input?.endDate || snapshot?.endDate);
  const now = new Date().toISOString();
  const items = [];

  for (let index = 0; index < rawItems.length; index += 1) {
    const raw = rawItems[index] || {};
    const dateLocal = itineraryDay(raw.dateLocal || raw.date);
    if (!dateLocal) return json({ ok: false, error: 'INVALID_ITINERARY_DATE', index }, 400);
    if (start && dateLocal < start) return json({ ok: false, error: 'ITINERARY_DATE_BEFORE_TRIP', index }, 409);
    if (end && dateLocal > end) return json({ ok: false, error: 'ITINERARY_DATE_AFTER_TRIP', index }, 409);
    const title = safeHumanText(raw.title || '', 180);
    if (!title) return json({ ok: false, error: 'ITINERARY_TITLE_REQUIRED', index }, 400);
    const rawID = cleanText(raw.id, 120) || '';
    const id = /^[A-Za-z0-9_-]{6,120}$/.test(rawID) ? rawID : `iti-${crypto.randomUUID()}`;
    items.push({
      id,
      bookingID,
      dateLocal,
      sortOrder: Number.isFinite(Number(raw.sortOrder)) ? Math.max(0, Math.trunc(Number(raw.sortOrder))) : index,
      title,
      subtitle: safeHumanText(raw.subtitle || '', 320) || '',
      icon: cleanText(raw.icon, 80) || 'calendar',
      location: safeHumanText(raw.location || '', 180) || '',
      notes: safeHumanText(raw.notes || '', 1200) || '',
      createdAt: cleanText(raw.createdAt, 80) || now,
      updatedAt: now
    });
  }

  const statements = [env.HOTELS_DB.prepare('DELETE FROM booking_itinerary_items WHERE booking_id=?').bind(bookingID)];
  for (const item of items) {
    statements.push(env.HOTELS_DB.prepare(`INSERT INTO booking_itinerary_items (id,booking_id,date_local,sort_order,title,subtitle,icon,location,notes,created_at,updated_at) VALUES (?,?,?,?,?,?,?,?,?,?,?)`).bind(item.id, bookingID, item.dateLocal, item.sortOrder, item.title, item.subtitle, item.icon, item.location, item.notes, item.createdAt, item.updatedAt));
  }
  await env.HOTELS_DB.batch(statements);
  return bookingItineraryDetail(env, bookingID, trip);
}

function humanizeFieldKey(value) {
  return String(value || '')
    .replace(/([a-z0-9])([A-Z])/g, '$1 $2')
    .replace(/[_-]+/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
    .replace(/^./, char => char.toUpperCase());
}

function flattenPricingLines(value) {
  const lines = [];
  const currency = deepScalar(value, ['currency','currencyCode']) || 'USD';
  const walk = (node, path = [], depth = 0) => {
    if (depth > 5 || lines.length >= 120 || node == null) return;
    if (typeof node === 'number' && Number.isFinite(node)) {
      const key = path.join('.');
      if (/(price|cost|fee|commission|margin|visa|hotel|flight|air|guide|transfer|transport|sim|support|total|amount|service)/i.test(key) && !/(count|guests|traveler|rooms|nights|days|year)/i.test(key)) {
        lines.push({ id: key || `value-${lines.length}`, label: humanizeFieldKey(path[path.length - 1] || 'Amount'), group: humanizeFieldKey(path.slice(0, -1).join(' · ') || 'Pricing'), amount: node, currency });
      }
      return;
    }
    if (Array.isArray(node)) {
      node.forEach((child, index) => walk(child, [...path, String(index + 1)], depth + 1));
      return;
    }
    if (typeof node === 'object') Object.entries(node).forEach(([key, child]) => walk(child, [...path, key], depth + 1));
  };
  walk(value);
  return lines;
}

function flattenRequestFields(raw) {
  const fields = [];
  const skip = /(^|\.)(pricing|priceBreakdown|pricingBreakdown|costBreakdown|generationReport|quote)(\.|$)/i;
  const walk = (node, path = [], depth = 0) => {
    if (depth > 4 || fields.length >= 120 || node == null) return;
    if (typeof node === 'string' || typeof node === 'number' || typeof node === 'boolean') {
      const keyPath = path.join('.');
      if (!skip.test(keyPath) && String(node).trim() !== '') fields.push({ id: keyPath, label: humanizeFieldKey(path[path.length - 1] || 'Value'), group: humanizeFieldKey(path.slice(0, -1).join(' · ') || 'Booking'), value: String(node) });
      return;
    }
    if (Array.isArray(node)) {
      node.slice(0, 20).forEach((child, index) => walk(child, [...path, String(index + 1)], depth + 1));
      return;
    }
    if (typeof node === 'object') Object.entries(node).forEach(([key, child]) => walk(child, [...path, key], depth + 1));
  };
  walk(raw);
  return fields;
}

async function rawBookingForDetail(request, env, bookingID) {
  const trip = await env.HOTELS_DB.prepare('SELECT * FROM pilgrim_trips WHERE booking_id=? LIMIT 1').bind(bookingID).first();
  try {
    const bookings = await fetchUpstreamBookings(request, env);
    const raw = bookings.find(item => String(item?.id || '') === bookingID);
    if (raw) return { raw, linked: await syncBookingTrip(env, raw) };
  } catch (error) {
    console.warn('BOOKING_DETAIL_UPSTREAM_FALLBACK', error);
  }
  if (trip) {
    const raw = parseJSONObject(trip.booking_snapshot_json);
    const pilgrim = await env.HOTELS_DB.prepare('SELECT * FROM pilgrims WHERE id=?').bind(trip.pilgrim_id).first();
    return { raw, linked: { trip, pilgrim } };
  }
  return null;
}


async function ensureBookingPricingOverrideSchema(env) {
  await env.HOTELS_DB.prepare(`CREATE TABLE IF NOT EXISTS booking_pricing_overrides (
    booking_id TEXT PRIMARY KEY,
    currency TEXT NOT NULL DEFAULT 'USD',
    components_json TEXT NOT NULL DEFAULT '[]',
    markup_rate REAL NOT NULL DEFAULT 0.50,
    payment_fee_rate REAL NOT NULL DEFAULT 0.02,
    supplier_cost_usd REAL NOT NULL DEFAULT 0,
    markup_amount_usd REAL NOT NULL DEFAULT 0,
    subtotal_after_markup_usd REAL NOT NULL DEFAULT 0,
    payment_fee_amount_usd REAL NOT NULL DEFAULT 0,
    calculated_selling_price_usd REAL NOT NULL DEFAULT 0,
    public_price_per_pilgrim_usd REAL NOT NULL DEFAULT 0,
    public_total_usd REAL NOT NULL DEFAULT 0,
    rounding_difference_usd REAL NOT NULL DEFAULT 0,
    estimated_profit_usd REAL NOT NULL DEFAULT 0,
    traveler_count INTEGER NOT NULL DEFAULT 1,
    updated_by TEXT,
    updated_at TEXT NOT NULL
  )`).run();
}

function bookingPricingOverrideMap(row) {
  if (!row) return null;
  return {
    bookingID: row.booking_id,
    currency: row.currency || 'USD',
    components: (() => { try { const value = JSON.parse(row.components_json || '[]'); return Array.isArray(value) ? value : []; } catch { return []; } })(),
    markupRate: Number(row.markup_rate || 0),
    paymentFeeRate: Number(row.payment_fee_rate || 0),
    travelerCount: Math.max(1, Number(row.traveler_count || 1)),
    totals: {
      supplierCostUsd: Number(row.supplier_cost_usd || 0),
      markupRate: Number(row.markup_rate || 0),
      markupAmountUsd: Number(row.markup_amount_usd || 0),
      subtotalAfterMarkupUsd: Number(row.subtotal_after_markup_usd || 0),
      paymentFeeRate: Number(row.payment_fee_rate || 0),
      paymentFeeAmountUsd: Number(row.payment_fee_amount_usd || 0),
      calculatedSellingPriceUsd: Number(row.calculated_selling_price_usd || 0),
      publicPricePerPilgrimUsd: Number(row.public_price_per_pilgrim_usd || 0),
      publicTotalUsd: Number(row.public_total_usd || 0),
      roundingDifferenceUsd: Number(row.rounding_difference_usd || 0),
      estimatedProfitUsd: Number(row.estimated_profit_usd || 0)
    },
    updatedBy: row.updated_by || null,
    updatedAt: row.updated_at
  };
}

async function bookingPricingOverride(env, bookingID) {
  await ensureBookingPricingOverrideSchema(env);
  const row = await env.HOTELS_DB.prepare('SELECT * FROM booking_pricing_overrides WHERE booking_id=? LIMIT 1').bind(bookingID).first();
  return bookingPricingOverrideMap(row);
}

function reportWithPricingOverride(report, override) {
  if (!report || !override) return report;
  return {
    ...report,
    components: override.components,
    totals: override.totals,
    businessOverride: true
  };
}

async function bookingPricingOverrideDetail(request, env, bookingID) {
  const resolved = await rawBookingForDetail(request, env, bookingID);
  if (!resolved) return json({ ok: false, error: 'BOOKING_NOT_FOUND' }, 404);
  const pricingReport = await generatorPricingReportForBooking(env, bookingID, resolved.raw);
  if (!pricingReport) return json({ ok: false, error: 'GENERATOR_PRICING_NOT_FOUND' }, 409);
  const override = await bookingPricingOverride(env, bookingID);
  return json({ ok: true, pricing: override, basePricing: pricingReport });
}

function normalizedEditablePricingComponents(value, baseComponents) {
  const baseByCode = new Map((Array.isArray(baseComponents) ? baseComponents : []).map(item => [String(item?.code || ''), item]));
  if (!Array.isArray(value) || !value.length) return null;
  const output = [];
  const seen = new Set();
  for (const raw of value) {
    const code = cleanText(raw?.code, 80);
    if (!code || seen.has(code) || !baseByCode.has(code)) continue;
    const amount = Number(raw?.supplierCostUsd);
    if (!Number.isFinite(amount) || amount < 0 || amount > 1000000) return null;
    const base = baseByCode.get(code);
    output.push({ code, label: safeHumanText(base?.label || raw?.label || code, 180) || code, supplierCostUsd: Math.round(amount * 100) / 100 });
    seen.add(code);
  }
  // Every original component is required, so saving cannot silently drop a cost.
  if (output.length !== baseByCode.size) return null;
  return output;
}

async function syncPricingOverrideToSourceBooking(env, bookingID, override) {
  if (!env.BOOKINGS_DB) throw new Error('BOOKINGS_DB_NOT_CONFIGURED');
  const source = await sourceBookingPayload(env, bookingID);
  if (!source || !Object.keys(source).length) throw new Error('SOURCE_BOOKING_NOT_FOUND');
  source.totalUsd = override.totals.publicTotalUsd;
  source.perPilgrimUsd = override.totals.publicPricePerPilgrimUsd;
  source.businessPricingOverride = {
    currency: override.currency,
    components: override.components,
    markupRate: override.markupRate,
    paymentFeeRate: override.paymentFeeRate,
    totals: override.totals,
    updatedAt: override.updatedAt
  };
  const sourceColumns = await env.BOOKINGS_DB.prepare("PRAGMA table_info('bookings')").all().catch(() => ({ results: [] }));
  const sourceNames = new Set((sourceColumns.results || []).map(row => String(row?.name || '')));
  if (sourceNames.has('updated_at')) {
    await env.BOOKINGS_DB.prepare('UPDATE bookings SET payload_json=?, updated_at=? WHERE id=?').bind(JSON.stringify(source), override.updatedAt, bookingID).run();
  } else {
    await env.BOOKINGS_DB.prepare('UPDATE bookings SET payload_json=? WHERE id=?').bind(JSON.stringify(source), bookingID).run();
  }

  const trip = await env.HOTELS_DB.prepare('SELECT * FROM pilgrim_trips WHERE booking_id=? LIMIT 1').bind(bookingID).first().catch(() => null);
  if (trip) {
    const snapshot = parseJSONObject(trip.booking_snapshot_json);
    snapshot.totalUsd = override.totals.publicTotalUsd;
    snapshot.perPilgrimUsd = override.totals.publicPricePerPilgrimUsd;
    snapshot.businessPricingOverride = source.businessPricingOverride;
    const pricing = parseJSONObject(trip.pricing_snapshot_json);
    pricing.businessPricingOverride = source.businessPricingOverride;
    await env.HOTELS_DB.prepare('UPDATE pilgrim_trips SET booking_snapshot_json=?, pricing_snapshot_json=?, updated_at=? WHERE booking_id=?')
      .bind(JSON.stringify(snapshot), JSON.stringify(pricing), override.updatedAt, bookingID).run();
  }
}

async function saveBookingPricingOverride(request, env, bookingID, user) {
  const resolved = await rawBookingForDetail(request, env, bookingID);
  if (!resolved) return json({ ok: false, error: 'BOOKING_NOT_FOUND' }, 404);
  const report = await generatorPricingReportForBooking(env, bookingID, resolved.raw);
  if (!report) return json({ ok: false, error: 'GENERATOR_PRICING_NOT_FOUND' }, 409);
  const payload = await request.json().catch(() => null);
  if (!payload) return json({ ok: false, error: 'INVALID_JSON' }, 400);

  const components = normalizedEditablePricingComponents(payload.components, report.components);
  if (!components) return json({ ok: false, error: 'INVALID_PRICING_COMPONENTS' }, 400);
  const markupRate = Number(payload.markupRate);
  const paymentFeeRate = Number(payload.paymentFeeRate);
  if (!Number.isFinite(markupRate) || markupRate < 0 || markupRate > 5) return json({ ok: false, error: 'INVALID_MARKUP_RATE' }, 400);
  if (!Number.isFinite(paymentFeeRate) || paymentFeeRate < 0 || paymentFeeRate >= 0.5) return json({ ok: false, error: 'INVALID_PAYMENT_FEE_RATE' }, 400);

  const travelerCount = Math.max(1,
    Number(report?.context?.travelers?.adults || 0) +
    Number(report?.context?.travelers?.children || 0) +
    Number(report?.context?.travelers?.infants || 0)
  );
  const supplierCostUsd = components.reduce((sum, item) => sum + Number(item.supplierCostUsd || 0), 0);
  const markupAmountUsd = supplierCostUsd * markupRate;
  const subtotalAfterMarkupUsd = supplierCostUsd + markupAmountUsd;
  const calculatedSellingPriceUsd = subtotalAfterMarkupUsd / (1 - paymentFeeRate);
  const paymentFeeAmountUsd = calculatedSellingPriceUsd - subtotalAfterMarkupUsd;
  const publicPricePerPilgrimUsd = Math.max(5, Math.round((calculatedSellingPriceUsd / travelerCount) / 5) * 5);
  const publicTotalUsd = publicPricePerPilgrimUsd * travelerCount;
  const roundingDifferenceUsd = publicTotalUsd - calculatedSellingPriceUsd;
  const estimatedProfitUsd = publicTotalUsd - supplierCostUsd - paymentFeeAmountUsd;
  const now = new Date().toISOString();
  const updatedBy = cleanText(user?.login, 180) || null;

  await ensureBookingPricingOverrideSchema(env);
  await env.HOTELS_DB.prepare(`INSERT INTO booking_pricing_overrides (
    booking_id,currency,components_json,markup_rate,payment_fee_rate,supplier_cost_usd,markup_amount_usd,
    subtotal_after_markup_usd,payment_fee_amount_usd,calculated_selling_price_usd,public_price_per_pilgrim_usd,
    public_total_usd,rounding_difference_usd,estimated_profit_usd,traveler_count,updated_by,updated_at
  ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
  ON CONFLICT(booking_id) DO UPDATE SET
    currency=excluded.currency,components_json=excluded.components_json,markup_rate=excluded.markup_rate,
    payment_fee_rate=excluded.payment_fee_rate,supplier_cost_usd=excluded.supplier_cost_usd,
    markup_amount_usd=excluded.markup_amount_usd,subtotal_after_markup_usd=excluded.subtotal_after_markup_usd,
    payment_fee_amount_usd=excluded.payment_fee_amount_usd,calculated_selling_price_usd=excluded.calculated_selling_price_usd,
    public_price_per_pilgrim_usd=excluded.public_price_per_pilgrim_usd,public_total_usd=excluded.public_total_usd,
    rounding_difference_usd=excluded.rounding_difference_usd,estimated_profit_usd=excluded.estimated_profit_usd,
    traveler_count=excluded.traveler_count,updated_by=excluded.updated_by,updated_at=excluded.updated_at`)
    .bind(bookingID, report.currency || 'USD', JSON.stringify(components), markupRate, paymentFeeRate, supplierCostUsd, markupAmountUsd,
      subtotalAfterMarkupUsd, paymentFeeAmountUsd, calculatedSellingPriceUsd, publicPricePerPilgrimUsd, publicTotalUsd,
      roundingDifferenceUsd, estimatedProfitUsd, travelerCount, updatedBy, now).run();

  const override = await bookingPricingOverride(env, bookingID);
  await syncPricingOverrideToSourceBooking(env, bookingID, override);
  return json({ ok: true, pricing: override });
}

async function generatorPricingReport(env, raw) {
  const trace = raw?.generatorTrace && typeof raw.generatorTrace === 'object' ? raw.generatorTrace : {};
  const embedded = extractPricingSnapshot(raw);
  if (validGeneratorPricingReport(embedded)) {
    return { ...embedded, selection: embedded.selection || trace };
  }
  const quoteID = cleanText(trace?.quoteId || raw?.quoteId, 180);
  if (!quoteID) return null;
  let row;
  try { row = await env.HOTELS_DB.prepare('SELECT audit_json FROM package_quote_audits WHERE quote_id=? LIMIT 1').bind(quoteID).first(); }
  catch { return null; }
  const audit = parseJSONObject(row?.audit_json);
  if (!audit || !Object.keys(audit).length) return null;
  return { ...audit, selection: trace };
}


async function generatorPricingReportForBooking(env, bookingID, raw) {
  const trip = await env.HOTELS_DB.prepare('SELECT booking_snapshot_json,pricing_snapshot_json FROM pilgrim_trips WHERE booking_id=? LIMIT 1').bind(bookingID).first().catch(() => null);
  const snapshot = parseJSONObject(trip?.booking_snapshot_json);
  const storedPricing = parseJSONObject(trip?.pricing_snapshot_json);
  return generatorPricingReport(env, {
    ...snapshot,
    ...(raw && typeof raw === 'object' ? raw : {}),
    ...(validGeneratorPricingReport(storedPricing) ? { pricingSnapshot: storedPricing } : {})
  });
}

async function ensureIgnavUsageSchema(env) {
  await env.HOTELS_DB.prepare(`CREATE TABLE IF NOT EXISTS ignav_api_usage_monthly (
    period TEXT PRIMARY KEY,
    successful_requests INTEGER NOT NULL DEFAULT 0,
    first_success_at TEXT,
    last_success_at TEXT,
    updated_at TEXT NOT NULL
  )`).run();
}

async function businessIgnavUsage(env) {
  await ensureIgnavUsageSchema(env);
  const period = new Date().toISOString().slice(0, 7);
  const row = await env.HOTELS_DB.prepare('SELECT * FROM ignav_api_usage_monthly WHERE period=? LIMIT 1').bind(period).first();
  const requestedBudget = Number(env.IGNAV_MONTHLY_REQUEST_BUDGET || 3000);
  const monthlyBudget = Number.isFinite(requestedBudget) && requestedBudget > 0 ? Math.trunc(requestedBudget) : 3000;
  const successfulRequests = Math.max(0, Number(row?.successful_requests || 0));
  const remainingRequests = Math.max(0, monthlyBudget - successfulRequests);
  return json({
    ok: true,
    usage: {
      period,
      monthlyBudget,
      successfulRequests,
      remainingRequests,
      usedFraction: monthlyBudget > 0 ? successfulRequests / monthlyBudget : 0,
      firstSuccessAt: row?.first_success_at || null,
      lastSuccessAt: row?.last_success_at || null,
      trackingNote: 'Внутренний бюджет iumrah. Счётчик учитывает успешные ответы Ignav с момента установки этого обновления.'
    }
  });
}

async function operationsBookingDetail(request, env, bookingID) {
  const deleted = await env.HOTELS_DB.prepare('SELECT booking_id FROM booking_tombstones WHERE booking_id=? LIMIT 1').bind(bookingID).first().catch(() => null);
  if (deleted) return json({ ok: false, error: 'BOOKING_DELETED' }, 404);
  const resolved = await rawBookingForDetail(request, env, bookingID);
  if (!resolved) return json({ ok: false, error: 'BOOKING_NOT_FOUND' }, 404);
  const trip = await env.HOTELS_DB.prepare('SELECT * FROM pilgrim_trips WHERE booking_id=?').bind(bookingID).first();
  const pilgrim = trip ? await env.HOTELS_DB.prepare('SELECT * FROM pilgrims WHERE id=?').bind(trip.pilgrim_id).first() : null;
  const pricingSnapshot = trip ? parseJSONObject(trip.pricing_snapshot_json) : extractPricingSnapshot(resolved.raw);
  const pricingReportSource = trip ? { ...parseJSONObject(trip.booking_snapshot_json), ...resolved.raw } : resolved.raw;
  let pricingLines = flattenPricingLines(pricingSnapshot);
  if (!pricingLines.length) pricingLines = flattenPricingLines(resolved.raw);
  const [history, flightRows, assignment] = await Promise.all([
    env.HOTELS_DB.prepare('SELECT old_status, new_status, changed_by, created_at FROM booking_status_history WHERE booking_id=? ORDER BY created_at DESC LIMIT 50').bind(bookingID).all(),
    env.HOTELS_DB.prepare("SELECT * FROM trip_flights WHERE booking_id=? ORDER BY CASE direction WHEN 'outbound' THEN 0 ELSE 1 END").bind(bookingID).all(),
    bookingAssignmentDetail(env, bookingID)
  ]);
  return json({
    ok: true,
    booking: augmentBooking(resolved.raw, { trip, pilgrim }),
    operation: tripMap(trip),
    pilgrim: pilgrim ? { id: pilgrimPublicID(pilgrim.id), displayName: pilgrim.display_name || '', firstName: pilgrim.first_name || '', lastName: pilgrim.last_name || '', phone: pilgrim.phone || '', email: pilgrim.email || '', totalTrips: Number(pilgrim.total_trips || 0) } : null,
    pricingLines,
    pricingReport: reportWithPricingOverride(await generatorPricingReportForBooking(env, bookingID, pricingReportSource), await bookingPricingOverride(env, bookingID)),
    pricingOverride: await bookingPricingOverride(env, bookingID),
    requestFields: flattenRequestFields(resolved.raw),
    statusHistory: (history.results || []).map(row => ({ oldStatus: row.old_status || null, newStatus: row.new_status, changedBy: row.changed_by || null, createdAt: row.created_at })),
    flights: (flightRows.results || []).map(mapTripFlight),
    assignment,
    esims: await clientBookingEsimRows(env, bookingID, { syncIfStale: true }),
    checkout: await adminCheckoutDetail(env, bookingID, trip)
  });
}


const ESIM_PROVIDER_ESIM_ACCESS = 'esim_access';
const ESIM_USAGE_SYNC_TTL_MS = 60 * 1000;

function normalizedEsimProvider(value) {
  const provider = String(value || '').trim().toLowerCase().replace(/[^a-z0-9_-]/g, '');
  return provider || ESIM_PROVIDER_ESIM_ACCESS;
}

function esimNumber(value, fallback = 0) {
  const number = Number(value);
  return Number.isFinite(number) && number >= 0 ? number : fallback;
}

function normalizeLpaString(value, smdpAddress = '', activationCode = '') {
  const direct = String(value || '').trim();
  if (direct) return direct;
  const smdp = String(smdpAddress || '').trim();
  const code = String(activationCode || '').trim();
  return smdp && code ? `LPA:1$${smdp}$${code}` : '';
}

function lpaParts(value) {
  const text = String(value || '').trim();
  if (!/^LPA:1\$/i.test(text)) return { smdpAddress: '', activationCode: '' };
  const parts = text.split('$');
  return { smdpAddress: parts[1] || '', activationCode: parts[2] || '' };
}

function mapBookingEsim(row) {
  if (!row) return null;
  const totalMB = esimNumber(row.total_mb);
  const usedMB = esimNumber(row.used_mb);
  const remainingMB = row.remaining_mb == null ? Math.max(0, totalMB - usedMB) : esimNumber(row.remaining_mb);
  return {
    id: row.id,
    bookingID: row.booking_id,
    travelerPosition: row.traveler_position == null ? null : Number(row.traveler_position),
    label: row.label || 'Saudi Arabia eSIM',
    provider: row.provider || ESIM_PROVIDER_ESIM_ACCESS,
    providerEsimID: row.provider_esim_id || null,
    iccid: row.iccid || '',
    planName: row.plan_name || '',
    countryCode: row.country_code || 'SA',
    totalMB,
    usedMB,
    remainingMB,
    validityDays: row.validity_days == null ? null : Number(row.validity_days),
    status: row.status || 'ready',
    providerStatus: row.provider_status || null,
    providerSmdpStatus: row.provider_smdp_status || null,
    smdpAddress: row.smdp_address || '',
    activationCode: row.activation_code || '',
    lpaString: row.lpa_string || '',
    qrCodeURL: row.qr_code_url || null,
    activatedAt: row.activated_at || null,
    expiresAt: row.expires_at || null,
    lastUsageSyncAt: row.last_usage_sync_at || null,
    usageSource: row.usage_source || 'pending',
    createdAt: row.created_at || '',
    updatedAt: row.updated_at || ''
  };
}

async function bookingEsimRows(env, bookingID) {
  const rows = await env.HOTELS_DB.prepare('SELECT * FROM booking_esims WHERE booking_id=? ORDER BY COALESCE(traveler_position, 9999), created_at').bind(bookingID).all();
  return (rows.results || []).map(mapBookingEsim).filter(Boolean);
}

async function adminBookingEsims(env, bookingID) {
  return json({ ok: true, bookingID, esims: await clientBookingEsimRows(env, bookingID, { syncIfStale: true }) });
}

async function saveBookingEsim(request, env, bookingID, rawEsimID, user) {
  const trip = await env.HOTELS_DB.prepare('SELECT booking_id FROM pilgrim_trips WHERE booking_id=? LIMIT 1').bind(bookingID).first();
  if (!trip) return json({ ok: false, error: 'BOOKING_NOT_FOUND' }, 404);
  const payload = await request.json().catch(() => null);
  if (!payload) return json({ ok: false, error: 'INVALID_JSON' }, 400);

  const existingID = rawEsimID ? safeID(rawEsimID) : null;
  if (rawEsimID && !existingID) return json({ ok: false, error: 'INVALID_ESIM_ID' }, 400);
  if (existingID) {
    const existing = await env.HOTELS_DB.prepare('SELECT id FROM booking_esims WHERE id=? AND booking_id=? LIMIT 1').bind(existingID, bookingID).first();
    if (!existing) return json({ ok: false, error: 'ESIM_NOT_FOUND' }, 404);
  }

  const id = existingID || `esim-${crypto.randomUUID()}`;
  const now = new Date().toISOString();
  const travelerPositionRaw = payload.travelerPosition == null || payload.travelerPosition === '' ? null : Number(payload.travelerPosition);
  const travelerPosition = Number.isInteger(travelerPositionRaw) && travelerPositionRaw > 0 ? travelerPositionRaw : null;
  const provider = normalizedEsimProvider(payload.provider);
  const iccid = cleanText(payload.iccid, 80) || '';
  if (provider === ESIM_PROVIDER_ESIM_ACCESS && !iccid) return json({ ok: false, error: 'ESIM_ICCID_REQUIRED' }, 400);
  const planName = safeHumanText(payload.planName, 180) || '';
  const label = safeHumanText(payload.label, 180) || planName || 'Saudi Arabia eSIM';
  const countryCode = (cleanText(payload.countryCode, 8) || 'SA').toUpperCase();
  const smdpAddress = cleanText(payload.smdpAddress, 500) || '';
  const activationCode = cleanText(payload.activationCode, 500) || '';
  const lpaString = normalizeLpaString(payload.lpaString, smdpAddress, activationCode);
  const parsed = lpaParts(lpaString);
  const finalSmdp = smdpAddress || parsed.smdpAddress;
  const finalActivationCode = activationCode || parsed.activationCode;
  const providerEsimID = cleanText(payload.providerEsimID, 120) || null;
  const qrCodeURL = cleanText(payload.qrCodeURL, 1500) || null;
  const updatedBy = cleanText(user?.login, 180) || null;

  if (existingID) {
    await env.HOTELS_DB.prepare(`UPDATE booking_esims SET traveler_position=?,label=?,provider=?,provider_esim_id=?,iccid=?,plan_name=?,country_code=?,smdp_address=?,activation_code=?,lpa_string=?,qr_code_url=?,updated_by=?,updated_at=? WHERE id=? AND booking_id=?`)
      .bind(travelerPosition,label,provider,providerEsimID,iccid,planName,countryCode,finalSmdp,finalActivationCode,lpaString,qrCodeURL,updatedBy,now,id,bookingID).run();
  } else {
    await env.HOTELS_DB.prepare(`INSERT INTO booking_esims(id,booking_id,traveler_position,label,provider,provider_esim_id,iccid,plan_name,country_code,total_mb,used_mb,remaining_mb,validity_days,status,smdp_address,activation_code,lpa_string,qr_code_url,usage_source,updated_by,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`)
      .bind(id,bookingID,travelerPosition,label,provider,providerEsimID,iccid,planName,countryCode,0,0,0,null,'ready',finalSmdp,finalActivationCode,lpaString,qrCodeURL,'pending',updatedBy,now,now).run();
  }

  let row = await env.HOTELS_DB.prepare('SELECT * FROM booking_esims WHERE id=? AND booking_id=?').bind(id, bookingID).first();
  if (row && normalizedEsimProvider(row.provider) === ESIM_PROVIDER_ESIM_ACCESS && row.iccid && String(env.ESIM_ACCESS_CODE || '').trim()) {
    try { row = await syncEsimAccessRow(env, row); }
    catch (error) { console.warn('ESIM_AUTO_SYNC_AFTER_SAVE_FAILED', bookingID, id, String(error?.message || error)); }
  }
  return json({ ok: true, esim: mapBookingEsim(row) }, existingID ? 200 : 201);
}

async function deleteBookingEsim(env, bookingID, rawEsimID) {
  const esimID = safeID(rawEsimID);
  if (!esimID) return json({ ok: false, error: 'INVALID_ESIM_ID' }, 400);
  const result = await env.HOTELS_DB.prepare('DELETE FROM booking_esims WHERE id=? AND booking_id=?').bind(esimID, bookingID).run();
  if (!Number(result?.meta?.changes || 0)) return json({ ok: false, error: 'ESIM_NOT_FOUND' }, 404);
  return json({ ok: true, deletedEsimID: esimID });
}

function esimAccessProfileFromPayload(payload, iccid) {
  const candidateLists = [payload?.obj?.esimList, payload?.esimList, payload?.data?.esimList, payload?.obj?.list, payload?.data?.list];
  const list = candidateLists.find(Array.isArray) || [];
  return list.find(item => String(item?.iccid || '') === String(iccid || '')) || list[0] || null;
}

function bytesToMB(value) {
  const bytes = Number(value);
  return Number.isFinite(bytes) && bytes >= 0 ? bytes / (1024 * 1024) : 0;
}

async function syncEsimAccessRow(env, row) {
  const accessCode = String(env.ESIM_ACCESS_CODE || '').trim();
  if (!accessCode) throw new Error('ESIM_ACCESS_NOT_CONFIGURED');
  const iccid = String(row?.iccid || '').trim();
  if (!iccid) throw new Error('ESIM_ICCID_REQUIRED');

  const body = JSON.stringify({ iccid, pager: { pageNum: 1, pageSize: 20 } });
  const response = await fetch('https://api.esimaccess.com/api/v1/open/esim/list', {
    method: 'POST',
    headers: { 'content-type': 'application/json', 'RT-AccessCode': accessCode },
    body
  });
  const payload = await response.json().catch(() => null);
  if (!response.ok || !payload) throw new Error(`ESIM_ACCESS_HTTP_${response.status}`);
  const profile = esimAccessProfileFromPayload(payload, iccid);
  if (!profile) throw new Error('ESIM_ACCESS_PROFILE_NOT_FOUND');

  const totalMB = bytesToMB(profile.totalVolume);
  const usedMB = bytesToMB(profile.orderUsage);
  const remainingMB = Math.max(0, totalMB - usedMB);
  const lpaString = String(profile.ac || row.lpa_string || '').trim();
  const parsed = lpaParts(lpaString);
  const now = new Date().toISOString();
  const validityDays = Number.isFinite(Number(profile.totalDuration)) ? Math.max(0, Math.floor(Number(profile.totalDuration))) : row.validity_days;
  await env.HOTELS_DB.prepare(`UPDATE booking_esims SET provider_esim_id=COALESCE(?,provider_esim_id),total_mb=?,used_mb=?,remaining_mb=?,validity_days=?,status=?,provider_status=?,provider_smdp_status=?,smdp_address=CASE WHEN smdp_address='' THEN ? ELSE smdp_address END,activation_code=CASE WHEN activation_code='' THEN ? ELSE activation_code END,lpa_string=CASE WHEN lpa_string='' THEN ? ELSE lpa_string END,qr_code_url=COALESCE(?,qr_code_url),expires_at=COALESCE(?,expires_at),last_usage_sync_at=?,usage_source='provider',updated_at=? WHERE id=? AND booking_id=?`)
    .bind(
      cleanText(profile.esimTranNo, 120) || null,
      totalMB, usedMB, remainingMB, validityDays,
      cleanText(profile.esimStatus, 60) || row.status || 'ready',
      cleanText(profile.esimStatus, 60) || null,
      cleanText(profile.smdpStatus, 60) || null,
      parsed.smdpAddress,
      parsed.activationCode,
      lpaString,
      cleanText(profile.qrCodeUrl, 1500) || null,
      cleanText(profile.expiredTime, 80) || null,
      now, now, row.id, row.booking_id
    ).run();
  return env.HOTELS_DB.prepare('SELECT * FROM booking_esims WHERE id=? AND booking_id=?').bind(row.id, row.booking_id).first();
}

async function syncBookingEsim(request, env, bookingID, rawEsimID) {
  const esimID = safeID(rawEsimID);
  if (!esimID) return json({ ok: false, error: 'INVALID_ESIM_ID' }, 400);
  let row = await env.HOTELS_DB.prepare('SELECT * FROM booking_esims WHERE id=? AND booking_id=? LIMIT 1').bind(esimID, bookingID).first();
  if (!row) return json({ ok: false, error: 'ESIM_NOT_FOUND' }, 404);
  if (normalizedEsimProvider(row.provider) !== ESIM_PROVIDER_ESIM_ACCESS) return json({ ok: false, error: 'ESIM_PROVIDER_SYNC_UNSUPPORTED' }, 409);
  try {
    row = await syncEsimAccessRow(env, row);
    return json({ ok: true, esim: mapBookingEsim(row) });
  } catch (error) {
    console.error('ESIM_USAGE_SYNC_FAILED', bookingID, esimID, error);
    const code = String(error?.message || 'ESIM_USAGE_SYNC_FAILED');
    return json({ ok: false, error: code }, code === 'ESIM_ACCESS_NOT_CONFIGURED' ? 503 : 502);
  }
}

function esimSyncIsStale(row) {
  if (!row?.last_usage_sync_at) return true;
  const when = Date.parse(row.last_usage_sync_at);
  return !Number.isFinite(when) || Date.now() - when >= ESIM_USAGE_SYNC_TTL_MS;
}

async function clientBookingEsimRows(env, bookingID, options = {}) {
  let rows = (await env.HOTELS_DB.prepare('SELECT * FROM booking_esims WHERE booking_id=? ORDER BY COALESCE(traveler_position, 9999), created_at').bind(bookingID).all()).results || [];
  if (options.syncIfStale && String(env.ESIM_ACCESS_CODE || '').trim()) {
    const refreshed = [];
    for (const row of rows) {
      if (normalizedEsimProvider(row.provider) === ESIM_PROVIDER_ESIM_ACCESS && row.iccid && esimSyncIsStale(row)) {
        try { refreshed.push(await syncEsimAccessRow(env, row)); }
        catch (error) { console.warn('ESIM_BACKGROUND_SYNC_SKIPPED', bookingID, row.id, String(error?.message || error)); refreshed.push(row); }
      } else refreshed.push(row);
    }
    rows = refreshed;
  }
  return rows.map(mapBookingEsim).filter(Boolean);
}

async function clientBookingEsims(env, bookingID) {
  return json({ ok: true, bookingID, esims: await clientBookingEsimRows(env, bookingID, { syncIfStale: true }) });
}


async function adminCheckoutDetail(env, bookingID, trip) {
  if (!trip) return null;
  await ensureTravelerRows(env, bookingID, trip);
  const [travelers, payment, receipts, documents, account] = await Promise.all([
    env.HOTELS_DB.prepare('SELECT * FROM booking_travelers WHERE booking_id=? ORDER BY position').bind(bookingID).all(),
    env.HOTELS_DB.prepare('SELECT * FROM booking_payment_instructions WHERE booking_id=?').bind(bookingID).first(),
    env.HOTELS_DB.prepare('SELECT id,payment_method,note,review_status,created_at,content_type FROM booking_payment_receipts WHERE booking_id=? ORDER BY created_at DESC').bind(bookingID).all(),
    env.HOTELS_DB.prepare('SELECT id,document_kind,title,content_type,created_at FROM booking_travel_documents WHERE booking_id=? ORDER BY created_at').bind(bookingID).all(),
    env.HOTELS_DB.prepare('SELECT activated_at,last_login_at FROM iumrah_accounts WHERE pilgrim_id=?').bind(trip.pilgrim_id).first()
  ]);
  const travelerItems = (travelers.results || []).map(row => ({
    ...travelerMap(row),
    passportMediaURL: row.passport_object_key ? `/api/admin/hotels/operations/bookings/${encodeURIComponent(bookingID)}/travelers/${Number(row.position)}/passport` : null
  }));
  return {
    iumrahID: pilgrimPublicID(trip.pilgrim_id),
    accountActive: !!account,
    activatedAt: account?.activated_at || null,
    allTravelersComplete: travelerItems.length > 0 && travelerItems.every(item => item.completed),
    travelers: travelerItems,
    payment: {
      visaCardNumber: payment?.visa_card_number || '',
      visaHolder: payment?.visa_holder || '',
      hasPaymeQR: !!payment?.payme_qr_object_key,
      humoCardNumber: payment?.humo_card_number || '',
      humoHolder: payment?.humo_holder || '',
      instructions: payment?.instructions || ''
    },
    receipts: (receipts.results || []).map(r => ({
      id: r.id,
      paymentMethod: r.payment_method || 'other',
      note: r.note || '',
      reviewStatus: r.review_status || 'submitted',
      createdAt: r.created_at || '',
      contentType: r.content_type || null,
      mediaURL: `/api/admin/hotels/operations/bookings/${encodeURIComponent(bookingID)}/receipt/media?id=${encodeURIComponent(r.id)}`
    })),
    documents: (documents.results || []).map(d => ({
      id: d.id,
      documentKind: d.document_kind || 'other',
      title: d.title || 'Документ поездки',
      contentType: d.content_type || 'application/octet-stream',
      createdAt: d.created_at || '',
      mediaURL: `/api/admin/hotels/operations/bookings/${encodeURIComponent(bookingID)}/documents/${encodeURIComponent(d.id)}`
    }))
  };
}

async function saveBookingPaymentInstructions(request, env, bookingID, user) {
  const trip=await env.HOTELS_DB.prepare('SELECT status FROM pilgrim_trips WHERE booking_id=?').bind(bookingID).first();
  if(!trip||!['availability_check','payment_pending'].includes(normalizedTripStatus(trip.status))) return json({ok:false,error:'PAYMENT_INSTRUCTIONS_LOCKED'},409);
  const payload = await request.json().catch(() => null);
  if (!payload) return json({ok:false,error:'INVALID_JSON'},400);
  const visaCard = cleanText(payload.visaCardNumber, 80) || '';
  const visaHolder = safeHumanText(payload.visaHolder, 160) || '';
  const humoCard = cleanText(payload.humoCardNumber, 80) || '';
  const humoHolder = safeHumanText(payload.humoHolder, 160) || '';
  const instructions = safeHumanText(payload.instructions, 1500) || '';
  const now = new Date().toISOString();
  await env.HOTELS_DB.prepare(`INSERT INTO booking_payment_instructions(booking_id,visa_card_number,visa_holder,humo_card_number,humo_holder,instructions,updated_by,updated_at) VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(booking_id) DO UPDATE SET visa_card_number=excluded.visa_card_number,visa_holder=excluded.visa_holder,humo_card_number=excluded.humo_card_number,humo_holder=excluded.humo_holder,instructions=excluded.instructions,updated_by=excluded.updated_by,updated_at=excluded.updated_at`)
    .bind(bookingID,visaCard,visaHolder,humoCard,humoHolder,instructions,cleanText(user?.login,180),now).run();
  return json({ok:true,checkout:await adminCheckoutDetail(env,bookingID,await env.HOTELS_DB.prepare('SELECT * FROM pilgrim_trips WHERE booking_id=?').bind(bookingID).first())});
}

async function uploadBookingPaymeQR(request, env, bookingID, user) {
  const trip=await env.HOTELS_DB.prepare('SELECT status FROM pilgrim_trips WHERE booking_id=?').bind(bookingID).first();
  if(!trip||!['availability_check','payment_pending'].includes(normalizedTripStatus(trip.status))) return json({ok:false,error:'PAYMENT_INSTRUCTIONS_LOCKED'},409);
  const up = await privateImageUpload(request, env, `payment-qr/${bookingID}`); if (!up.ok) return up.response;
  const current = await env.HOTELS_DB.prepare('SELECT payme_qr_object_key FROM booking_payment_instructions WHERE booking_id=?').bind(bookingID).first();
  const now=new Date().toISOString();
  await env.HOTELS_DB.prepare(`INSERT INTO booking_payment_instructions(booking_id,payme_qr_object_key,payme_qr_content_type,updated_by,updated_at) VALUES(?,?,?,?,?) ON CONFLICT(booking_id) DO UPDATE SET payme_qr_object_key=excluded.payme_qr_object_key,payme_qr_content_type=excluded.payme_qr_content_type,updated_by=excluded.updated_by,updated_at=excluded.updated_at`).bind(bookingID,up.key,up.ct,cleanText(user?.login,180),now).run();
  if(current?.payme_qr_object_key) await env.HOTELS_MEDIA.delete(current.payme_qr_object_key).catch(()=>{});
  return json({ok:true});
}

async function serveAdminPaymentReceipt(env, bookingID, receiptID) {
  const id=safeID(receiptID); if(!id)return json({ok:false,error:'INVALID_RECEIPT'},400);
  const row=await env.HOTELS_DB.prepare('SELECT object_key,content_type FROM booking_payment_receipts WHERE id=? AND booking_id=?').bind(id,bookingID).first();
  if(!row)return json({ok:false,error:'RECEIPT_NOT_FOUND'},404); const obj=await env.HOTELS_MEDIA.get(row.object_key); if(!obj)return json({ok:false,error:'RECEIPT_NOT_FOUND'},404);
  return new Response(obj.body,{headers:{'content-type':row.content_type||'image/jpeg','cache-control':'private, no-store'}});
}

async function serveAdminTravelerPassport(env, bookingID, position) {
  if (!Number.isInteger(position) || position < 1) return json({ok:false,error:'INVALID_TRAVELER'},400);
  const row = await env.HOTELS_DB.prepare('SELECT passport_object_key,passport_content_type FROM booking_travelers WHERE booking_id=? AND position=?').bind(bookingID,position).first();
  if (!row?.passport_object_key) return json({ok:false,error:'PASSPORT_NOT_FOUND'},404);
  const obj = await env.HOTELS_MEDIA.get(row.passport_object_key);
  if (!obj) return json({ok:false,error:'PASSPORT_NOT_FOUND'},404);
  return new Response(obj.body,{headers:{'content-type':row.passport_content_type||'image/jpeg','cache-control':'private, no-store'}});
}

async function uploadBookingTravelDocument(request, env, bookingID, user, url) {
  const kind=cleanText(url.searchParams.get('kind'),32)||'other'; if(!['visa','voucher','insurance','ticket','other'].includes(kind))return json({ok:false,error:'INVALID_DOCUMENT_KIND'},400);
  const title=safeHumanText(url.searchParams.get('title'),180)||'Документ поездки';
  const ct=String(request.headers.get('content-type')||'').split(';')[0].trim().toLowerCase();
  if(!(ct==='application/pdf'||ct.startsWith('image/')))return json({ok:false,error:'DOCUMENT_REQUIRED'},415);
  const bytes=await request.arrayBuffer(); if(!bytes.byteLength||bytes.byteLength>15_000_000)return json({ok:false,error:'DOCUMENT_TOO_LARGE'},413);
  const ext=ct==='application/pdf'?'pdf':ct.includes('png')?'png':'jpg'; const id=crypto.randomUUID(); const key=`private/travel-documents/${bookingID}/${id}.${ext}`;
  await env.HOTELS_MEDIA.put(key,bytes,{httpMetadata:{contentType:ct}});
  await env.HOTELS_DB.prepare('INSERT INTO booking_travel_documents(id,booking_id,document_kind,title,object_key,content_type,byte_size,created_by) VALUES(?,?,?,?,?,?,?,?)').bind(id,bookingID,kind,title,key,ct,bytes.byteLength,cleanText(user?.login,180)).run();
  await sendClientPush(env,bookingID,'Документ поездки готов',title,{type:'travel_document',bookingID}).catch(()=>{});
  return json({ok:true,id});
}
async function serveAdminTravelDocument(env,bookingID,id){const safe=safeID(id);if(!safe)return json({ok:false,error:'INVALID_DOCUMENT'},400);const row=await env.HOTELS_DB.prepare('SELECT object_key,content_type FROM booking_travel_documents WHERE id=? AND booking_id=?').bind(safe,bookingID).first();if(!row)return json({ok:false,error:'DOCUMENT_NOT_FOUND'},404);const obj=await env.HOTELS_MEDIA.get(row.object_key);if(!obj)return json({ok:false,error:'DOCUMENT_NOT_FOUND'},404);return new Response(obj.body,{headers:{'content-type':row.content_type,'cache-control':'private, no-store'}});}

function sourceStatusFromTripStatus(value) {
  const map = { availability_check:'AVAILABILITY_CHECK', payment_pending:'PAYMENT_PENDING', booking_confirmed:'BOOKING_CONFIRMED', ready_to_travel:'READY_TO_TRAVEL', in_trip:'IN_TRIP', completed:'COMPLETED', cancelled:'CANCELLED' };
  return map[String(value || '')] || 'AVAILABILITY_CHECK';
}

async function persistSourceBookingStatus(env, bookingID, status) {
  if (!env.BOOKINGS_DB) throw new Error('BOOKINGS_DB_NOT_CONFIGURED');
  const columns = await env.BOOKINGS_DB.prepare("PRAGMA table_info('bookings')").all();
  const names = new Set((columns.results || []).map(row => String(row?.name || '')));
  if (!names.has('status')) throw new Error('BOOKINGS_SOURCE_STATUS_COLUMN_MISSING');
  const now = new Date().toISOString();
  const sourceStatus = sourceStatusFromTripStatus(status);
  const sql = names.has('updated_at')
    ? 'UPDATE bookings SET status=?, updated_at=? WHERE id=?'
    : 'UPDATE bookings SET status=? WHERE id=?';
  const result = names.has('updated_at')
    ? await env.BOOKINGS_DB.prepare(sql).bind(sourceStatus, now, bookingID).run()
    : await env.BOOKINGS_DB.prepare(sql).bind(sourceStatus, bookingID).run();
  if (Number(result?.meta?.changes ?? 0) < 1) throw new Error('BOOKING_NOT_FOUND_IN_SOURCE_DB');
  if (names.has('payload_json')) {
    await env.BOOKINGS_DB.prepare(
      `UPDATE bookings SET payload_json=json_set(payload_json,'$.status',?) WHERE id=? AND json_valid(payload_json)=1`
    ).bind(sourceStatus, bookingID).run().catch(error => console.warn('BOOKING_PAYLOAD_STATUS_SYNC_FAILED', bookingID, error));
  }
  const persisted = await env.BOOKINGS_DB.prepare('SELECT status FROM bookings WHERE id=? LIMIT 1').bind(bookingID).first();
  if (!persisted || String(persisted.status || '').toUpperCase() !== sourceStatus) throw new Error('BOOKING_SOURCE_STATUS_NOT_PERSISTED');
  return sourceStatus;
}

async function updateOperationsBooking(request, env, bookingID, user) {
  const trip = await env.HOTELS_DB.prepare('SELECT * FROM pilgrim_trips WHERE booking_id=?').bind(bookingID).first();
  if (!trip) return json({ ok: false, error: 'BOOKING_NOT_SYNCED' }, 404);
  const payload = await request.json().catch(() => null);
  if (!payload) return json({ ok: false, error: 'INVALID_JSON' }, 400);
  const nextStatus = cleanText(payload?.status, 80) || trip.status;
  if (!TRIP_STATUSES.has(nextStatus)) return json({ ok: false, error: 'INVALID_TRIP_STATUS' }, 400);
  const currentStatus = normalizedTripStatus(trip.status);
  if (!(TRIP_TRANSITIONS[currentStatus] || new Set([currentStatus])).has(nextStatus)) {
    return json({ ok:false, error:'INVALID_STATUS_TRANSITION' }, 409);
  }
  const paymentStatus = safeHumanText(payload?.paymentStatus ?? trip.payment_status ?? '', 160) || '';
  const confirmationNumber = safeHumanText(payload?.confirmationNumber ?? trip.confirmation_number ?? '', 200) || '';
  const internalNotes = safeHumanText(payload?.internalNotes ?? trip.internal_notes ?? '', 4000) || '';
  const now = new Date().toISOString();
  const completedAt = nextStatus === 'completed' ? (trip.completed_at || now) : null;

  if (nextStatus === 'payment_pending' && nextStatus !== currentStatus) {
    const payment = await env.HOTELS_DB.prepare('SELECT visa_card_number,humo_card_number,payme_qr_object_key FROM booking_payment_instructions WHERE booking_id=? LIMIT 1').bind(bookingID).first();
    if (!(payment?.visa_card_number || payment?.humo_card_number || payment?.payme_qr_object_key)) {
      return json({ ok:false, error:'PAYMENT_INSTRUCTIONS_REQUIRED' }, 409);
    }
  }

  if (nextStatus === 'booking_confirmed' && nextStatus !== currentStatus) {
    await ensureTravelerRows(env, bookingID, trip);
    const readiness = await adminCheckoutDetail(env, bookingID, trip);
    if (!readiness?.accountActive) return json({ ok:false, error:'IUMRAH_ACCOUNT_REQUIRED' }, 409);
    if (!readiness?.allTravelersComplete) return json({ ok:false, error:'TRAVELER_DATA_INCOMPLETE' }, 409);
    if (!(readiness?.receipts || []).length) return json({ ok:false, error:'PAYMENT_RECEIPT_REQUIRED' }, 409);
  }
  if (nextStatus === 'ready_to_travel' && nextStatus !== currentStatus) {
    const docs = await env.HOTELS_DB.prepare('SELECT COUNT(*) AS count FROM booking_travel_documents WHERE booking_id=?').bind(bookingID).first();
    if (Number(docs?.count || 0) < 1) return json({ ok:false, error:'TRAVEL_DOCUMENT_REQUIRED' }, 409);
  }

  // The status is canonical across both databases: the customer booking row and
  // the Business operational mirror. This keeps filters, Beta and staff screens
  // on the same value instead of maintaining two drifting statuses.
  if (nextStatus !== currentStatus) {
    try {
      await persistSourceBookingStatus(env, bookingID, nextStatus);
    } catch (error) {
      console.error('BOOKING_SOURCE_STATUS_UPDATE_FAILED', bookingID, error);
      return json({ ok: false, error: cleanText(error?.message, 180) || 'BOOKING_SOURCE_STATUS_UPDATE_FAILED' }, 500);
    }
  }

  const updateResult = await env.HOTELS_DB.prepare(`UPDATE pilgrim_trips SET status=?, payment_status=?, confirmation_number=?, internal_notes=?, completed_at=?, updated_at=? WHERE booking_id=?`)
    .bind(nextStatus, paymentStatus, confirmationNumber, internalNotes, completedAt, now, bookingID).run();
  if (Number(updateResult?.meta?.changes ?? 0) < 1) {
    if (nextStatus !== currentStatus) await persistSourceBookingStatus(env, bookingID, currentStatus).catch(() => {});
    return json({ ok: false, error: 'BOOKING_STATUS_UPDATE_NOT_PERSISTED' }, 500);
  }

  const persisted = await env.HOTELS_DB.prepare('SELECT status, payment_status, confirmation_number, internal_notes FROM pilgrim_trips WHERE booking_id=? LIMIT 1').bind(bookingID).first();
  if (!persisted || String(persisted.status || '') !== nextStatus) {
    if (nextStatus !== currentStatus) await persistSourceBookingStatus(env, bookingID, currentStatus).catch(() => {});
    console.error('BOOKING_STATUS_VERIFY_FAILED', bookingID, { expected: nextStatus, actual: persisted?.status || null });
    return json({ ok: false, error: 'BOOKING_STATUS_UPDATE_NOT_PERSISTED' }, 500);
  }

  if (nextStatus !== currentStatus) {
    await env.HOTELS_DB.prepare('INSERT INTO booking_status_history (id, booking_id, old_status, new_status, changed_by, created_at) VALUES (?, ?, ?, ?, ?, ?)')
      .bind(crypto.randomUUID(), bookingID, currentStatus, nextStatus, cleanText(user?.login, 180), now).run();
    await sendClientStatusPush(env, bookingID, nextStatus).catch(error => console.warn('CLIENT_STATUS_PUSH_FAILED', bookingID, error));
  }

  return operationsBookingDetail(request, env, bookingID);
}

async function listPilgrims(env, url) {
  const archiveOnly = url.searchParams.get('archive') === '1';
  const search = cleanText(url.searchParams.get('q'), 120);
  const where = [];
  const values = [];
  if (archiveOnly) where.push("EXISTS (SELECT 1 FROM pilgrim_trips t WHERE t.pilgrim_id=p.id AND t.status='completed')");
  if (search) {
    where.push("(LOWER(p.display_name) LIKE LOWER(?) OR LOWER(p.email) LIKE LOWER(?) OR p.phone LIKE ? OR printf('%06d', p.id) LIKE ?)");
    const q = `%${search}%`; values.push(q,q,q,q);
  }
  const result = await env.HOTELS_DB.prepare(`
    SELECT p.*, (SELECT COUNT(*) FROM pilgrim_trips t WHERE t.pilgrim_id=p.id AND t.status='completed') AS completed_trips
    FROM pilgrims p ${where.length ? `WHERE ${where.join(' AND ')}` : ''}
    ORDER BY COALESCE(p.last_trip_at,p.updated_at) DESC LIMIT 500
  `).bind(...values).all();
  return json({ ok: true, pilgrims: (result.results || []).map(row => ({ id: pilgrimPublicID(row.id), displayName: row.display_name || '', firstName: row.first_name || '', lastName: row.last_name || '', phone: row.phone || '', email: row.email || '', totalTrips: Number(row.total_trips || 0), completedTrips: Number(row.completed_trips || 0), lastTripAt: row.last_trip_at || null })) });
}

function parsePilgrimPublicID(value) {
  const text = String(value || '').trim();
  const match = text.match(/^(\d{6})$/);
  return match ? Number(match[1]) : null;
}

async function pilgrimDetail(env, publicID) {
  const numericID = parsePilgrimPublicID(publicID);
  if (!numericID) return json({ ok: false, error: 'INVALID_PILGRIM_ID' }, 400);
  const pilgrim = await env.HOTELS_DB.prepare('SELECT * FROM pilgrims WHERE id=?').bind(numericID).first();
  if (!pilgrim) return json({ ok: false, error: 'PILGRIM_NOT_FOUND' }, 404);
  const trips = await env.HOTELS_DB.prepare('SELECT * FROM pilgrim_trips WHERE pilgrim_id=? ORDER BY created_at DESC').bind(numericID).all();
  return json({ ok: true, pilgrim: { id: pilgrimPublicID(pilgrim.id), displayName: pilgrim.display_name || '', firstName: pilgrim.first_name || '', lastName: pilgrim.last_name || '', phone: pilgrim.phone || '', email: pilgrim.email || '', totalTrips: Number(pilgrim.total_trips || 0), lastTripAt: pilgrim.last_trip_at || null }, trips: (trips.results || []).map(tripMap) });
}

async function adminPrimaryHotels(env, url) {
  const city = cleanText(url.searchParams.get('city'), 80);
  const values = [];
  const where = [];
  if (city) { where.push('LOWER(p.city)=LOWER(?)'); values.push(city); }
  const result = await env.HOTELS_DB.prepare(`
    SELECT p.city, p.star_category, p.position, h.id, h.name, h.stars, h.rating, h.review_count, h.status, h.lifecycle_state, h.updated_at,
      (SELECT COUNT(*) FROM hotel_images hi WHERE hi.hotel_id=h.id) AS image_count,
      (SELECT COUNT(*) FROM hotel_rooms hr WHERE hr.hotel_id=h.id) AS room_count,
      (SELECT hi.id FROM hotel_images hi WHERE hi.hotel_id=h.id ORDER BY hi.is_cover DESC, hi.position ASC LIMIT 1) AS cover_image_id
    FROM primary_hotels p JOIN hotels h ON h.id=p.hotel_id
    ${where.length ? `WHERE ${where.join(' AND ')}` : ''}
    ORDER BY p.city, p.star_category, p.position
  `).bind(...values).all();
  return json({ ok: true, assignments: (result.results || []).map(row => ({ city: row.city, stars: Number(row.star_category), position: Number(row.position), hotel: hotelSummary(row) })) });
}

async function savePrimaryHotels(request, env) {
  const payload = await request.json().catch(() => null);
  const city = safeHumanText(payload?.city, 80);
  const stars = Number(payload?.stars);
  const hotelIDs = Array.isArray(payload?.hotelIDs) ? [...new Set(payload.hotelIDs.map(value => safeID(value)).filter(Boolean))].slice(0,3) : [];
  if (!city || !Number.isInteger(stars) || stars < 1 || stars > 5) return json({ ok: false, error: 'INVALID_PRIMARY_CATEGORY' }, 400);
  const valid = [];
  for (const id of hotelIDs) {
    const hotel = await env.HOTELS_DB.prepare("SELECT id, city FROM hotels WHERE id=? AND status='published' LIMIT 1").bind(id).first();
    if (!hotel) return json({ ok: false, error: `HOTEL_NOT_PUBLISHED:${id}` }, 409);
    if (String(hotel.city || '').toLowerCase() !== city.toLowerCase()) return json({ ok: false, error: `HOTEL_CITY_MISMATCH:${id}` }, 409);
    valid.push(id);
  }
  const statements = [env.HOTELS_DB.prepare('DELETE FROM primary_hotels WHERE LOWER(city)=LOWER(?) AND star_category=?').bind(city, stars)];
  const now = new Date().toISOString();
  valid.forEach((id, index) => statements.push(env.HOTELS_DB.prepare('INSERT INTO primary_hotels (city, star_category, position, hotel_id, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)').bind(city, stars, index + 1, id, now, now)));
  await env.HOTELS_DB.batch(statements);
  return adminPrimaryHotels(env, new URL(`https://iumrah.app/api/admin/hotels/operations/primary-hotels?city=${encodeURIComponent(city)}`));
}

async function publicPrimaryHotels(env, url) {
  const city = safeHumanText(url.searchParams.get('city'), 80);
  const stars = Number(url.searchParams.get('stars'));
  if (!city || !Number.isInteger(stars) || stars < 1 || stars > 5) return json({ ok: false, error: 'CITY_AND_STARS_REQUIRED' }, 400);
  const result = await env.HOTELS_DB.prepare(`
    SELECT p.position, h.id, h.name, h.city, h.stars, h.rating, h.review_count, h.status, h.lifecycle_state, h.updated_at,
      (SELECT COUNT(*) FROM hotel_images hi WHERE hi.hotel_id=h.id) AS image_count,
      (SELECT COUNT(*) FROM hotel_rooms hr WHERE hr.hotel_id=h.id) AS room_count,
      (SELECT hi.id FROM hotel_images hi WHERE hi.hotel_id=h.id ORDER BY hi.is_cover DESC, hi.position ASC LIMIT 1) AS cover_image_id
    FROM primary_hotels p JOIN hotels h ON h.id=p.hotel_id
    WHERE LOWER(p.city)=LOWER(?) AND p.star_category=? AND h.status='published'
    ORDER BY p.position ASC
  `).bind(city, stars).all();
  return json({ ok: true, city, stars, recommendationLabel: 'Рекомендует iumrah', hotels: (result.results || []).map(row => ({ ...hotelSummary(row), primaryPosition: Number(row.position) })) }, 200, PUBLIC_CACHE_HEADERS);
}

async function handleClientOperations(request, env, parts) {
  if (parts[0] === 'account') return handleClientAccount(request, env, parts.slice(1));

  if (parts[0] === 'trips') {
    if (parts.length === 1 && request.method === 'GET') {
      const auth = await requireIumrahAccount(request, env); if (!auth.ok) return auth.response;
      return listAccountTrips(env, auth.pilgrim.id);
    }
    const bookingID = cleanText(parts[1],180); if (!bookingID) return json({ok:false,error:'INVALID_BOOKING_ID'},400);
    if (parts.length === 3 && parts[2] === 'sync' && request.method === 'POST') {
      const auth = await requireBookingToken(request, env, bookingID, {syncTrip:true}); if (!auth.ok) return auth.response;
      return syncBookingProfileByToken(request, env, bookingID, auth);
    }
    if (parts.length === 2 && request.method === 'GET') {
      const auth = await requireClientBooking(request, env, bookingID); if (!auth.ok) return auth.response;
      return clientTripDetail(env, bookingID, auth.trip);
    }
    if (parts.length === 3 && parts[2] === 'itinerary' && request.method === 'GET') {
      const auth = await requireClientBooking(request, env, bookingID); if (!auth.ok) return auth.response;
      return bookingItineraryDetail(env, bookingID, auth.trip);
    }
    if (parts.length === 3 && parts[2] === 'esims' && request.method === 'GET') {
      const auth = await requireClientBooking(request, env, bookingID); if (!auth.ok) return auth.response;
      return clientBookingEsims(env, bookingID);
    }
    if (parts.length === 3 && parts[2] === 'checkout' && request.method === 'GET') {
      const auth=await requireClientBooking(request,env,bookingID); if(!auth.ok)return auth.response;
      return clientCheckoutDetail(env,bookingID,auth.trip);
    }
    if (parts.length === 4 && parts[2] === 'travelers' && request.method === 'PUT') {
      const auth=await requireIumrahBookingAccount(request,env,bookingID); if(!auth.ok)return auth.response;
      return saveTravelerForm(request,env,bookingID,Number(parts[3]),auth);
    }
    if (parts.length === 4 && parts[2] === 'travelers' && parts[3] === 'passport' && request.method === 'POST') return methodNotAllowed();
    if (parts.length === 5 && parts[2] === 'travelers' && parts[4] === 'passport' && request.method === 'POST') {
      const auth=await requireIumrahBookingAccount(request,env,bookingID); if(!auth.ok)return auth.response;
      return uploadTravelerPassport(request,env,bookingID,Number(parts[3]),auth);
    }
    if (parts.length === 3 && parts[2] === 'receipt' && request.method === 'POST') {
      const auth=await requireIumrahBookingAccount(request,env,bookingID); if(!auth.ok)return auth.response;
      return uploadPaymentReceipt(request,env,bookingID,auth);
    }
    if (parts.length === 4 && parts[2] === 'media' && request.method === 'GET') {
      const auth=await requireIumrahBookingAccount(request,env,bookingID); if(!auth.ok)return auth.response;
      return serveClientPrivateMedia(env,bookingID,parts[3]);
    }
    return methodNotAllowed();
  }

  if (parts[0] === 'bookings') {
    const bookingID=cleanText(parts[1],180); if(!bookingID)return json({ok:false,error:'INVALID_BOOKING_ID'},400);
    if(parts.length===2&&request.method==='DELETE'){const auth=await requireClientBooking(request,env,bookingID,{syncTrip:false});if(!auth.ok)return auth.response;return deleteClientBooking(request,env,bookingID,auth);} return methodNotAllowed();
  }
  if(parts[0]==='push'&&parts.length===2&&parts[1]==='devices'&&request.method==='POST')return registerClientPushDevice(request,env);
  if(parts[0]==='notifications')return handleClientSystemNotifications(request,env,parts.slice(1));
  if(parts[0]!=='chats')return json({ok:false,error:'NOT_FOUND'},404);
  const bookingID=cleanText(parts[1],180); if(!bookingID)return json({ok:false,error:'INVALID_BOOKING_ID'},400);
  const auth=await requireClientBooking(request,env,bookingID,{syncTrip:false}); if(!auth.ok)return auth.response;
  if(parts.length===3&&parts[2]==='messages'){if(request.method==='GET')return chatMessages(env,bookingID,false);if(request.method==='POST')return sendClientChatMessage(request,env,bookingID,auth.user);}
  if(parts.length===3&&parts[2]==='attachments'&&request.method==='POST')return sendChatAttachment(request,env,bookingID,auth.user,false);
  if(parts.length===3&&parts[2]==='read'&&request.method==='POST')return markClientChatRead(env,bookingID);
  if(parts.length===4&&parts[2]==='media'&&request.method==='GET')return serveChatAttachment(env,bookingID,parts[3]);
  return methodNotAllowed();
}

async function registerClientPushDevice(request,env){
 const payload=await request.json().catch(()=>null);const bookingID=cleanText(payload?.bookingID||payload?.bookingId,180);const token=cleanText(payload?.deviceToken,256)?.toLowerCase();if(!bookingID)return json({ok:false,error:'BOOKING_ID_REQUIRED'},400);if(!token||!/^[0-9a-f]{32,256}$/.test(token))return json({ok:false,error:'INVALID_DEVICE_TOKEN'},400);
 const auth=await requireClientBooking(request,env,bookingID,{syncTrip:false});if(!auth.ok)return auth.response;const environment=payload?.environment==='development'?'development':'production';const appBundleID=cleanText(payload?.appBundleID||payload?.appBundleId,220)||'com.iumrah.beta';if(appBundleID!=='com.iumrah.beta')return json({ok:false,error:'INVALID_APP_BUNDLE_ID'},400);const locale=cleanText(payload?.locale,32)||'ru';const now=new Date().toISOString();
 await env.HOTELS_DB.prepare(`INSERT INTO client_push_subscriptions(device_token,booking_id,environment,app_bundle_id,locale,enabled,created_at,updated_at,last_error) VALUES(?,?,?,?,?,1,?,?,NULL) ON CONFLICT(device_token,booking_id) DO UPDATE SET environment=excluded.environment,app_bundle_id=excluded.app_bundle_id,locale=excluded.locale,enabled=1,updated_at=excluded.updated_at,last_error=NULL`).bind(token,bookingID,environment,appBundleID,locale,now,now).run();return json({ok:true,ready:apnsConfigured(env),bookingID});
}


const CLIENT_NOTIFICATION_SCOPES = new Set(['all','authenticated','guest','has_trip']);
const CLIENT_NOTIFICATION_DESTINATIONS = new Set(['home','hotels','bookings','care','account','booking']);

function validClientInstallation(value) {
  return typeof value === 'string' && /^[A-Za-z0-9._:-]{16,128}$/.test(value);
}

async function optionalIumrahAccount(request, env) {
  const header = String(request.headers.get('authorization') || '');
  if (!header.toLowerCase().startsWith('bearer ')) return { ok: true, authenticated: false, pilgrim: null };
  const auth = await requireIumrahAccount(request, env);
  if (!auth.ok) return { ok: false, response: auth.response };
  return { ok: true, authenticated: true, pilgrim: auth.pilgrim };
}

function clientNotificationTargetSQL(scope, alias = 'd') {
  if (scope === 'authenticated') return `${alias}.is_authenticated=1`;
  if (scope === 'guest') return `${alias}.is_authenticated=0`;
  if (scope === 'has_trip') return `${alias}.has_trip=1`;
  return '1=1';
}

function mapClientSystemNotification(row) {
  return {
    id: row.id,
    title: row.title,
    body: row.body,
    targetScope: row.target_scope,
    destination: row.destination,
    destinationBookingID: row.destination_booking_id || null,
    createdBy: row.created_by || '',
    status: row.status,
    matchedDevices: Number(row.matched_devices || 0),
    pushSentCount: Number(row.push_sent_count || 0),
    pushFailedCount: Number(row.push_failed_count || 0),
    createdAt: row.created_at,
    sentAt: row.sent_at || null,
    expiresAt: row.expires_at,
    isRead: Number(row.is_read || 0) === 1
  };
}

async function registerClientNotificationDevice(request, env) {
  const payload = await request.json().catch(() => null);
  const installationID = cleanText(payload?.installationID || payload?.installationId, 128);
  if (!validClientInstallation(installationID)) return json({ ok: false, error: 'INVALID_INSTALLATION_ID' }, 400);

  let deviceToken = cleanText(payload?.deviceToken, 256)?.toLowerCase() || null;
  if (deviceToken && !/^[0-9a-f]{32,256}$/.test(deviceToken)) return json({ ok: false, error: 'INVALID_DEVICE_TOKEN' }, 400);
  const environment = payload?.environment === 'development' ? 'development' : 'production';
  const appBundleID = cleanText(payload?.appBundleID || payload?.appBundleId, 220) || 'com.iumrah.beta';
  if (appBundleID !== 'com.iumrah.beta') return json({ ok: false, error: 'INVALID_APP_BUNDLE_ID' }, 400);
  const locale = cleanText(payload?.locale, 32) || 'ru';
  const hasTrip = payload?.hasTrip === true ? 1 : 0;
  const account = await optionalIumrahAccount(request, env);
  if (!account.ok) return account.response;
  const pilgrimID = account.authenticated ? Number(account.pilgrim?.id || account.pilgrim?.pilgrim_id || 0) || null : null;
  const authenticated = account.authenticated ? 1 : 0;
  const now = new Date().toISOString();

  if (deviceToken) {
    await env.HOTELS_DB.prepare(`
      DELETE FROM client_notification_devices
      WHERE device_token=? AND installation_id<>?
    `).bind(deviceToken, installationID).run().catch(() => {});
  }

  await env.HOTELS_DB.prepare(`
    INSERT INTO client_notification_devices(
      installation_id,device_token,environment,app_bundle_id,locale,pilgrim_id,is_authenticated,has_trip,enabled,created_at,updated_at,last_seen_at,last_error
    ) VALUES(?,?,?,?,?,?,?,?,1,?,?,?,NULL)
    ON CONFLICT(installation_id) DO UPDATE SET
      device_token=COALESCE(excluded.device_token,client_notification_devices.device_token),
      environment=excluded.environment,
      app_bundle_id=excluded.app_bundle_id,
      locale=excluded.locale,
      pilgrim_id=excluded.pilgrim_id,
      is_authenticated=excluded.is_authenticated,
      has_trip=excluded.has_trip,
      enabled=CASE WHEN excluded.device_token IS NOT NULL THEN 1 ELSE client_notification_devices.enabled END,
      updated_at=excluded.updated_at,
      last_seen_at=excluded.last_seen_at,
      last_error=NULL
  `).bind(
    installationID, deviceToken, environment, appBundleID, locale, pilgrimID, authenticated, hasTrip,
    now, now, now
  ).run();

  return json({ ok: true, ready: apnsConfigured(env), installationID, authenticated: !!authenticated, hasTrip: !!hasTrip });
}

async function clientSystemNotificationFeed(request, env) {
  const url = new URL(request.url);
  const installationID = cleanText(url.searchParams.get('installationID') || url.searchParams.get('installationId'), 128);
  if (!validClientInstallation(installationID)) return json({ ok: false, error: 'INVALID_INSTALLATION_ID' }, 400);
  const account = await optionalIumrahAccount(request, env);
  if (!account.ok) return account.response;

  const device = await env.HOTELS_DB.prepare(`
    SELECT installation_id,is_authenticated,has_trip FROM client_notification_devices WHERE installation_id=? LIMIT 1
  `).bind(installationID).first();
  if (!device) return json({ ok: true, notifications: [] });

  const now = new Date().toISOString();
  const rows = await env.HOTELS_DB.prepare(`
    SELECT n.*, CASE WHEN r.notification_id IS NULL THEN 0 ELSE 1 END AS is_read
    FROM client_system_notifications n
    LEFT JOIN client_system_notification_reads r
      ON r.notification_id=n.id AND r.installation_id=?
    WHERE n.status='published' AND n.sent_at IS NOT NULL AND n.expires_at>?
      AND (
        n.target_scope='all'
        OR (n.target_scope='authenticated' AND ?=1)
        OR (n.target_scope='guest' AND ?=0)
        OR (n.target_scope='has_trip' AND ?=1)
      )
    ORDER BY n.sent_at DESC
    LIMIT 12
  `).bind(
    installationID,
    now,
    Number(device.is_authenticated || 0),
    Number(device.is_authenticated || 0),
    Number(device.has_trip || 0)
  ).all();

  return json({ ok: true, notifications: (rows.results || []).map(mapClientSystemNotification) });
}

async function markClientSystemNotificationRead(request, env, notificationID) {
  const payload = await request.json().catch(() => null);
  const installationID = cleanText(payload?.installationID || payload?.installationId, 128);
  if (!validClientInstallation(installationID)) return json({ ok: false, error: 'INVALID_INSTALLATION_ID' }, 400);
  const exists = await env.HOTELS_DB.prepare('SELECT id FROM client_system_notifications WHERE id=? LIMIT 1').bind(notificationID).first();
  if (!exists) return json({ ok: false, error: 'NOTIFICATION_NOT_FOUND' }, 404);
  const device = await env.HOTELS_DB.prepare('SELECT installation_id FROM client_notification_devices WHERE installation_id=? LIMIT 1').bind(installationID).first();
  if (!device) return json({ ok: false, error: 'INSTALLATION_NOT_REGISTERED' }, 404);
  const now = new Date().toISOString();
  await env.HOTELS_DB.prepare(`
    INSERT INTO client_system_notification_reads(notification_id,installation_id,opened_at)
    VALUES(?,?,?)
    ON CONFLICT(notification_id,installation_id) DO UPDATE SET opened_at=excluded.opened_at
  `).bind(notificationID, installationID, now).run();
  return json({ ok: true });
}

async function handleClientSystemNotifications(request, env, parts) {
  if (parts.length === 1 && parts[0] === 'devices' && request.method === 'POST') {
    return registerClientNotificationDevice(request, env);
  }
  if (parts.length === 1 && parts[0] === 'feed' && request.method === 'GET') {
    return clientSystemNotificationFeed(request, env);
  }
  if (parts.length === 3 && parts[0] === 'feed' && parts[2] === 'read' && request.method === 'POST') {
    const notificationID = safeID(parts[1]);
    if (!notificationID) return json({ ok: false, error: 'INVALID_NOTIFICATION_ID' }, 400);
    return markClientSystemNotificationRead(request, env, notificationID);
  }
  return methodNotAllowed();
}

async function clientNotificationAudience(env) {
  const row = await env.HOTELS_DB.prepare(`
    SELECT
      COUNT(*) AS all_count,
      SUM(CASE WHEN is_authenticated=1 THEN 1 ELSE 0 END) AS authenticated_count,
      SUM(CASE WHEN is_authenticated=0 THEN 1 ELSE 0 END) AS guest_count,
      SUM(CASE WHEN has_trip=1 THEN 1 ELSE 0 END) AS has_trip_count,
      SUM(CASE WHEN enabled=1 AND device_token IS NOT NULL AND device_token<>'' THEN 1 ELSE 0 END) AS push_capable_count
    FROM client_notification_devices
  `).first();
  return json({
    ok: true,
    audience: {
      all: Number(row?.all_count || 0),
      authenticated: Number(row?.authenticated_count || 0),
      guest: Number(row?.guest_count || 0),
      hasTrip: Number(row?.has_trip_count || 0),
      pushCapable: Number(row?.push_capable_count || 0)
    }
  });
}

async function listClientSystemNotifications(env) {
  const rows = await env.HOTELS_DB.prepare(`
    SELECT * FROM client_system_notifications ORDER BY created_at DESC LIMIT 50
  `).all();
  return json({ ok: true, notifications: (rows.results || []).map(mapClientSystemNotification) });
}

async function sendClientSystemNotificationPush(env, scope, notification) {
  if (!apnsConfigured(env)) return { ok: false, skipped: 'APNS_NOT_CONFIGURED', sent: 0, total: 0 };
  let lastInstallationID = '';
  let sent = 0;
  let total = 0;
  const where = clientNotificationTargetSQL(scope, 'd');

  for (let page = 0; page < 100; page += 1) {
    const rows = await env.HOTELS_DB.prepare(`
      SELECT installation_id,device_token,environment,app_bundle_id,locale
      FROM client_notification_devices d
      WHERE d.enabled=1 AND d.device_token IS NOT NULL AND d.device_token<>''
        AND d.installation_id>? AND ${where}
      ORDER BY d.installation_id ASC
      LIMIT 200
    `).bind(lastInstallationID).all();
    const devices = rows.results || [];
    if (!devices.length) break;
    lastInstallationID = devices[devices.length - 1].installation_id;

    const data = {
      type: 'system_notification',
      notificationID: notification.id,
      destination: notification.destination,
      ...(notification.destinationBookingID ? { destinationBookingID: notification.destinationBookingID } : {})
    };
    const result = await sendAPNsToRows(env, devices, notification.title, notification.body, data, async (device, delivery) => {
      const now = new Date().toISOString();
      if (delivery.ok) {
        await env.HOTELS_DB.prepare(`
          UPDATE client_notification_devices SET last_success_at=?,last_error=NULL,updated_at=? WHERE installation_id=?
        `).bind(now, now, device.installation_id).run().catch(() => {});
      } else if (delivery.response) {
        await env.HOTELS_DB.prepare(`
          UPDATE client_notification_devices SET enabled=?,last_error=?,updated_at=? WHERE installation_id=?
        `).bind(delivery.disable ? 0 : 1, delivery.error.slice(0, 900), now, device.installation_id).run().catch(() => {});
      }
    });
    sent += Number(result.sent || 0);
    total += Number(result.total || 0);
    if (devices.length < 200) break;
  }
  return { ok: sent > 0, sent, total };
}

async function createClientSystemNotification(request, env, user) {
  const payload = await request.json().catch(() => null);
  const title = safeHumanText(payload?.title || '', 120) || '';
  const body = safeHumanText(payload?.body || '', 600) || '';
  const targetScope = cleanText(payload?.targetScope, 32)?.toLowerCase() || 'all';
  const destination = cleanText(payload?.destination, 32)?.toLowerCase() || 'home';
  const destinationBookingID = cleanText(payload?.destinationBookingID || payload?.destinationBookingId, 180) || null;
  if (!title || !body) return json({ ok: false, error: 'NOTIFICATION_COPY_REQUIRED' }, 400);
  if (!CLIENT_NOTIFICATION_SCOPES.has(targetScope)) return json({ ok: false, error: 'INVALID_NOTIFICATION_SCOPE' }, 400);
  if (!CLIENT_NOTIFICATION_DESTINATIONS.has(destination)) return json({ ok: false, error: 'INVALID_NOTIFICATION_DESTINATION' }, 400);
  if (destination === 'booking' && !destinationBookingID) return json({ ok: false, error: 'DESTINATION_BOOKING_ID_REQUIRED' }, 400);

  const id = `signal-${crypto.randomUUID()}`;
  const now = new Date();
  const createdAt = now.toISOString();
  const expiresAt = new Date(now.getTime() + 14 * 86400_000).toISOString();
  const createdBy = businessStaffLogin(user) || safeHumanText(user?.displayName || '', 180) || 'iumrah-business';
  const countRow = await env.HOTELS_DB.prepare(`
    SELECT COUNT(*) AS count FROM client_notification_devices d WHERE ${clientNotificationTargetSQL(targetScope, 'd')}
  `).first();
  const matchedDevices = Number(countRow?.count || 0);

  await env.HOTELS_DB.prepare(`
    INSERT INTO client_system_notifications(
      id,title,body,target_scope,destination,destination_booking_id,created_by,status,matched_devices,push_sent_count,push_failed_count,created_at,sent_at,expires_at
    ) VALUES(?,?,?,?,?,?,?,'sending',?,0,0,?,NULL,?)
  `).bind(
    id,title,body,targetScope,destination,destinationBookingID,createdBy,matchedDevices,createdAt,expiresAt
  ).run();

  let delivery;
  try {
    delivery = await sendClientSystemNotificationPush(env, targetScope, {
      id, title, body, destination, destinationBookingID
    });
  } catch (error) {
    console.error('CLIENT_SYSTEM_NOTIFICATION_PUSH_FAILED', id, error);
    delivery = { ok: false, sent: 0, total: 0, error: String(error?.message || error) };
  }

  const sentAt = new Date().toISOString();
  const sentCount = Number(delivery?.sent || 0);
  const attempted = Number(delivery?.total || 0);
  const failedCount = Math.max(0, attempted - sentCount);
  await env.HOTELS_DB.prepare(`
    UPDATE client_system_notifications
    SET status='published',sent_at=?,push_sent_count=?,push_failed_count=?
    WHERE id=?
  `).bind(sentAt, sentCount, failedCount, id).run();

  const row = await env.HOTELS_DB.prepare('SELECT * FROM client_system_notifications WHERE id=?').bind(id).first();
  return json({ ok: true, notification: mapClientSystemNotification(row), delivery: { sent: sentCount, attempted, pushReady: apnsConfigured(env) } }, 201);
}

async function requireBookingToken(request,env,bookingID,options={}){
 const bookingToken=cleanText(request.headers.get('x-booking-token'),1024);if(!bookingToken)return {ok:false,response:json({ok:false,error:'UNAUTHORIZED'},401)};const base=String(env.BOOKINGS_PUBLIC_URL||'https://iumrah.app/api/bookings').replace(/\/$/,'');let response;try{response=await fetch(`${base}/${encodeURIComponent(bookingID)}`,{method:'GET',headers:{'x-booking-token':bookingToken,'accept':'application/json','user-agent':request.headers.get('user-agent')||'iumrah-client'},redirect:'manual'});}catch{return {ok:false,response:json({ok:false,error:'BOOKING_AUTH_UNAVAILABLE'},503)}}if(response.status===404)return {ok:false,response:json({ok:false,error:'BOOKING_NOT_FOUND'},404)};if(!response.ok)return {ok:false,response:json({ok:false,error:'BOOKING_ACCESS_DENIED'},403)};const payload=await response.json().catch(()=>null);const booking=payload?.booking||payload;if(!booking||cleanText(booking?.id,180)!==bookingID)return {ok:false,response:json({ok:false,error:'BOOKING_ACCESS_DENIED'},403)};
 let linked=null;if(options.syncTrip!==false){try{linked=await syncBookingTrip(env,booking);}catch(error){console.error('CLIENT_BOOKING_SYNC_FAILED',bookingID,error);return {ok:false,response:json({ok:false,error:'BOOKING_SYNC_FAILED'},503)}}}if(linked?.deleted)return {ok:false,response:json({ok:false,error:'BOOKING_DELETED'},410)};let trip=linked?.trip||await env.HOTELS_DB.prepare('SELECT * FROM pilgrim_trips WHERE booking_id=?').bind(bookingID).first().catch(()=>null);return {ok:true,booking,trip,user:{displayName:linked?.pilgrim?canonicalPilgrimName(linked.pilgrim):'Паломник'},bootstrap:true};
}

async function requireIumrahAccount(request,env){
 const header=String(request.headers.get('authorization')||'');
 const token=header.toLowerCase().startsWith('bearer ')?header.slice(7).trim():'';
 if(!token)return {ok:false,response:json({ok:false,error:'ACCOUNT_AUTH_REQUIRED'},401)};
 const hash=await sha256Hex(token),now=new Date().toISOString();
 const row=await env.HOTELS_DB.prepare(`SELECT s.pilgrim_id,s.expires_at,p.id,p.first_name,p.last_name,p.display_name,p.phone,p.email,p.telegram,p.whatsapp,p.created_at,p.updated_at,p.last_trip_at,p.total_trips FROM iumrah_account_sessions s JOIN pilgrims p ON p.id=s.pilgrim_id WHERE s.token_hash=? AND s.revoked_at IS NULL AND s.expires_at>? LIMIT 1`).bind(hash,now).first();
 if(!row)return {ok:false,response:json({ok:false,error:'ACCOUNT_SESSION_EXPIRED'},401)};
 await env.HOTELS_DB.prepare('UPDATE iumrah_account_sessions SET last_used_at=? WHERE token_hash=?').bind(now,hash).run().catch(()=>{});
 return {ok:true,pilgrim:row,tokenHash:hash,user:{id:pilgrimPublicID(row.id),displayName:canonicalPilgrimName(row)}};
}
async function requireIumrahBookingAccount(request,env,bookingID){const auth=await requireIumrahAccount(request,env);if(!auth.ok)return auth;const trip=await env.HOTELS_DB.prepare('SELECT * FROM pilgrim_trips WHERE booking_id=? AND pilgrim_id=? LIMIT 1').bind(bookingID,auth.pilgrim.pilgrim_id||auth.pilgrim.id).first();if(!trip)return {ok:false,response:json({ok:false,error:'BOOKING_ACCESS_DENIED'},403)};return {...auth,trip};}
async function requireClientBooking(request,env,bookingID,options={}){const account=await requireIumrahAccount(request,env);if(account.ok){const access=await requireIumrahBookingAccount(request,env,bookingID);if(access.ok)return access;}return requireBookingToken(request,env,bookingID,options);}

const IUMRAH_PASSWORD_ITERATIONS = 100000;

function decodePilgrimID(value){const text=String(value||'').trim();if(!/^\d{6}$/.test(text))return 0;return Number(text);}
function validPassword(value){return typeof value==='string'&&value.length>=8&&value.length<=128;}
function passwordHashSupported(iterations){const value=Number(iterations||0);return Number.isFinite(value)&&value>0&&value<=IUMRAH_PASSWORD_ITERATIONS;}
function randomToken(bytes=32){const data=new Uint8Array(bytes);crypto.getRandomValues(data);return base64urlBytes(data);}
async function passwordDigest(password,salt,iterations=IUMRAH_PASSWORD_ITERATIONS){
 const safeIterations=Number(iterations||IUMRAH_PASSWORD_ITERATIONS);
 if(!passwordHashSupported(safeIterations))throw new Error('UNSUPPORTED_PASSWORD_ITERATIONS');
 const key=await crypto.subtle.importKey('raw',new TextEncoder().encode(password),'PBKDF2',false,['deriveBits']);
 const bits=await crypto.subtle.deriveBits({name:'PBKDF2',hash:'SHA-256',salt:new TextEncoder().encode(salt),iterations:safeIterations},key,256);
 return base64urlBytes(new Uint8Array(bits));
}
function constantTimeEqual(a,b){const x=new TextEncoder().encode(String(a||'')),y=new TextEncoder().encode(String(b||''));if(x.length===0||y.length===0||x.length!==y.length)return false;let diff=0;for(let i=0;i<x.length;i++)diff|=x[i]^y[i];return diff===0;}
async function createAccountSession(env,pilgrimID){const token=randomToken(32),hash=await sha256Hex(token),now=new Date(),expires=new Date(now.getTime()+90*86400_000);await env.HOTELS_DB.prepare('INSERT INTO iumrah_account_sessions(token_hash,pilgrim_id,created_at,expires_at,last_used_at) VALUES(?,?,?,?,?)').bind(hash,pilgrimID,now.toISOString(),expires.toISOString(),now.toISOString()).run();return {token,expiresAt:expires.toISOString()};}
function accountProfile(p){return {iumrahID:pilgrimPublicID(p.id||p.pilgrim_id),displayName:canonicalPilgrimName(p),firstName:p.first_name||'',lastName:p.last_name||'',phone:p.phone||'',email:p.email||'',telegram:p.telegram||'',whatsapp:p.whatsapp||''};}
async function handleClientAccount(request,env,parts){
 if(parts.length===1&&parts[0]==='activate'&&request.method==='POST'){
  const payload=await request.json().catch(()=>null),bookingID=cleanText(payload?.bookingID,180),password=String(payload?.password||'');
  if(!bookingID||!validPassword(password))return json({ok:false,error:'INVALID_ACCOUNT_DATA'},400);
  const boot=await requireBookingToken(request,env,bookingID,{syncTrip:true});if(!boot.ok)return boot.response;
  const trip=boot.trip;if(!trip||normalizedTripStatus(trip.status)!=='payment_pending')return json({ok:false,error:'ACCOUNT_ACTIVATION_NOT_AVAILABLE'},409);
  const existing=await env.HOTELS_DB.prepare('SELECT pilgrim_id,password_iterations FROM iumrah_accounts WHERE pilgrim_id=?').bind(trip.pilgrim_id).first();
  if(existing&&passwordHashSupported(existing.password_iterations))return json({ok:false,error:'ACCOUNT_ALREADY_ACTIVE'},409);
  const salt=randomToken(18),iterations=IUMRAH_PASSWORD_ITERATIONS,now=new Date().toISOString();
  let hash;try{hash=await passwordDigest(password,salt,iterations);}catch(error){console.error('IUMRAH_PASSWORD_HASH_FAILED',error);return json({ok:false,error:'PASSWORD_SETUP_UNAVAILABLE'},503);}
  if(existing){
   await env.HOTELS_DB.prepare(`UPDATE iumrah_accounts SET password_salt=?,password_hash=?,password_iterations=?,password_updated_at=?,failed_attempts=0,locked_until=NULL,last_login_at=NULL WHERE pilgrim_id=?`).bind(salt,hash,iterations,now,trip.pilgrim_id).run();
  }else{
   await env.HOTELS_DB.prepare('INSERT INTO iumrah_accounts(pilgrim_id,password_salt,password_hash,password_iterations,activated_at,password_updated_at) VALUES(?,?,?,?,?,?)').bind(trip.pilgrim_id,salt,hash,iterations,now,now).run();
  }
  const pilgrim=await env.HOTELS_DB.prepare('SELECT * FROM pilgrims WHERE id=?').bind(trip.pilgrim_id).first();
  const session=await createAccountSession(env,trip.pilgrim_id);
  return json({ok:true,account:accountProfile(pilgrim),session});
 }
 if(parts.length===1&&parts[0]==='login'&&request.method==='POST'){
  const payload=await request.json().catch(()=>null),id=decodePilgrimID(payload?.iumrahID||payload?.id),password=String(payload?.password||'');
  if(!id||!validPassword(password))return json({ok:false,error:'INVALID_CREDENTIALS'},401);
  const row=await env.HOTELS_DB.prepare('SELECT a.*,p.* FROM iumrah_accounts a JOIN pilgrims p ON p.id=a.pilgrim_id WHERE a.pilgrim_id=? LIMIT 1').bind(id).first();
  if(!row)return json({ok:false,error:'INVALID_CREDENTIALS'},401);
  if(!passwordHashSupported(row.password_iterations))return json({ok:false,error:'ACCOUNT_PASSWORD_RESET_REQUIRED'},409);
  if(row.locked_until&&Date.parse(row.locked_until)>Date.now())return json({ok:false,error:'ACCOUNT_TEMPORARILY_LOCKED'},423);
  let expected;try{expected=await passwordDigest(password,row.password_salt,Number(row.password_iterations));}catch(error){console.error('IUMRAH_PASSWORD_VERIFY_FAILED',error);return json({ok:false,error:'PASSWORD_LOGIN_UNAVAILABLE'},503);}
  if(!constantTimeEqual(expected,row.password_hash)){const attempts=Number(row.failed_attempts||0)+1;const locked=attempts>=6?new Date(Date.now()+15*60_000).toISOString():null;await env.HOTELS_DB.prepare('UPDATE iumrah_accounts SET failed_attempts=?,locked_until=? WHERE pilgrim_id=?').bind(locked?0:attempts,locked,id).run();return json({ok:false,error:locked?'ACCOUNT_TEMPORARILY_LOCKED':'INVALID_CREDENTIALS'},locked?423:401);}
  const now=new Date().toISOString();await env.HOTELS_DB.prepare('UPDATE iumrah_accounts SET failed_attempts=0,locked_until=NULL,last_login_at=? WHERE pilgrim_id=?').bind(now,id).run();
  const session=await createAccountSession(env,id);return json({ok:true,account:accountProfile(row),session});
 }
 if(parts.length===1&&parts[0]==='session'&&request.method==='GET'){const auth=await requireIumrahAccount(request,env);if(!auth.ok)return auth.response;return json({ok:true,account:accountProfile(auth.pilgrim)});}
 if(parts.length===1&&parts[0]==='profile'&&request.method==='PUT'){const auth=await requireIumrahAccount(request,env);if(!auth.ok)return auth.response;const payload=await request.json().catch(()=>null);if(!payload)return json({ok:false,error:'INVALID_JSON'},400);const firstName=safeHumanText(payload.firstName,120)||'',lastName=safeHumanText(payload.lastName,120)||'',phone=cleanText(payload.phone,100)||'',email=cleanText(payload.email,220)||'',telegram=cleanText(payload.telegram,120)||'',whatsapp=cleanText(payload.whatsapp,120)||'';if(!firstName||!lastName)return json({ok:false,error:'PROFILE_NAME_REQUIRED'},400);const displayName=[firstName,lastName].filter(Boolean).join(' ').trim();await env.HOTELS_DB.prepare('UPDATE pilgrims SET first_name=?,last_name=?,display_name=?,phone=?,email=?,telegram=?,whatsapp=?,updated_at=? WHERE id=?').bind(firstName,lastName,displayName,phone,email,telegram,whatsapp,new Date().toISOString(),auth.pilgrim.id).run();const pilgrim=await env.HOTELS_DB.prepare('SELECT * FROM pilgrims WHERE id=?').bind(auth.pilgrim.id).first();return json({ok:true,account:accountProfile(pilgrim)});}
 if(parts.length===1&&parts[0]==='logout'&&request.method==='POST'){const auth=await requireIumrahAccount(request,env);if(!auth.ok)return auth.response;await env.HOTELS_DB.prepare('UPDATE iumrah_account_sessions SET revoked_at=? WHERE token_hash=?').bind(new Date().toISOString(),auth.tokenHash).run();return json({ok:true});}
 if(parts.length===1&&parts[0]==='link-booking'&&request.method==='POST'){
  const auth=await requireIumrahAccount(request,env);if(!auth.ok)return auth.response;
  const payload=await request.json().catch(()=>null);const bookingID=cleanText(payload?.bookingID,180);if(!bookingID)return json({ok:false,error:'BOOKING_ID_REQUIRED'},400);
  // Validate the one-time booking token without creating a temporary pilgrim. The
  // canonical Iumrah account owns the trip from its first operational row.
  const boot=await requireBookingToken(request,env,bookingID,{syncTrip:false});if(!boot.ok)return boot.response;
  const canonicalID=Number(auth.pilgrim.id);const now=new Date().toISOString();
  let trip=await env.HOTELS_DB.prepare('SELECT * FROM pilgrim_trips WHERE booking_id=? LIMIT 1').bind(bookingID).first();
  if(!trip){
    const sourcePayload=await sourceBookingPayload(env,bookingID);const effectiveRaw=mergeSourceBooking(boot.booking,sourcePayload);const pricing=extractPricingSnapshot(effectiveRaw);const bookingNumber=await allocateBookingNumber(env);
    await env.HOTELS_DB.prepare(`INSERT INTO pilgrim_trips (id,booking_id,booking_number,pilgrim_id,status,start_date,end_date,booking_snapshot_json,pricing_snapshot_json,created_at,updated_at) VALUES (?,?,?,?,?,?,?,?,?,?,?)`)
      .bind(`trip-${crypto.randomUUID()}`,bookingID,bookingNumber,canonicalID,tripStatusFromBooking(effectiveRaw),cleanText(effectiveRaw?.startDate,64),cleanText(effectiveRaw?.endDate,64),JSON.stringify(effectiveRaw),JSON.stringify(pricing),now,now).run();
  }else if(Number(trip.pilgrim_id)!==canonicalID){
    const oldID=Number(trip.pilgrim_id||0);
    await env.HOTELS_DB.prepare('UPDATE pilgrim_trips SET pilgrim_id=?,updated_at=? WHERE booking_id=?').bind(canonicalID,now,bookingID).run();
    await recalcPilgrimStats(env,oldID);const orphan=await env.HOTELS_DB.prepare('SELECT COUNT(*) AS count FROM pilgrim_trips WHERE pilgrim_id=?').bind(oldID).first();const oldAccount=await env.HOTELS_DB.prepare('SELECT pilgrim_id FROM iumrah_accounts WHERE pilgrim_id=?').bind(oldID).first();if(oldID&&Number(orphan?.count||0)===0&&!oldAccount)await env.HOTELS_DB.prepare('DELETE FROM pilgrims WHERE id=?').bind(oldID).run().catch(()=>{});
  }
  const identity=bookingIdentity(boot.booking);await updatePilgrimIdentityFields(env,auth.pilgrim,identity);await recalcPilgrimStats(env,canonicalID);
  trip=await env.HOTELS_DB.prepare('SELECT * FROM pilgrim_trips WHERE booking_id=?').bind(bookingID).first();
  return json({ok:true,pilgrimID:pilgrimPublicID(canonicalID),bookingNumber:Number(trip?.booking_number||0)||null,bookingDisplayNumber:bookingPublicNumber(trip?.booking_number)});
 }
 return methodNotAllowed();
}
async function recalcPilgrimStats(env,id){if(!id)return;const r=await env.HOTELS_DB.prepare('SELECT COUNT(*) count,MAX(COALESCE(end_date,created_at)) last_trip FROM pilgrim_trips WHERE pilgrim_id=?').bind(id).first();await env.HOTELS_DB.prepare('UPDATE pilgrims SET total_trips=?,last_trip_at=?,updated_at=? WHERE id=?').bind(Number(r?.count||0),r?.last_trip||null,new Date().toISOString(),id).run();}
async function listAccountTrips(env,pilgrimID){const rows=await env.HOTELS_DB.prepare('SELECT * FROM pilgrim_trips WHERE pilgrim_id=? ORDER BY created_at DESC').bind(pilgrimID).all();return json({ok:true,trips:(rows.results||[]).map(tripMap)});}
async function clientTripDetail(env,bookingID,trip){const raw=parseJSONObject(trip?.booking_snapshot_json);return json({ok:true,trip:tripMap(trip),booking:raw,assignment:await clientBookingAssignmentDetail(env,bookingID),esims:await clientBookingEsimRows(env,bookingID,{syncIfStale:true})});}
async function syncBookingProfileByToken(request, env, bookingID, auth) {
  const payload = await request.json().catch(() => ({}));
  let trip = auth.trip;
  let pilgrim = trip ? await env.HOTELS_DB.prepare('SELECT * FROM pilgrims WHERE id=?').bind(trip.pilgrim_id).first() : null;

  const hasIdentityPayload = ['firstName','lastName','whatsapp','phone','email'].some(key => cleanText(payload?.[key], 220));
  if (pilgrim && hasIdentityPayload) {
    const identity = {
      firstName: safeHumanText(payload?.firstName || '', 120) || '',
      lastName: safeHumanText(payload?.lastName || '', 120) || '',
      displayName: [payload?.firstName, payload?.lastName].filter(Boolean).join(' ').trim(),
      phone: cleanText(payload?.whatsapp || payload?.phone, 100) || '',
      email: cleanText(payload?.email, 220) || ''
    };
    pilgrim = await updatePilgrimIdentityFields(env, pilgrim, identity);
  }

  if (trip) {
    const bookingSnapshot = parseJSONObject(trip.booking_snapshot_json);
    let bookingSnapshotChanged = false;
    if (payload?.generatorTrace && typeof payload.generatorTrace === 'object') {
      bookingSnapshot.generatorTrace = payload.generatorTrace;
      bookingSnapshotChanged = true;
    }

    let pricingJSON = trip.pricing_snapshot_json || '{}';
    if (payload?.pricingSnapshot && typeof payload.pricingSnapshot === 'object') {
      if (!validGeneratorPricingReport(payload.pricingSnapshot)) {
        return json({ ok: false, error: 'INVALID_GENERATOR_PRICING_REPORT' }, 422);
      }
      // Store the immutable generator report both in its dedicated column and in the
      // booking snapshot. The dedicated column powers "Цена под капотом"; embedding
      // it also protects the report across future source-booking re-syncs.
      pricingJSON = JSON.stringify(payload.pricingSnapshot);
      bookingSnapshot.pricingSnapshot = payload.pricingSnapshot;
      bookingSnapshotChanged = true;
    }

    if (bookingSnapshotChanged || pricingJSON !== (trip.pricing_snapshot_json || '{}')) {
      await env.HOTELS_DB.prepare('UPDATE pilgrim_trips SET booking_snapshot_json=?,pricing_snapshot_json=?,updated_at=? WHERE id=?')
        .bind(JSON.stringify(bookingSnapshot), pricingJSON, new Date().toISOString(), trip.id).run();
      trip = await env.HOTELS_DB.prepare('SELECT * FROM pilgrim_trips WHERE id=?').bind(trip.id).first();
    }
  }

  return json({
    ok: true,
    pilgrimID: pilgrim ? pilgrimPublicID(pilgrim.id) : null,
    trip: tripMap(trip),
    assignment: await clientBookingAssignmentDetail(env, bookingID),
    esims: await clientBookingEsimRows(env, bookingID, { syncIfStale: true })
  });
}

function travelerCountsFromSnapshot(raw){const t=raw?.input?.travelers||raw?.travelers||{};return {adults:Math.max(1,Number(t.adults||1)),children:Math.max(0,Number(t.children||0)),infants:Math.max(0,Number(t.infants||0))};}
async function ensureTravelerRows(env,bookingID,trip){const existing=await env.HOTELS_DB.prepare('SELECT COUNT(*) count FROM booking_travelers WHERE booking_id=?').bind(bookingID).first();if(Number(existing?.count||0)>0)return;const c=travelerCountsFromSnapshot(parseJSONObject(trip.booking_snapshot_json));let pos=0;const stm=[];for(const [type,count] of [['adult',c.adults],['child',c.children],['infant',c.infants]])for(let i=0;i<count;i++){pos++;stm.push(env.HOTELS_DB.prepare('INSERT OR IGNORE INTO booking_travelers(id,booking_id,position,traveler_type) VALUES(?,?,?,?)').bind(`traveler-${crypto.randomUUID()}`,bookingID,pos,type));}if(stm.length)await env.HOTELS_DB.batch(stm);}
function travelerMap(r){return {position:Number(r.position),travelerType:r.traveler_type,firstName:r.first_name,middleName:r.middle_name,lastName:r.last_name,gender:r.gender,dateOfBirth:r.date_of_birth,placeOfBirth:r.place_of_birth,nationality:r.nationality,residenceCountry:r.residence_country,passportNumber:r.passport_number,passportIssueDate:r.passport_issue_date,passportExpiryDate:r.passport_expiry_date,passportIssuingCountry:r.passport_issuing_country,phone:r.phone,email:r.email,emergencyName:r.emergency_name,emergencyPhone:r.emergency_phone,emergencyRelation:r.emergency_relation,hasPassport:!!r.passport_object_key,completed:Number(r.completed||0)===1};}
async function accountActive(env,pid){const row=await env.HOTELS_DB.prepare('SELECT pilgrim_id,password_iterations FROM iumrah_accounts WHERE pilgrim_id=?').bind(pid).first();return !!row&&passwordHashSupported(row.password_iterations);}
async function clientCheckoutDetail(env,bookingID,trip){
 await ensureTravelerRows(env,bookingID,trip);
 const [trav,pay,receipts,docs,active]=await Promise.all([
  env.HOTELS_DB.prepare('SELECT * FROM booking_travelers WHERE booking_id=? ORDER BY position').bind(bookingID).all(),
  env.HOTELS_DB.prepare('SELECT * FROM booking_payment_instructions WHERE booking_id=?').bind(bookingID).first(),
  env.HOTELS_DB.prepare('SELECT id,payment_method,note,review_status,created_at FROM booking_payment_receipts WHERE booking_id=? ORDER BY created_at DESC').bind(bookingID).all(),
  env.HOTELS_DB.prepare('SELECT id,document_kind,title,content_type,created_at FROM booking_travel_documents WHERE booking_id=? ORDER BY created_at').bind(bookingID).all(),
  accountActive(env,trip.pilgrim_id)
 ]);
 return json({
  ok:true,iumrahID:pilgrimPublicID(trip.pilgrim_id),accountActive:active,status:normalizedTripStatus(trip.status),
  travelers:(trav.results||[]).map(travelerMap),
  payment:{visaCardNumber:pay?.visa_card_number||'',visaHolder:pay?.visa_holder||'',hasPaymeQR:!!pay?.payme_qr_object_key,paymeQRURL:pay?.payme_qr_object_key?`/api/catalog/hotels/client/trips/${encodeURIComponent(bookingID)}/media/payment-qr`:null,humoCardNumber:pay?.humo_card_number||'',humoHolder:pay?.humo_holder||'',instructions:pay?.instructions||''},
  receipts:(receipts.results||[]).map(r=>({id:r.id,paymentMethod:r.payment_method||'other',note:r.note||'',reviewStatus:r.review_status||'submitted',createdAt:r.created_at||''})),
  documents:(docs.results||[]).map(d=>({id:d.id,documentKind:d.document_kind||'other',title:d.title||'Документ поездки',contentType:d.content_type||'application/octet-stream',createdAt:d.created_at||'',url:`/api/catalog/hotels/client/trips/${encodeURIComponent(bookingID)}/media/document-${d.id}`}))
 });
}
function travelerComplete(v,hasPassport){return !!(v.firstName&&v.lastName&&v.gender&&v.dateOfBirth&&v.placeOfBirth&&v.nationality&&v.residenceCountry&&v.passportNumber&&v.passportIssueDate&&v.passportExpiryDate&&v.passportIssuingCountry&&v.phone&&v.emergencyName&&v.emergencyPhone&&v.emergencyRelation&&hasPassport);}
async function saveTravelerForm(request,env,bookingID,position,auth){if(normalizedTripStatus(auth.trip?.status)!=='payment_pending')return json({ok:false,error:'TRAVELER_EDITING_CLOSED'},409);if(!Number.isInteger(position)||position<1)return json({ok:false,error:'INVALID_TRAVELER'},400);const p=await request.json().catch(()=>null);if(!p)return json({ok:false,error:'INVALID_JSON'},400);const row=await env.HOTELS_DB.prepare('SELECT * FROM booking_travelers WHERE booking_id=? AND position=?').bind(bookingID,position).first();if(!row)return json({ok:false,error:'TRAVELER_NOT_FOUND'},404);const val={firstName:safeHumanText(p.firstName,120)||'',middleName:safeHumanText(p.middleName,120)||'',lastName:safeHumanText(p.lastName,120)||'',gender:cleanText(p.gender,20)||'',dateOfBirth:cleanText(p.dateOfBirth,20)||'',placeOfBirth:safeHumanText(p.placeOfBirth,160)||'',nationality:safeHumanText(p.nationality,100)||'',residenceCountry:safeHumanText(p.residenceCountry,100)||'',passportNumber:cleanText(p.passportNumber,80)||'',passportIssueDate:cleanText(p.passportIssueDate,20)||'',passportExpiryDate:cleanText(p.passportExpiryDate,20)||'',passportIssuingCountry:safeHumanText(p.passportIssuingCountry,100)||'',phone:cleanText(p.phone,100)||'',email:cleanText(p.email,220)||'',emergencyName:safeHumanText(p.emergencyName,160)||'',emergencyPhone:cleanText(p.emergencyPhone,100)||'',emergencyRelation:safeHumanText(p.emergencyRelation,80)||''};const complete=travelerComplete(val,!!row.passport_object_key);await env.HOTELS_DB.prepare(`UPDATE booking_travelers SET first_name=?,middle_name=?,last_name=?,gender=?,date_of_birth=?,place_of_birth=?,nationality=?,residence_country=?,passport_number=?,passport_issue_date=?,passport_expiry_date=?,passport_issuing_country=?,phone=?,email=?,emergency_name=?,emergency_phone=?,emergency_relation=?,completed=?,updated_at=? WHERE booking_id=? AND position=?`).bind(val.firstName,val.middleName,val.lastName,val.gender,val.dateOfBirth,val.placeOfBirth,val.nationality,val.residenceCountry,val.passportNumber,val.passportIssueDate,val.passportExpiryDate,val.passportIssuingCountry,val.phone,val.email,val.emergencyName,val.emergencyPhone,val.emergencyRelation,complete?1:0,new Date().toISOString(),bookingID,position).run();return json({ok:true,traveler:travelerMap(await env.HOTELS_DB.prepare('SELECT * FROM booking_travelers WHERE booking_id=? AND position=?').bind(bookingID,position).first())});}
async function privateImageUpload(request,env,keyPrefix){const ct=String(request.headers.get('content-type')||'').split(';')[0].toLowerCase();if(!ct.startsWith('image/'))return {ok:false,response:json({ok:false,error:'IMAGE_REQUIRED'},415)};const bytes=await request.arrayBuffer();if(!bytes.byteLength||bytes.byteLength>10_000_000)return {ok:false,response:json({ok:false,error:'IMAGE_TOO_LARGE'},413)};const ext=ct.includes('png')?'png':ct.includes('heic')?'heic':'jpg';const key=`private/${keyPrefix}/${crypto.randomUUID()}.${ext}`;await env.HOTELS_MEDIA.put(key,bytes,{httpMetadata:{contentType:ct}});return {ok:true,key,ct,size:bytes.byteLength};}
async function uploadTravelerPassport(request,env,bookingID,position,auth){if(normalizedTripStatus(auth.trip?.status)!=='payment_pending')return json({ok:false,error:'TRAVELER_EDITING_CLOSED'},409);const row=await env.HOTELS_DB.prepare('SELECT * FROM booking_travelers WHERE booking_id=? AND position=?').bind(bookingID,position).first();if(!row)return json({ok:false,error:'TRAVELER_NOT_FOUND'},404);const up=await privateImageUpload(request,env,`passports/${bookingID}`);if(!up.ok)return up.response;if(row.passport_object_key)await env.HOTELS_MEDIA.delete(row.passport_object_key).catch(()=>{});const complete=travelerComplete({firstName:row.first_name,lastName:row.last_name,gender:row.gender,dateOfBirth:row.date_of_birth,placeOfBirth:row.place_of_birth,nationality:row.nationality,residenceCountry:row.residence_country,passportNumber:row.passport_number,passportIssueDate:row.passport_issue_date,passportExpiryDate:row.passport_expiry_date,passportIssuingCountry:row.passport_issuing_country,phone:row.phone,emergencyName:row.emergency_name,emergencyPhone:row.emergency_phone,emergencyRelation:row.emergency_relation},true);await env.HOTELS_DB.prepare('UPDATE booking_travelers SET passport_object_key=?,passport_content_type=?,completed=?,updated_at=? WHERE booking_id=? AND position=?').bind(up.key,up.ct,complete?1:0,new Date().toISOString(),bookingID,position).run();return json({ok:true,hasPassport:true});}
async function uploadPaymentReceipt(request,env,bookingID,auth){if(normalizedTripStatus(auth.trip?.status)!=='payment_pending')return json({ok:false,error:'PAYMENT_SUBMISSION_CLOSED'},409);const method=cleanText(request.headers.get('x-payment-method') || new URL(request.url).searchParams.get('method'),20)||'other';if(!['visa','payme','humo','other'].includes(method))return json({ok:false,error:'INVALID_PAYMENT_METHOD'},400);const up=await privateImageUpload(request,env,`receipts/${bookingID}`);if(!up.ok)return up.response;const id=crypto.randomUUID();await env.HOTELS_DB.prepare('INSERT INTO booking_payment_receipts(id,booking_id,payment_method,object_key,content_type,byte_size) VALUES(?,?,?,?,?,?)').bind(id,bookingID,method,up.key,up.ct,up.size).run();await env.HOTELS_DB.prepare("UPDATE pilgrim_trips SET payment_status='receipt_submitted',updated_at=? WHERE booking_id=?").bind(new Date().toISOString(),bookingID).run();await sendStaffPush(env,'Новый чек оплаты',`Бронь ${bookingID} · iumrah ID ${pilgrimPublicID(auth.pilgrim.id)}`,{type:'payment_receipt',bookingID}).catch(()=>{});return json({ok:true,id});}
async function serveClientPrivateMedia(env,bookingID,mediaID){let key=null,ct='application/octet-stream';if(mediaID==='payment-qr'){const r=await env.HOTELS_DB.prepare('SELECT payme_qr_object_key,payme_qr_content_type FROM booking_payment_instructions WHERE booking_id=?').bind(bookingID).first();key=r?.payme_qr_object_key;ct=r?.payme_qr_content_type||'image/png';}else if(mediaID.startsWith('document-')){const id=mediaID.slice(9);const r=await env.HOTELS_DB.prepare('SELECT object_key,content_type FROM booking_travel_documents WHERE id=? AND booking_id=?').bind(id,bookingID).first();key=r?.object_key;ct=r?.content_type||ct;}if(!key)return json({ok:false,error:'MEDIA_NOT_FOUND'},404);const obj=await env.HOTELS_MEDIA.get(key);if(!obj)return json({ok:false,error:'MEDIA_NOT_FOUND'},404);return new Response(obj.body,{headers:{'content-type':ct,'cache-control':'private, no-store'}});}

async function sendClientChatMessage(request, env, bookingID, user) {
  const payload = await request.json().catch(() => null);
  const body = safeHumanText(payload?.body, 4000);
  if (!body) return json({ ok: false, error: 'EMPTY_MESSAGE' }, 400);
  const clientMessageID = safeID(payload?.clientMessageID) || null;
  if (clientMessageID) {
    const existing = await env.HOTELS_DB.prepare('SELECT id FROM business_chat_messages WHERE booking_id=? AND client_message_id=? LIMIT 1').bind(bookingID, clientMessageID).first();
    if (existing?.id) return chatMessageDetail(env, existing.id, 200, false);
  }
  const id = crypto.randomUUID();
  const now = new Date().toISOString();
  const senderName = await bookingPilgrimName(env, bookingID, safeHumanText(user?.displayName || user?.name || '', 160) || '');
  try {
    // Keep these writes sequential. Besides producing clearer diagnostics, this makes
    // the parent thread unquestionably visible before the FK-constrained message write.
    await env.HOTELS_DB.prepare(`INSERT INTO business_chat_threads (booking_id, created_at, updated_at, last_message_at, last_message_preview, last_sender_type, unread_for_staff) VALUES (?, ?, ?, ?, ?, 'client', 1) ON CONFLICT(booking_id) DO UPDATE SET updated_at=excluded.updated_at, last_message_at=excluded.last_message_at, last_message_preview=excluded.last_message_preview, last_sender_type='client', unread_for_staff=1`)
      .bind(bookingID, now, now, now, body.slice(0,240)).run();
    await env.HOTELS_DB.prepare(`INSERT INTO business_chat_messages (id, booking_id, sender_type, sender_name, body, created_at, read_by_staff, client_message_id, message_type) VALUES (?, ?, 'client', ?, ?, ?, 0, ?, 'text')`)
      .bind(id, bookingID, senderName, body, now, clientMessageID).run();
  } catch (error) {
    // If the client retried after a network timeout, return the already-created message.
    if (clientMessageID) {
      const existing = await env.HOTELS_DB.prepare('SELECT id FROM business_chat_messages WHERE booking_id=? AND client_message_id=? LIMIT 1')
        .bind(bookingID, clientMessageID).first().catch(() => null);
      if (existing?.id) return chatMessageDetail(env, existing.id, 200, false);
    }
    console.error('CLIENT_CHAT_WRITE_FAILED', bookingID, error);
    return json({ ok: false, error: 'CHAT_MESSAGE_WRITE_FAILED' }, 500);
  }
  await sendStaffPush(env, senderName, body.slice(0, 180), { type: 'chat_message', bookingID }).catch(() => {});
  return chatMessageDetail(env, id, 201, false);
}

async function markClientChatRead(env, bookingID) {
  return json({ ok: true });
}

async function sendChatAttachment(request, env, bookingID, user, staff = true) {
  const contentType = String(request.headers.get('content-type') || '').split(';')[0].trim().toLowerCase();
  if (!contentType.startsWith('image/')) return json({ ok: false, error: 'IMAGE_REQUIRED' }, 415);
  const sourceBytes = await request.arrayBuffer();
  if (!sourceBytes.byteLength || sourceBytes.byteLength > 12_000_000) return json({ ok: false, error: 'IMAGE_TOO_LARGE' }, 413);
  let transformed;
  try { transformed = await optimizeHotelImageBytes(env, sourceBytes, { category: 'gallery', isCover: false, sourceContentType: contentType }); }
  catch (error) { return json({ ok: false, error: String(error?.message || 'IMAGE_OPTIMIZATION_FAILED') }, 422); }
  const attachmentID = crypto.randomUUID();
  const extension = transformed.extension || 'webp';
  const objectKey = `chat/${bookingID}/${attachmentID}.${extension}`;
  await env.HOTELS_MEDIA.put(objectKey, transformed.bytes, { httpMetadata: { contentType: transformed.contentType } });
  const now = new Date().toISOString();
  const messageID = crypto.randomUUID();
  const senderType = staff ? 'staff' : 'client';
  const senderName = staff
    ? await staffDisplayName(env, user)
    : await bookingPilgrimName(env, bookingID, safeHumanText(user?.displayName || user?.name || '', 160) || '');
  const preview = 'Фотография';
  try {
    await env.HOTELS_DB.batch([
      env.HOTELS_DB.prepare(`INSERT INTO business_chat_threads (booking_id, created_at, updated_at, last_message_at, last_message_preview, last_sender_type, unread_for_staff) VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT(booking_id) DO UPDATE SET updated_at=excluded.updated_at, last_message_at=excluded.last_message_at, last_message_preview=excluded.last_message_preview, last_sender_type=excluded.last_sender_type, unread_for_staff=excluded.unread_for_staff`).bind(bookingID, now, now, now, preview, senderType, staff ? 0 : 1),
      env.HOTELS_DB.prepare('INSERT INTO business_chat_attachments (id, booking_id, object_key, content_type, byte_size, width, height, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)').bind(attachmentID, bookingID, objectKey, transformed.contentType, transformed.bytes.byteLength, transformed.width, transformed.height, now),
      env.HOTELS_DB.prepare(`INSERT INTO business_chat_messages (id, booking_id, sender_type, sender_name, body, created_at, read_by_staff, message_type, attachment_id) VALUES (?, ?, ?, ?, '', ?, ?, 'image', ?)`).bind(messageID, bookingID, senderType, senderName, now, staff ? 1 : 0, attachmentID)
    ]);
  } catch (error) {
    await env.HOTELS_MEDIA.delete(objectKey).catch(() => {});
    throw error;
  }
  if (staff) {
    await sendClientPush(env, bookingID, 'iumrah Care', 'Фотография', { type: 'chat_image', bookingID }).catch(() => {});
  } else {
    await sendStaffPush(env, senderName, 'Фотография', { type: 'chat_image', bookingID }).catch(() => {});
  }
  return chatMessageDetail(env, messageID, 201, staff);
}

async function serveChatAttachment(env, bookingID, attachmentID) {
  const safeAttachmentID = safeID(attachmentID);
  if (!safeAttachmentID) return json({ ok: false, error: 'INVALID_ATTACHMENT_ID' }, 400);
  const row = await env.HOTELS_DB.prepare('SELECT * FROM business_chat_attachments WHERE id=? AND booking_id=? LIMIT 1').bind(safeAttachmentID, bookingID).first();
  if (!row) return json({ ok: false, error: 'ATTACHMENT_NOT_FOUND' }, 404);
  const object = await env.HOTELS_MEDIA.get(row.object_key);
  if (!object) return json({ ok: false, error: 'ATTACHMENT_NOT_FOUND' }, 404);
  const headers = new Headers();
  headers.set('content-type', row.content_type || 'image/webp');
  headers.set('cache-control', 'private, max-age=3600');
  return new Response(object.body, { status: 200, headers });
}


async function requireStaff(request, env, options = {}) {
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

  if (options.allowSessionRegistration === true) {
    return { ok: true, user, businessSession: null };
  }
  const business = await requireBusinessSession(request, env, user);
  if (!business.ok) return business;
  return { ok: true, user, businessSession: business.session || null };
}

async function health(env, admin) {
  const row = await env.HOTELS_DB.prepare(
    admin
      ? 'SELECT COUNT(*) AS count FROM hotels'
      : "SELECT COUNT(*) AS count FROM hotels WHERE status = 'published'"
  ).first();

  let bookingsDbReady = false;
  let sourceBookings = 0;
  if (env.BOOKINGS_DB) {
    try {
      const bookings = await env.BOOKINGS_DB.prepare('SELECT COUNT(*) AS count FROM bookings').first();
      sourceBookings = Number(bookings?.count || 0);
      bookingsDbReady = true;
    } catch (error) {
      console.error('BOOKINGS_DB_HEALTH_FAILED', error);
    }
  }

  return json({
    ok: bookingsDbReady,
    database: 'iumrah-hotels',
    storage: 'iumrah-hotels-media',
    hotels: Number(row?.count || 0),
    bookingsDbReady,
    sourceBookings
  }, bookingsDbReady ? 200 : 503, PUBLIC_CACHE_HEADERS);
}

async function listHotels(env, url, publishedOnly) {
  const city = cleanText(url.searchParams.get('city'), 80);
  const values = [];
  const where = [];

  if (publishedOnly) {
    where.push("h.status = 'published'");
    where.push("hp.status = 'fresh'");
    where.push('hp.nightly_price_usd IS NOT NULL');
    where.push('hp.expires_at > ?');
    values.push(new Date().toISOString());
  }
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
      ) AS cover_image_id,
      hp.provider AS price_provider,
      hp.source_url AS price_source_url,
      hp.resolved_url AS price_resolved_url,
      hp.amount_original AS price_amount_original,
      hp.currency_original AS price_currency_original,
      hp.price_basis AS price_basis,
      hp.nightly_price_usd AS price_nightly_usd,
      hp.quote_total_usd AS price_quote_total_usd,
      hp.quote_check_in AS price_quote_check_in,
      hp.quote_check_out AS price_quote_check_out,
      hp.quote_nights AS price_quote_nights,
      hp.quote_adults AS price_quote_adults,
      hp.quote_rooms AS price_quote_rooms,
      hp.confidence AS price_confidence,
      hp.method AS price_method,
      hp.status AS price_status,
      hp.fetched_at AS price_fetched_at,
      hp.expires_at AS price_expires_at,
      hp.last_attempt_at AS price_last_attempt_at,
      hp.next_retry_at AS price_next_retry_at,
      hp.error AS price_error
    FROM hotels h
    LEFT JOIN hotel_price_cache hp ON hp.hotel_id = h.id
    ${where.length ? `WHERE ${where.join(' AND ')}` : ''}
    ORDER BY
      CASE LOWER(h.city) WHEN 'makkah' THEN 0 WHEN 'madinah' THEN 1 ELSE 2 END,
      h.name COLLATE NOCASE ASC
    LIMIT 500
  `;

  const result = await env.HOTELS_DB.prepare(sql).bind(...values).all();
  const hotels = (result.results || []).map(row => {
    const summary = hotelSummary(row);
    if (publishedOnly && summary?.price) summary.price = publicHotelPrice(summary.price);
    return summary;
  });
  return json({ hotels }, 200, publishedOnly ? PUBLIC_CACHE_HEADERS : undefined);
}

async function hotelDetail(env, hotelID, admin, url = null) {
  const hotel = await env.HOTELS_DB.prepare(
    `SELECT * FROM hotels WHERE id = ? ${admin ? '' : "AND status = 'published'"}`
  ).bind(hotelID).first();

  if (!hotel) return json({ ok: false, error: 'HOTEL_NOT_FOUND' }, 404);

  const [amenitiesResult, roomsResult, imagesResult, sourcesResult, priceResult] = await Promise.all([
    env.HOTELS_DB.prepare('SELECT amenity FROM hotel_amenities WHERE hotel_id = ? ORDER BY position ASC, amenity ASC').bind(hotelID).all(),
    env.HOTELS_DB.prepare('SELECT id, name, max_guests, size_m2, beds, view, description, amenities_json, smoking, accessibility_json, category, bathroom_json FROM hotel_rooms WHERE hotel_id = ? ORDER BY position ASC, name ASC').bind(hotelID).all(),
    env.HOTELS_DB.prepare('SELECT id, source_provider, category, label, room_name, position, is_cover, width, height, byte_size, original_byte_size, content_type, transform_version FROM hotel_images WHERE hotel_id = ? ORDER BY is_cover DESC, position ASC, created_at ASC').bind(hotelID).all(),
    admin
      ? env.HOTELS_DB.prepare('SELECT * FROM hotel_sources WHERE hotel_id = ? ORDER BY provider ASC').bind(hotelID).all()
      : Promise.resolve({ results: [] }),
    env.HOTELS_DB.prepare('SELECT * FROM hotel_price_cache WHERE hotel_id=? LIMIT 1').bind(hotelID).first()
  ]);

  const effectivePublicPrice = publicHotelPrice(hotelPriceRow(priceResult));
  if (!admin && !effectivePublicPrice) {
    return json({ ok: false, error: 'HOTEL_PRICE_UNAVAILABLE' }, 404, PUBLIC_CACHE_HEADERS);
  }

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
    price: admin ? hotelPriceRow(priceResult) : effectivePublicPrice,
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

  const importedPriceSeed = await seedHotelPriceFromDraft(env, id, draft);
  if (!importedPriceSeed.ok) {
    console.warn('HOTEL_IMPORT_PRICE_NOT_SEEDED', { hotelID: id, error: importedPriceSeed.error });
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



const HOTEL_PRICE_FETCH_HEADERS = {
  'user-agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Mobile/15E148 Safari/604.1',
  'accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
  'accept-language': 'en-US,en;q=0.9',
  'cache-control': 'no-cache'
};

async function loadRenderedHotelPricePage(env, probeURL) {
  if (env.BROWSER?.quickAction) {
    try {
      const response = await env.BROWSER.quickAction('content', {
        url: probeURL,
        userAgent: HOTEL_PRICE_FETCH_HEADERS['user-agent'],
        setExtraHTTPHeaders: {
          'Accept-Language': HOTEL_PRICE_FETCH_HEADERS['accept-language']
        },
        gotoOptions: {
          waitUntil: 'networkidle2',
          timeout: 30000
        },
        waitForTimeout: 1800
      });
      const httpStatus = response.status;
      if (response.ok) {
        const payload = await response.json();
        const html = payload?.success && typeof payload.result === 'string' ? payload.result : null;
        if (html && html.length >= 500) {
          return { ok: true, html, resolvedURL: probeURL, httpStatus, transport: 'browser-run' };
        }
        return { ok: false, error: 'PRICE_BROWSER_EMPTY_PAGE', httpStatus, transport: 'browser-run' };
      }
      const detail = (await response.text()).slice(0, 300);
      console.warn('HOTEL_PRICE_BROWSER_RUN_HTTP', { status: httpStatus, detail });
    } catch (error) {
      console.warn('HOTEL_PRICE_BROWSER_RUN_FAILED', String(error?.message || error));
    }
  }

  try {
    const response = await fetch(probeURL, {
      headers: HOTEL_PRICE_FETCH_HEADERS,
      redirect: 'follow',
      cf: { cacheTtl: 0 }
    });
    if (!response.ok) return { ok: false, error: `PRICE_HTTP_${response.status}`, httpStatus: response.status, transport: 'static-fetch' };
    const html = await response.text();
    return { ok: true, html, resolvedURL: response.url || probeURL, httpStatus: response.status, transport: 'static-fetch' };
  } catch (error) {
    return { ok: false, error: `PRICE_FETCH_FAILED: ${String(error?.message || error).slice(0, 320)}`, httpStatus: null, transport: 'static-fetch' };
  }
}

function importedPriceUSD(amount, currency) {
  const value = Number(amount);
  const token = String(currency || '').trim().toUpperCase();
  if (!Number.isFinite(value) || value <= 0) return null;
  if (token === 'USD' || token === 'US$' || token === '$') return value;
  if (token === 'SAR' || token === 'SR') return value / 3.75;
  if (token === 'AED') return value / 3.6725;
  return null;
}

function importedPriceCandidate(draft) {
  const sources = Array.isArray(draft?.sources) ? draft.sources : [];
  const candidates = [];
  for (const source of sources) {
    const price = source?.price;
    const provider = canonicalPriceProvider(source?.provider, safeURLObject(source?.sourceURL));
    const sourceURL = cleanURL(source?.canonicalURL) || cleanURL(source?.sourceURL);
    if (!price || !provider || !sourceURL) continue;
    const amount = Number(price.amount);
    const currency = cleanText(price.currency, 12)?.toUpperCase();
    const nights = nullableInteger(price.nights, 1, 30) || 1;
    const adults = nullableInteger(price.adults, 1, 20) || 2;
    const rooms = nullableInteger(price.rooms, 1, 20) || 1;
    const basis = price.priceBasis === 'stay_total' ? 'stay_total' : 'nightly';
    const amountUSD = importedPriceUSD(amount, currency);
    if (!amountUSD) continue;
    const nightlyUSD = basis === 'stay_total' ? amountUSD / nights : amountUSD;
    if (!Number.isFinite(nightlyUSD) || nightlyUSD < 15 || nightlyUSD > 5000) continue;
    const totalAmount = Number(price.totalAmount);
    const totalCurrency = cleanText(price.totalCurrency, 12)?.toUpperCase() || currency;
    const explicitTotalUSD = Number.isFinite(totalAmount) && totalAmount > 0 ? importedPriceUSD(totalAmount, totalCurrency) : null;
    const quoteTotalUSD = explicitTotalUSD || (basis === 'stay_total' ? amountUSD : nightlyUSD * nights);
    const confidence = Math.max(0.5, Math.min(0.999, Number(price.confidence) || 0.9));
    const roomName = cleanText(price.roomName, 240) || '';
    const preferred = /(double|twin|standard|classic)/i.test(roomName);
    candidates.push({ source, price, provider, sourceURL, amount, currency, basis, nights, adults, rooms, nightlyUSD, quoteTotalUSD, confidence, preferred });
  }
  candidates.sort((a, b) => {
    if (a.preferred !== b.preferred) return a.preferred ? -1 : 1;
    if (Math.abs(b.confidence - a.confidence) > 0.03) return b.confidence - a.confidence;
    return a.nightlyUSD - b.nightlyUSD;
  });
  return candidates[0] || null;
}

async function seedHotelPriceFromDraft(env, hotelID, draft) {
  const candidate = importedPriceCandidate(draft);
  if (!candidate) return { ok: false, error: 'IMPORT_PRICE_MISSING' };
  const now = new Date().toISOString();
  const expiresAt = new Date(Date.now() + HOTEL_PRICE_TTL_MS).toISOString();
  const sourceID = cleanText(candidate.source?.id, 180);
  const resolvedURL = cleanURL(candidate.source?.canonicalURL) || candidate.sourceURL;
  const method = cleanText(`importer:${candidate.price?.method || 'verified-browser'}`, 160);
  await env.HOTELS_DB.prepare(`
    INSERT INTO hotel_price_cache (
      hotel_id, source_id, provider, source_url, resolved_url,
      amount_original, currency_original, price_basis, nightly_price_usd, quote_total_usd,
      quote_check_in, quote_check_out, quote_nights, quote_adults, quote_rooms,
      confidence, method, status, fetched_at, expires_at, last_attempt_at,
      next_retry_at, last_http_status, error, updated_at
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'fresh', ?, ?, ?, NULL, NULL, NULL, ?)
    ON CONFLICT(hotel_id) DO UPDATE SET
      source_id=excluded.source_id,
      provider=excluded.provider,
      source_url=excluded.source_url,
      resolved_url=excluded.resolved_url,
      amount_original=excluded.amount_original,
      currency_original=excluded.currency_original,
      price_basis=excluded.price_basis,
      nightly_price_usd=excluded.nightly_price_usd,
      quote_total_usd=excluded.quote_total_usd,
      quote_check_in=excluded.quote_check_in,
      quote_check_out=excluded.quote_check_out,
      quote_nights=excluded.quote_nights,
      quote_adults=excluded.quote_adults,
      quote_rooms=excluded.quote_rooms,
      confidence=excluded.confidence,
      method=excluded.method,
      status='fresh',
      fetched_at=excluded.fetched_at,
      expires_at=excluded.expires_at,
      last_attempt_at=excluded.last_attempt_at,
      next_retry_at=NULL,
      last_http_status=NULL,
      error=NULL,
      updated_at=excluded.updated_at
  `).bind(
    hotelID,
    sourceID,
    candidate.provider,
    candidate.sourceURL,
    resolvedURL,
    candidate.amount,
    candidate.currency,
    candidate.basis,
    Math.round(candidate.nightlyUSD * 100) / 100,
    Math.round(candidate.quoteTotalUSD * 100) / 100,
    cleanText(candidate.price?.checkIn, 32),
    cleanText(candidate.price?.checkOut, 32),
    candidate.nights,
    candidate.adults,
    candidate.rooms,
    candidate.confidence,
    method,
    now,
    expiresAt,
    now,
    now
  ).run();
  return { ok: true, nightlyUSD: candidate.nightlyUSD, provider: candidate.provider };
}

async function runHotelPriceScheduler(env) {
  try {
    await runHotelCatalogMaintenance(env);
  } catch (error) {
    console.error('HOTEL_CATALOG_MAINTENANCE_FAILED', String(error?.message || error));
  }

  try {
    await refreshDueHotelPrices(env);
  } catch (error) {
    console.error('HOTEL_PRICE_SCHEDULER_FAILED', String(error?.message || error));
  }
}

async function refreshDueHotelPrices(env) {
  const now = new Date().toISOString();
  const due = await env.HOTELS_DB.prepare(`
    SELECT h.id
    FROM hotels h
    LEFT JOIN hotel_price_cache hp ON hp.hotel_id = h.id
    WHERE h.status != 'archived'
      AND EXISTS (
        SELECT 1 FROM hotel_sources hs
        WHERE hs.hotel_id = h.id AND LOWER(hs.provider) IN ('booking','expedia')
      )
      AND (
        hp.hotel_id IS NULL
        OR (hp.status = 'fresh' AND (hp.expires_at IS NULL OR hp.expires_at <= ?))
        OR (hp.status IN ('stale','failed','pending') AND (hp.next_retry_at IS NULL OR hp.next_retry_at <= ?))
      )
    ORDER BY COALESCE(hp.next_retry_at, hp.expires_at, h.created_at) ASC
    LIMIT 12
  `).bind(now, now).all();

  const hotelIDs = (due.results || []).map(row => safeID(row.id)).filter(Boolean);
  for (let start = 0; start < hotelIDs.length; start += 3) {
    const group = hotelIDs.slice(start, start + 3);
    await Promise.allSettled(group.map(hotelID => refreshHotelPrice(env, hotelID, { reason: 'scheduled' })));
  }
  return { attempted: hotelIDs.length };
}

async function refreshHotelPriceResponse(env, hotelID) {
  const hotel = await env.HOTELS_DB.prepare('SELECT id FROM hotels WHERE id=? LIMIT 1').bind(hotelID).first();
  if (!hotel) return json({ ok: false, error: 'HOTEL_NOT_FOUND' }, 404);
  const result = await refreshHotelPrice(env, hotelID, { reason: 'manual', force: true });
  return json({ ok: result.ok, price: await hotelPriceRecord(env, hotelID), error: result.error || null }, result.ok ? 200 : 502);
}

async function hotelPriceDetail(env, hotelID) {
  const hotel = await env.HOTELS_DB.prepare('SELECT id FROM hotels WHERE id=? LIMIT 1').bind(hotelID).first();
  if (!hotel) return json({ ok: false, error: 'HOTEL_NOT_FOUND' }, 404);
  return json({ ok: true, price: await hotelPriceRecord(env, hotelID) });
}

async function refreshHotelPrice(env, hotelID, options = {}) {
  const id = safeID(hotelID);
  if (!id) return { ok: false, error: 'INVALID_HOTEL_ID' };

  const source = await env.HOTELS_DB.prepare(`
    SELECT id, hotel_id, provider, source_url, canonical_url, checked_at
    FROM hotel_sources
    WHERE hotel_id=? AND LOWER(provider) IN ('booking','expedia')
    ORDER BY
      CASE LOWER(provider) WHEN 'booking' THEN 0 WHEN 'expedia' THEN 1 ELSE 2 END,
      checked_at DESC
    LIMIT 1
  `).bind(id).first();

  if (!source?.source_url) {
    await markHotelPriceFailure(env, id, null, 'PRICE_SOURCE_MISSING');
    return { ok: false, error: 'PRICE_SOURCE_MISSING' };
  }

  const sourceURL = cleanURL(source.canonical_url) || cleanURL(source.source_url);
  if (!sourceURL) {
    await markHotelPriceFailure(env, id, source, 'PRICE_SOURCE_INVALID_URL');
    return { ok: false, error: 'PRICE_SOURCE_INVALID_URL' };
  }

  let parsedSource;
  try { parsedSource = new URL(sourceURL); }
  catch (_) {
    await markHotelPriceFailure(env, id, source, 'PRICE_SOURCE_INVALID_URL');
    return { ok: false, error: 'PRICE_SOURCE_INVALID_URL' };
  }

  const provider = canonicalPriceProvider(source.provider, parsedSource);
  if (!provider) {
    await markHotelPriceFailure(env, id, source, 'PRICE_PROVIDER_UNSUPPORTED');
    return { ok: false, error: 'PRICE_PROVIDER_UNSUPPORTED' };
  }

  const attemptedAt = new Date().toISOString();
  await env.HOTELS_DB.prepare(`
    INSERT INTO hotel_price_cache (
      hotel_id, source_id, provider, source_url, status, last_attempt_at, next_retry_at, updated_at
    ) VALUES (?, ?, ?, ?, 'pending', ?, ?, ?)
    ON CONFLICT(hotel_id) DO UPDATE SET
      source_id=excluded.source_id,
      provider=excluded.provider,
      source_url=excluded.source_url,
      status=CASE WHEN hotel_price_cache.nightly_price_usd IS NULL THEN 'pending' ELSE hotel_price_cache.status END,
      last_attempt_at=excluded.last_attempt_at,
      next_retry_at=excluded.next_retry_at,
      updated_at=excluded.updated_at
  `).bind(
    id,
    cleanText(source.id, 180),
    provider,
    sourceURL,
    attemptedAt,
    new Date(Date.now() + HOTEL_PRICE_RETRY_MS).toISOString(),
    attemptedAt
  ).run();

  const probes = buildHotelPriceProbeURLs(parsedSource, provider);
  let lastError = 'PRICE_NOT_FOUND';
  let lastHTTPStatus = null;

  for (const probeURL of probes) {
    const page = await loadRenderedHotelPricePage(env, probeURL);
    lastHTTPStatus = page.httpStatus;
    if (!page.ok) {
      lastError = page.error || 'PRICE_PAGE_LOAD_FAILED';
      continue;
    }

    const finalURL = page.resolvedURL || probeURL;
    let parsedFinal;
    try { parsedFinal = new URL(finalURL); }
    catch (_) {
      lastError = 'PRICE_BAD_REDIRECT';
      continue;
    }
    if (!samePricePropertyIdentity(parsedFinal, parsedSource, provider)) {
      lastError = 'PRICE_SOURCE_IDENTITY_MISMATCH';
      continue;
    }

    const html = page.html;
    if (!html || html.length < 500) {
      lastError = 'PRICE_EMPTY_PAGE';
      continue;
    }
    if (html.length > 8_000_000) {
      lastError = 'PRICE_PAGE_TOO_LARGE';
      continue;
    }
    if (isProviderChallengeHTML(html)) {
      lastError = 'PRICE_PROVIDER_CHALLENGE';
      continue;
    }

    const quote = extractHotelPriceFromHTML(html, provider);
    if (!quote) {
      lastError = 'PRICE_NOT_FOUND_IN_PROPERTY_PAGE';
      continue;
    }

    const context = quoteContextFromProbeURL(probeURL, provider);
    const fetchedAt = new Date().toISOString();
    const expiresAt = new Date(Date.now() + HOTEL_PRICE_TTL_MS).toISOString();
    await env.HOTELS_DB.prepare(`
      INSERT INTO hotel_price_cache (
        hotel_id, source_id, provider, source_url, resolved_url,
        amount_original, currency_original, price_basis, nightly_price_usd, quote_total_usd,
        quote_check_in, quote_check_out, quote_nights, quote_adults, quote_rooms,
        confidence, method, status, fetched_at, expires_at, last_attempt_at,
        next_retry_at, last_http_status, error, updated_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'fresh', ?, ?, ?, NULL, ?, NULL, ?)
      ON CONFLICT(hotel_id) DO UPDATE SET
        source_id=excluded.source_id,
        provider=excluded.provider,
        source_url=excluded.source_url,
        resolved_url=excluded.resolved_url,
        amount_original=excluded.amount_original,
        currency_original=excluded.currency_original,
        price_basis=excluded.price_basis,
        nightly_price_usd=excluded.nightly_price_usd,
        quote_total_usd=excluded.quote_total_usd,
        quote_check_in=excluded.quote_check_in,
        quote_check_out=excluded.quote_check_out,
        quote_nights=excluded.quote_nights,
        quote_adults=excluded.quote_adults,
        quote_rooms=excluded.quote_rooms,
        confidence=excluded.confidence,
        method=excluded.method,
        status='fresh',
        fetched_at=excluded.fetched_at,
        expires_at=excluded.expires_at,
        last_attempt_at=excluded.last_attempt_at,
        next_retry_at=NULL,
        last_http_status=excluded.last_http_status,
        error=NULL,
        updated_at=excluded.updated_at
    `).bind(
      id,
      cleanText(source.id, 180),
      provider,
      sourceURL,
      finalURL,
      quote.amount,
      quote.currency,
      quote.priceBasis,
      quote.nightlyUSD,
      quote.stayTotalUSD,
      context.checkIn,
      context.checkOut,
      context.nights,
      context.adults,
      context.rooms,
      quote.confidence,
      cleanText(`${page.transport || 'unknown'}:${quote.method}`, 160),
      fetchedAt,
      expiresAt,
      fetchedAt,
      lastHTTPStatus,
      fetchedAt
    ).run();

    console.log('HOTEL_PRICE_REFRESHED', {
      hotelID: id,
      provider,
      nightlyUSD: quote.nightlyUSD,
      quoteTotalUSD: quote.stayTotalUSD,
      checkIn: context.checkIn,
      checkOut: context.checkOut,
      reason: options.reason || 'unknown'
    });
    return { ok: true, price: quote, provider, context };
  }

  await markHotelPriceFailure(env, id, source, lastError, lastHTTPStatus);
  console.warn('HOTEL_PRICE_REFRESH_FAILED', { hotelID: id, provider, error: lastError, reason: options.reason || 'unknown' });
  return { ok: false, error: lastError };
}

async function markHotelPriceFailure(env, hotelID, source, error, httpStatus = null) {
  const now = new Date().toISOString();
  const nextRetry = new Date(Date.now() + HOTEL_PRICE_RETRY_MS).toISOString();
  const provider = source ? canonicalPriceProvider(source.provider, safeURLObject(source.source_url)) : null;
  const sourceURL = source ? cleanURL(source.canonical_url) || cleanURL(source.source_url) : null;
  await env.HOTELS_DB.prepare(`
    INSERT INTO hotel_price_cache (
      hotel_id, source_id, provider, source_url, status, last_attempt_at,
      next_retry_at, last_http_status, error, updated_at
    ) VALUES (?, ?, ?, ?, 'failed', ?, ?, ?, ?, ?)
    ON CONFLICT(hotel_id) DO UPDATE SET
      source_id=COALESCE(excluded.source_id, hotel_price_cache.source_id),
      provider=COALESCE(excluded.provider, hotel_price_cache.provider),
      source_url=COALESCE(excluded.source_url, hotel_price_cache.source_url),
      status=CASE WHEN hotel_price_cache.nightly_price_usd IS NULL THEN 'failed' ELSE 'stale' END,
      last_attempt_at=excluded.last_attempt_at,
      next_retry_at=excluded.next_retry_at,
      last_http_status=excluded.last_http_status,
      error=excluded.error,
      updated_at=excluded.updated_at
  `).bind(
    hotelID,
    cleanText(source?.id, 180),
    provider,
    sourceURL,
    now,
    nextRetry,
    httpStatus,
    cleanText(error, 900) || 'PRICE_REFRESH_FAILED',
    now
  ).run();
}

async function hotelPriceRecord(env, hotelID) {
  const row = await env.HOTELS_DB.prepare('SELECT * FROM hotel_price_cache WHERE hotel_id=? LIMIT 1').bind(hotelID).first();
  return hotelPriceRow(row);
}

function hotelPriceRow(row) {
  if (!row) return null;
  const prefixed = Object.prototype.hasOwnProperty.call(row, 'price_status')
    || Object.prototype.hasOwnProperty.call(row, 'price_nightly_usd')
    || Object.prototype.hasOwnProperty.call(row, 'price_provider');
  const directCache = Object.prototype.hasOwnProperty.call(row, 'hotel_id')
    && (Object.prototype.hasOwnProperty.call(row, 'nightly_price_usd') || Object.prototype.hasOwnProperty.call(row, 'fetched_at'));
  if (!prefixed && !directCache) return null;
  if (prefixed && row.price_status == null && row.price_nightly_usd == null && row.price_provider == null) return null;
  return {
    provider: prefixed ? (row.price_provider || null) : (row.provider || null),
    sourceURL: row.price_source_url || row.source_url || null,
    resolvedURL: row.price_resolved_url || row.resolved_url || null,
    amountOriginal: nullableRowNumber(row.price_amount_original ?? row.amount_original),
    currencyOriginal: row.price_currency_original || row.currency_original || null,
    priceBasis: row.price_basis || null,
    nightlyUSD: nullableRowNumber(row.price_nightly_usd ?? row.nightly_price_usd),
    quoteTotalUSD: nullableRowNumber(row.price_quote_total_usd ?? row.quote_total_usd),
    checkIn: row.price_quote_check_in || row.quote_check_in || null,
    checkOut: row.price_quote_check_out || row.quote_check_out || null,
    nights: nullableRowInteger(row.price_quote_nights ?? row.quote_nights),
    adults: nullableRowInteger(row.price_quote_adults ?? row.quote_adults),
    rooms: nullableRowInteger(row.price_quote_rooms ?? row.quote_rooms),
    confidence: nullableRowNumber(row.price_confidence ?? row.confidence),
    method: row.price_method || row.method || null,
    status: prefixed ? (row.price_status || 'pending') : (row.status || 'pending'),
    fetchedAt: row.price_fetched_at || row.fetched_at || null,
    expiresAt: row.price_expires_at || row.expires_at || null,
    lastAttemptAt: row.price_last_attempt_at || row.last_attempt_at || null,
    nextRetryAt: row.price_next_retry_at || row.next_retry_at || null,
    error: row.price_error || row.error || null
  };
}

function publicHotelPrice(price) {
  if (!price || price.status !== 'fresh' || price.nightlyUSD == null) return null;
  if (!price.expiresAt || Date.parse(price.expiresAt) <= Date.now()) return null;
  return {
    provider: price.provider || null,
    nightlyUSD: price.nightlyUSD == null ? null : Number(price.nightlyUSD),
    status: price.status || 'pending',
    fetchedAt: price.fetchedAt || null,
    expiresAt: price.expiresAt || null,
    checkIn: price.checkIn || null,
    checkOut: price.checkOut || null,
    nights: price.nights == null ? null : Number(price.nights),
    adults: price.adults == null ? null : Number(price.adults),
    rooms: price.rooms == null ? null : Number(price.rooms)
  };
}

function nullableRowNumber(value) {
  if (value == null || value === '') return null;
  const number = Number(value);
  return Number.isFinite(number) ? number : null;
}

function nullableRowInteger(value) {
  const number = nullableRowNumber(value);
  return number == null ? null : Math.trunc(number);
}

function canonicalPriceProvider(rawProvider, sourceURL) {
  const provider = String(rawProvider || '').trim().toLowerCase();
  if (provider === 'booking') return 'Booking';
  if (provider === 'expedia') return 'Expedia';
  return sourceURL ? detectRoomProvider(sourceURL) : null;
}

function safeURLObject(value) {
  try { return value ? new URL(String(value)) : null; }
  catch (_) { return null; }
}

function samePricePropertyIdentity(candidateURL, expectedURL, provider) {
  if (!providerRoomHostAllowed(candidateURL, provider)) return false;
  if (provider === 'Expedia') return sameProviderPropertyIdentity(candidateURL, expectedURL, provider);
  const bookingSlug = url => {
    const match = String(url?.pathname || '').match(/\/hotel\/[^/]+\/([^/?#]+?)(?:\.html)?\/?$/i);
    return match ? match[1].replace(/\.html$/i, '').toLowerCase() : null;
  };
  const expected = bookingSlug(expectedURL);
  const actual = bookingSlug(candidateURL);
  return !expected || !actual || expected === actual;
}

async function runHotelCatalogMaintenance(env) {
  const task = await env.HOTELS_DB.prepare(`
    SELECT id, status, cutoff_at, attempt_count
    FROM catalog_maintenance_tasks
    WHERE status IN ('pending','failed')
      AND (next_retry_at IS NULL OR next_retry_at <= ?)
    ORDER BY created_at ASC
    LIMIT 1
  `).bind(new Date().toISOString()).first().catch(() => null);
  if (!task?.id) return { ok: true, task: null };

  const now = new Date().toISOString();
  await env.HOTELS_DB.prepare(`
    UPDATE catalog_maintenance_tasks
    SET status='running', attempt_count=attempt_count+1, started_at=COALESCE(started_at, ?), updated_at=?, error=NULL
    WHERE id=?
  `).bind(now, now, task.id).run();

  try {
    let deletedObjects = 0;
    if (task.id === 'reset-hotel-media-clean-start-v1') {
      deletedObjects = await purgeHotelMediaBefore(env, task.cutoff_at || now);
    }
    const completedAt = new Date().toISOString();
    await env.HOTELS_DB.prepare(`
      UPDATE catalog_maintenance_tasks
      SET status='completed', deleted_objects=?, completed_at=?, updated_at=?, next_retry_at=NULL, error=NULL
      WHERE id=?
    `).bind(deletedObjects, completedAt, completedAt, task.id).run();
    console.log('HOTEL_CATALOG_MAINTENANCE_COMPLETED', { taskID: task.id, deletedObjects });
    return { ok: true, task: task.id, deletedObjects };
  } catch (error) {
    const failedAt = new Date().toISOString();
    await env.HOTELS_DB.prepare(`
      UPDATE catalog_maintenance_tasks
      SET status='failed', next_retry_at=?, error=?, updated_at=?
      WHERE id=?
    `).bind(
      new Date(Date.now() + 60 * 60 * 1000).toISOString(),
      cleanText(String(error?.message || error), 900),
      failedAt,
      task.id
    ).run();
    throw error;
  }
}

async function purgeHotelMediaBefore(env, cutoffISO) {
  const cutoffMs = Date.parse(cutoffISO);
  const effectiveCutoff = Number.isFinite(cutoffMs) ? cutoffMs : Date.now();
  let cursor = undefined;
  let deleted = 0;
  let pages = 0;
  do {
    const listing = await env.HOTELS_MEDIA.list({ prefix: 'hotels/', limit: 1000, cursor });
    const keys = (listing.objects || [])
      .filter(object => {
        const uploaded = object?.uploaded instanceof Date ? object.uploaded.getTime() : Date.parse(object?.uploaded || '');
        return !Number.isFinite(uploaded) || uploaded <= effectiveCutoff;
      })
      .map(object => object.key)
      .filter(Boolean);
    for (let start = 0; start < keys.length; start += 100) {
      const chunk = keys.slice(start, start + 100);
      if (chunk.length) await env.HOTELS_MEDIA.delete(chunk);
      deleted += chunk.length;
    }
    cursor = listing.truncated ? listing.cursor : undefined;
    pages += 1;
    if (pages > 500) throw new Error('HOTEL_MEDIA_PURGE_PAGE_LIMIT');
  } while (cursor);
  return deleted;
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
  const expectedPropertyID = providerPropertyIDFromURL(finalParsed, provider)
    || providerPropertyIDFromURL(input, provider);
  if (provider === 'Expedia' && !expectedPropertyID) {
    return json({ ok: false, error: 'SOURCE_PROPERTY_ID_MISSING', detail: 'Resolved Expedia URL has no stable .h<propertyID> identity.' }, 422);
  }

  const html = await response.text();
  if (!html || html.length < 500) return json({ ok: false, error: 'SOURCE_ROOM_EMPTY_PAGE' }, 502);
  if (html.length > 8_000_000) return json({ ok: false, error: 'SOURCE_ROOM_PAGE_TOO_LARGE' }, 502);
  if (isProviderChallengeHTML(html)) {
    return json({ ok: false, error: 'SOURCE_PROVIDER_CHALLENGE', detail: 'Provider returned an anti-bot verification page instead of the hotel property.' }, 409);
  }

  let rooms = extractProviderRoomsFromHTML(html, provider, expectedPropertyID);
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
        if (!sameProviderPropertyIdentity(fallbackFinal, finalParsed, provider)) continue;
        const fallbackHTML = await fallbackResponse.text();
        if (!fallbackHTML || fallbackHTML.length > 8_000_000) continue;
        const recovered = extractProviderRoomsFromHTML(fallbackHTML, provider, expectedPropertyID);
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
    method,
    propertyID: expectedPropertyID || null
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

function providerPropertyIDFromURL(url, provider) {
  if (provider !== 'Expedia') return null;
  try {
    const explicit = url.searchParams.get('expediaPropertyId') || url.searchParams.get('propertyId');
    if (explicit && /^[0-9]{4,}$/.test(explicit)) return explicit;
    const match = String(url.pathname || '').match(/\.h([0-9]{4,})\.Hotel-Information/i);
    return match ? match[1] : null;
  } catch (_) {
    return null;
  }
}

function sameProviderPropertyIdentity(candidateURL, expectedURL, provider) {
  if (!providerRoomHostAllowed(candidateURL, provider)) return false;
  if (provider !== 'Expedia') return true;
  const expected = providerPropertyIDFromURL(expectedURL, provider);
  const actual = providerPropertyIDFromURL(candidateURL, provider);
  return !!expected && actual === expected;
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

function extractProviderRoomsFromHTML(html, provider, expectedPropertyID = null) {
  const visible = htmlToReadableText(html);
  const roomStart = visible.search(/\b(?:room options|rooms and rates|available rooms|choose your room|room types)\b/i);
  let roomText = roomStart >= 0 ? visible.slice(roomStart, roomStart + 180_000) : visible;
  const end = roomText.slice(800).search(/\b(?:about this property|property amenities|location|policies|reviews|getting around|you may also like|similar properties|recommended)\b/i);
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
  // Expedia SSR/app-state contains other properties on the same HTML document. Do not
  // accept unscoped room-name JSON; the visible Room options/action labels are the safe
  // property-specific source. Booking keeps the legacy structured fallback.
  if (provider !== 'Expedia') {
    for (const pattern of rawJSONPatterns) {
      let match;
      while ((match = pattern.exec(html)) !== null && rawJSONAnchors.length < 300) {
        rawJSONAnchors.push({ name: cleanRoomAnchor(decodeHTMLEntities(match[1])), index: -1, source: 'json' });
      }
    }
  }

  // SSR room cards frequently expose the room name only through aria-label/title
  // attributes. htmlToReadableText intentionally removes tags, so capture those
  // attributes directly before the markup is stripped. Expedia appends cross-sell
  // properties after the current property's room section, so never scan those cards.
  const recommendationBoundary = provider === 'Expedia'
    ? String(html || '').search(/(?:You may also like|Similar properties|Recommended properties)/i)
    : -1;
  const propertyScopedHTML = recommendationBoundary >= 0 ? String(html || '').slice(0, recommendationBoundary) : String(html || '');
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
    while ((match = pattern.exec(propertyScopedHTML)) !== null && rawJSONAnchors.length < 420) {
      rawJSONAnchors.push({ name: cleanRoomAnchor(decodeHTMLEntities(match[1])), index: -1, source: 'attribute' });
    }
  }

  // Expedia application state is often JSON-escaped inside another script string.
  // Normalize only quoting/unicode escapes and then reuse the strict room-name keys.
  const normalizedStructuredHTML = String(html || '')
    .replace(/\\u([0-9a-f]{4})/gi, (_, hex) => String.fromCharCode(parseInt(hex, 16)))
    .replace(/\\"/g, '"');
  if (provider !== 'Expedia' && normalizedStructuredHTML !== html) {
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

    await step.do('ensure hotel price', { retries: { limit: 1, delay: '4 seconds' }, timeout: '55 seconds' }, async () => {
      const cached = await this.env.HOTELS_DB.prepare(`
        SELECT nightly_price_usd, status, expires_at
        FROM hotel_price_cache WHERE hotel_id=? LIMIT 1
      `).bind(hotelID).first();
      const nowISO = new Date().toISOString();
      const fresh = cached?.nightly_price_usd != null && cached.status === 'fresh' && cached.expires_at && cached.expires_at > nowISO;
      if (fresh) return { ok: true, source: 'importer-cache' };
      return refreshHotelPrice(this.env, hotelID, { reason: 'import-finalize' });
    });

    const finalState = await step.do('finalize hotel import', async () => {
      const now = new Date().toISOString();
      const [roomRow, coverRow, priceRow] = await Promise.all([
        this.env.HOTELS_DB.prepare('SELECT COUNT(*) AS count FROM hotel_rooms WHERE hotel_id=?').bind(hotelID).first(),
        this.env.HOTELS_DB.prepare('SELECT COUNT(*) AS count FROM hotel_images WHERE hotel_id=? AND is_cover=1').bind(hotelID).first(),
        this.env.HOTELS_DB.prepare('SELECT nightly_price_usd, status, expires_at FROM hotel_price_cache WHERE hotel_id=? LIMIT 1').bind(hotelID).first()
      ]);
      const roomCount = Number(roomRow?.count || 0);
      const coverCount = Number(coverRow?.count || 0);
      const requiredImages = Math.min(4, total);
      const mediaReady = total > 0 && stored >= requiredImages && coverCount > 0;
      const roomsReady = !publishWhenComplete || roomCount > 0;
      const priceReady = !publishWhenComplete || (priceRow?.nightly_price_usd != null && priceRow.status === 'fresh' && priceRow.expires_at && priceRow.expires_at > now);
      const completed = mediaReady && roomsReady && priceReady;
      const withWarnings = completed && failed > 0;
      const warning = withWarnings ? `${failed} из ${total} фотографий недоступны у источника; сохранено ${stored}.` : null;
      let failureReason = null;
      if (!mediaReady) failureReason = `Сохранено только ${stored} из ${total} фотографий; для готовой карточки требуется минимум ${requiredImages} и обложка.`;
      else if (!roomsReady) failureReason = 'Не найдено ни одного подтверждённого типа номера; публикация остановлена.';
      else if (!priceReady) failureReason = 'Не удалось подтвердить актуальную цену отеля; карточка недоступна генератору и не опубликована.';

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
      return { completed, stored, failed, total, hotelID, roomCount, coverCount, priceReady, warning };
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
      ) AS cover_image_id,
      hp.provider AS price_provider,
      hp.source_url AS price_source_url,
      hp.resolved_url AS price_resolved_url,
      hp.amount_original AS price_amount_original,
      hp.currency_original AS price_currency_original,
      hp.price_basis AS price_basis,
      hp.nightly_price_usd AS price_nightly_usd,
      hp.quote_total_usd AS price_quote_total_usd,
      hp.quote_check_in AS price_quote_check_in,
      hp.quote_check_out AS price_quote_check_out,
      hp.quote_nights AS price_quote_nights,
      hp.quote_adults AS price_quote_adults,
      hp.quote_rooms AS price_quote_rooms,
      hp.confidence AS price_confidence,
      hp.method AS price_method,
      hp.status AS price_status,
      hp.fetched_at AS price_fetched_at,
      hp.expires_at AS price_expires_at,
      hp.last_attempt_at AS price_last_attempt_at,
      hp.next_retry_at AS price_next_retry_at,
      hp.error AS price_error
    FROM hotels h
    LEFT JOIN hotel_price_cache hp ON hp.hotel_id=h.id
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
    price: hotelPriceRow(row),
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
    'access-control-allow-methods': 'GET,POST,PUT,PATCH,DELETE,OPTIONS',
    'access-control-allow-headers': 'Content-Type,Authorization,Idempotency-Key,X-Iumrah-Business-Session,X-Iumrah-Allow-Possible-Duplicate,X-Iumrah-Source,X-Iumrah-Position,X-Iumrah-Cover,X-Iumrah-Category,X-Iumrah-Source-URL,X-Iumrah-Label,X-Iumrah-Room',
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
