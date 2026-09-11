# iumrah Business — Hotel ChatGPT Sync

Hotel Sync deliberately follows the proven Flight Sync transport pattern.

## Source of truth

The public ChatGPT feed is **not rebuilt from the hotel database**. When the operator taps sync, the iOS app serializes the hotel rows that are already loaded in `HotelsView` and uploads that read-only snapshot to the relay. Cloudflare stores and serves the snapshot only so the secret URL can be read outside the iPhone app.

Makkah and Madinah have separate durable links and separate snapshots.

## Price-check contract

Before syncing a city, the operator chooses one check-in date. The snapshot fixes:

- check-in and next-day check-out;
- one night;
- one room;
- two adults;
- zero children;
- USD comparison currency.

Every hotel contains its exact stored Expedia/Booking property URL plus a `monitoring_url` with those dates applied. The primary monitoring method is to open `monitoring_url` for that exact property. Search may only be used to recover the same provider/property when the exact page cannot be read. A search-result/snippet price is never verification.

If the exact property, exact dates, occupancy and sellable nightly price cannot be verified, return `unverified`.

## Read-only link

The link is durable like Flight Sync. Pressing **Синхронизировать и скопировать** replaces only the city snapshot behind the same secret link. Rotating/revoking the link is explicit.

The public response uses the same external-reader contract as Flight Sync:

- valid pretty-printed JSON body;
- `Content-Type: text/plain; charset=utf-8`;
- `X-Content-Type-Options: nosniff`;
- `Cache-Control: no-store, max-age=0`.

The token is stored server-side only as SHA-256.

## Result

ChatGPT returns `iumrah.hotel-price-update.v2`. The operator pastes it into iumrah Business. Preview validates snapshot ID, hotel ID, old price, provider/property identity, exact dates, occupancy, checked provider URL and high confidence. Nothing is written during preview.

Only rows selected by the operator are batch-applied. The backend repeats the same safety checks against the saved snapshot and the current hotel price/source before writing.

## Upgrade from v4

v4 used a short-lived one-shot relay. The first sync after this upgrade checks whether the durable feed exists; if not, iumrah Business automatically rotates a new durable link once and replaces the stale Keychain URL. The operator does not need to diagnose or manually clear an old link.

## Scope

This implementation does not modify Flight Sync or the Hotel Importer. Existing importer flows for adding hotels remain unchanged.
