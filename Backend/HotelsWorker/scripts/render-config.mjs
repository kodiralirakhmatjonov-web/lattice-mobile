import fs from 'node:fs';

const [databaseId, zoneId] = process.argv.slice(2);
if (!databaseId || !zoneId) {
  console.error('Usage: node scripts/render-config.mjs <D1_DATABASE_ID> <ZONE_ID>');
  process.exit(1);
}

const template = fs.readFileSync(new URL('../wrangler.template.jsonc', import.meta.url), 'utf8');
const rendered = template
  .replaceAll('__D1_DATABASE_ID__', databaseId)
  .replaceAll('__ZONE_ID__', zoneId);

fs.writeFileSync(new URL('../wrangler.generated.jsonc', import.meta.url), rendered);
console.log('Generated wrangler.generated.jsonc');
