import fs from 'node:fs';

const [hotelDatabaseId, zoneId] = process.argv.slice(2);
const accountId = process.env.CLOUDFLARE_ACCOUNT_ID;
const apiToken = process.env.CLOUDFLARE_API_TOKEN;

if (!hotelDatabaseId || !zoneId || !accountId || !apiToken) {
  console.error('Usage: node scripts/render-config.mjs <HOTELS_D1_DATABASE_ID> <ZONE_ID> with CLOUDFLARE_ACCOUNT_ID and CLOUDFLARE_API_TOKEN');
  process.exit(1);
}

const headers = {
  Authorization: `Bearer ${apiToken}`,
  'Content-Type': 'application/json'
};

async function findBookingsDatabase() {
  const response = await fetch(`https://api.cloudflare.com/client/v4/accounts/${accountId}/d1/database?per_page=100`, { headers });
  if (!response.ok) throw new Error(`Unable to list D1 databases (${response.status})`);
  const payload = await response.json();
  const databases = Array.isArray(payload.result) ? payload.result : [];

  databases.sort((a, b) => (/iumrah/i.test(String(a?.name || '')) ? 0 : 1) - (/iumrah/i.test(String(b?.name || '')) ? 0 : 1));

  for (const database of databases) {
    const id = String(database?.uuid || database?.id || '');
    if (!id || id === hotelDatabaseId) continue;
    try {
      const query = await fetch(`https://api.cloudflare.com/client/v4/accounts/${accountId}/d1/database/${id}/query`, {
        method: 'POST',
        headers,
        body: JSON.stringify({ sql: "SELECT name FROM sqlite_master WHERE type='table' AND name='bookings' LIMIT 1" })
      });
      if (!query.ok) continue;
      const result = await query.json();
      const batches = Array.isArray(result.result) ? result.result : [];
      const found = batches.some(batch => Array.isArray(batch?.results) && batch.results.some(row => row?.name === 'bookings'));
      if (found) return { id, name: String(database?.name || 'iumrah-bookings') };
    } catch {
      // Keep scanning existing D1 databases; never create or guess a bookings DB.
    }
  }
  throw new Error('No existing D1 database containing the bookings table was found. Refusing to deploy with a guessed booking store.');
}

const bookings = await findBookingsDatabase();
console.log(`Using existing bookings D1: ${bookings.name} (${bookings.id})`);

const template = fs.readFileSync(new URL('../wrangler.template.jsonc', import.meta.url), 'utf8');
const rendered = template
  .replaceAll('__D1_DATABASE_ID__', hotelDatabaseId)
  .replaceAll('__BOOKINGS_D1_DATABASE_ID__', bookings.id)
  .replaceAll('__BOOKINGS_D1_DATABASE_NAME__', bookings.name.replaceAll('"', '\\"'))
  .replaceAll('__ZONE_ID__', zoneId);

JSON.parse(rendered);
fs.writeFileSync(new URL('../wrangler.generated.jsonc', import.meta.url), rendered);
console.log('Generated wrangler.generated.jsonc with HOTELS_DB + BOOKINGS_DB bindings');
