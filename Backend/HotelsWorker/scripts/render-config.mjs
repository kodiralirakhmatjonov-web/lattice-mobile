import fs from 'node:fs';

const [hotelDatabaseID, zoneID] = process.argv.slice(2);
const accountID = process.env.CLOUDFLARE_ACCOUNT_ID;
const apiToken = process.env.CLOUDFLARE_API_TOKEN;

if (!hotelDatabaseID || !zoneID || !accountID || !apiToken) {
  console.error('Usage: node scripts/render-config.mjs <HOTEL_D1_DATABASE_ID> <ZONE_ID> with CLOUDFLARE_ACCOUNT_ID and CLOUDFLARE_API_TOKEN');
  process.exit(1);
}

const headers = {
  Authorization: `Bearer ${apiToken}`,
  'Content-Type': 'application/json',
};

async function d1Query(databaseID, sql, params = []) {
  const response = await fetch(
    `https://api.cloudflare.com/client/v4/accounts/${accountID}/d1/database/${databaseID}/query`,
    {
      method: 'POST',
      headers,
      body: JSON.stringify({ sql, params }),
    },
  );
  if (!response.ok) throw new Error(`D1 query failed for ${databaseID} (${response.status})`);
  const payload = await response.json();
  if (payload?.success === false) throw new Error(`D1 query rejected for ${databaseID}`);
  return payload?.result?.[0]?.results ?? [];
}

async function operationalBookingIDs() {
  try {
    const rows = await d1Query(
      hotelDatabaseID,
      `SELECT booking_id
       FROM pilgrim_trips
       WHERE booking_id IS NOT NULL AND booking_id <> ''
       ORDER BY COALESCE(updated_at, created_at) DESC
       LIMIT 25`,
    );
    return [...new Set(rows.map(row => String(row?.booking_id || '').trim()).filter(Boolean))];
  } catch (error) {
    console.warn(`Could not read operational booking IDs from HOTELS_DB: ${error?.message || error}`);
    return [];
  }
}

async function findBookingDatabase() {
  const listResponse = await fetch(
    `https://api.cloudflare.com/client/v4/accounts/${accountID}/d1/database?per_page=100`,
    { headers },
  );
  if (!listResponse.ok) throw new Error(`Unable to list D1 databases (${listResponse.status})`);
  const listPayload = await listResponse.json();
  const databases = Array.isArray(listPayload.result) ? listPayload.result : [];
  const knownBookingIDs = await operationalBookingIDs();
  const candidates = [];

  for (const database of databases) {
    const id = database.uuid ?? database.id;
    if (!id || String(id) === String(hotelDatabaseID)) continue;
    try {
      const rows = await d1Query(
        id,
        `SELECT
           (SELECT COUNT(*) FROM bookings) AS booking_count,
           (SELECT MAX(COALESCE(updated_at, created_at, '')) FROM bookings) AS newest_booking,
           (SELECT COUNT(*) FROM pragma_table_info('bookings') WHERE name IN ('id','access_token_hash','payload_json','status')) AS required_columns`,
      );
      const row = rows[0];
      if (!row || Number(row.required_columns ?? 0) !== 4) continue;

      let overlapCount = 0;
      if (knownBookingIDs.length) {
        const placeholders = knownBookingIDs.map(() => '?').join(',');
        const overlapRows = await d1Query(
          id,
          `SELECT COUNT(*) AS overlap_count FROM bookings WHERE id IN (${placeholders})`,
          knownBookingIDs,
        );
        overlapCount = Number(overlapRows?.[0]?.overlap_count ?? 0);
      }

      candidates.push({
        id: String(id),
        name: String(database.name ?? 'iumrah-bookings'),
        bookingCount: Number(row.booking_count ?? 0),
        newestBooking: String(row.newest_booking ?? ''),
        overlapCount,
      });
    } catch {
      // Not the live bookings database. Keep scanning.
    }
  }

  if (!candidates.length) {
    throw new Error('No existing D1 database with the production bookings schema (id/access_token_hash/payload_json/status) was found.');
  }

  candidates.sort((a, b) => {
    if (knownBookingIDs.length && b.overlapCount !== a.overlapCount) return b.overlapCount - a.overlapCount;
    const byNewest = b.newestBooking.localeCompare(a.newestBooking);
    if (byNewest !== 0) return byNewest;
    return b.bookingCount - a.bookingCount;
  });

  const selected = candidates[0];
  if (knownBookingIDs.length && selected.overlapCount === 0) {
    throw new Error(`No bookings D1 overlaps the ${knownBookingIDs.length} operational booking IDs already stored in iumrah-hotels. Refusing to bind an unrelated database.`);
  }

  console.log(`Operational booking IDs used for D1 verification: ${knownBookingIDs.length}`);
  console.log('Bookings D1 candidates:', candidates.map(item => `${item.name}:overlap=${item.overlapCount}:count=${item.bookingCount}:newest=${item.newestBooking}`).join(', '));
  console.log(`Using bookings D1: ${selected.name} (${selected.id})`);
  return selected;
}

