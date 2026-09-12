# iumrah Business — Hotel ChatGPT Sync

Hotel Sync keeps the proven Flight Sync security model (durable revocable read-only token + server-side snapshot), but uses a different reader surface because hotel monitoring must follow exact provider property links.

## Source of truth

The public ChatGPT feed is **not rebuilt from the hotel database**. When the operator taps sync, the iOS app serializes the hotel rows already loaded in `HotelsView` and uploads that read-only snapshot to the relay. Cloudflare stores and serves the snapshot only so the secret URL can be read outside the iPhone app.

Makkah and Madinah have separate durable links and separate snapshots.

## Why Hotel Sync cannot use the Flight Sync `text/plain` surface

Flight Sync only needs ChatGPT to read the current flight catalogue; ChatGPT can then search the web independently by route, date and flight number.

Hotel Sync is different: the exact Expedia/Booking property URL is part of the verification boundary and ChatGPT must be able to navigate from the sync feed to that URL. A URL embedded only as a JSON string is not a reliable navigable link for external ChatGPT/browser readers.

Therefore the durable Hotel Sync URL now serves a small no-cache HTML reader page by default:

- every hotel has a real clickable `monitoring_url` anchor;
- the complete snapshot/result template is still embedded visibly as machine-readable JSON text;
- the same URL with `?format=json` returns the raw JSON document;
- both formats remain read-only and `noindex`.

## Clean exact-property monitoring URLs

Imported Expedia/Booking share URLs can contain tracking and deep-link parameters that preserve old dates. Appending new dates on top of those values creates competing stay contexts.

Hotel Sync now constructs a clean browser URL from only the verified provider origin + property pathname, then applies the snapshot context:

- Expedia: `chkin`, `chkout`, `rm1=a2`, `currency=USD`, `useRewards=false`;
- Booking: `checkin`, `checkout`, `group_adults=2`, `group_children=0`, `no_rooms=1`, `room1=A,A`, `selected_currency=USD`.

The immutable stored `source_url` remains in the snapshot for provenance and property validation. Only the derived `monitoring_url` is cleaned.

## Price-check contract

Before syncing a city, the operator chooses one check-in date. The snapshot fixes:

- check-in and next-day check-out;
- one night;
- one room;
- two adults;
- zero children;
- USD comparison currency.

ChatGPT follows each clickable provider link and checks the same property for the exact snapshot dates. Search may only recover the same provider/property when the exact page cannot be read. Search-result/snippet prices are never accepted as verified evidence.

If the exact property, exact dates, occupancy and sellable nightly price cannot be verified, the result must be `unverified`.

## Read-only link

The link is durable like Flight Sync. Pressing **Синхронизировать и скопировать** replaces only the city snapshot behind the same secret link. Rotating/revoking the link is explicit.

Default reader headers:

- `Content-Type: text/html; charset=utf-8`;
- `X-Content-Type-Options: nosniff`;
- `Cache-Control: no-store, max-age=0`;
- `X-Robots-Tag: noindex`.

Raw JSON (`?format=json`) uses `application/json; charset=utf-8` with the same no-cache/noindex policy.

The token is stored server-side only as SHA-256.

## Result

ChatGPT returns `iumrah.hotel-price-update.v2`. The operator pastes it into iumrah Business. Preview validates snapshot ID, hotel ID, old price, provider/property identity, exact dates, occupancy, checked provider URL and high confidence. Nothing is written during preview.

Only rows selected by the operator are batch-applied. The backend repeats the same safety checks against the saved snapshot and the current hotel price/source before writing.

## Upgrade behavior

Existing durable Hotel Sync tokens remain valid. No D1 migration and no token rotation are required for this reader fix. After deploying the Worker, an existing copied Hotel Sync URL automatically renders the new clickable reader on the next request. A fresh **Синхронизировать и скопировать** is still recommended so the snapshot receives newly cleaned `monitoring_url` values.

## Scope

This implementation does not modify Flight Sync or the Hotel Importer. Existing importer flows for adding hotels remain unchanged.