async function normalizeBookingStatuses(databaseID) {
  const mappings = [
    ['NEW', 'AVAILABILITY_CHECK'],
    ['PAID', 'BOOKING_CONFIRMED'],
    ['DOCUMENTS_READY', 'READY_TO_TRAVEL'],
  ];

  const before = await d1Query(
    databaseID,
    `SELECT UPPER(COALESCE(status,'')) AS status, COUNT(*) AS count FROM bookings GROUP BY UPPER(COALESCE(status,'')) ORDER BY status`,
  );

  for (const [legacy, canonical] of mappings) {
    await d1Query(
      databaseID,
      `UPDATE bookings SET status=? WHERE UPPER(COALESCE(status,''))=?`,
      [canonical, legacy],
    );

    // Keep the immutable booking payload readable by older consumers while making
    // its embedded status agree with the canonical database status when present.
    try {
      await d1Query(
        databaseID,
        `UPDATE bookings
         SET payload_json=json_set(payload_json,'$.status',?)
         WHERE json_valid(payload_json)=1
           AND UPPER(COALESCE(json_extract(payload_json,'$.status'),''))=?`,
        [canonical, legacy],
      );
    } catch (error) {
      console.warn(`Could not normalize embedded payload status ${legacy}: ${error?.message || error}`);
    }
  }

  const after = await d1Query(
    databaseID,
    `SELECT UPPER(COALESCE(status,'')) AS status, COUNT(*) AS count FROM bookings GROUP BY UPPER(COALESCE(status,'')) ORDER BY status`,
  );
  const forbidden = new Set(['NEW', 'PAID', 'DOCUMENTS_READY']);
  const remaining = after.filter(row => forbidden.has(String(row?.status || '').toUpperCase()) && Number(row?.count || 0) > 0);
  if (remaining.length) {
    throw new Error(`Legacy booking statuses remain after normalization: ${JSON.stringify(remaining)}`);
  }
  console.log('Bookings status normalization:', { before, after });
}

const bookingDatabase = await findBookingDatabase();
await normalizeBookingStatuses(bookingDatabase.id);
const template = fs.readFileSync(new URL('../wrangler.template.jsonc', import.meta.url), 'utf8');
const rendered = template
  .replaceAll('__D1_DATABASE_ID__', hotelDatabaseID)
  .replaceAll('__BOOKING_D1_DATABASE_ID__', bookingDatabase.id)
  .replaceAll('__BOOKING_D1_DATABASE_NAME__', bookingDatabase.name.replaceAll('"', '\\"'))
  .replaceAll('__ZONE_ID__', zoneID);

JSON.parse(rendered);
fs.writeFileSync(new URL('../wrangler.generated.jsonc', import.meta.url), rendered);
console.log('Generated wrangler.generated.jsonc with HOTELS_DB + verified BOOKINGS_DB bindings');
