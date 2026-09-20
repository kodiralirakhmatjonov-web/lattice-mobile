# Hotel Sync Permanent Live Feed V4

## Goal

Hotel Sync links are permanent bearer URLs. A link is created once per city and remains valid with unlimited reads until an iumrah Business operator explicitly disables it.

## Live-feed contract

- No token TTL.
- No automatic token rotation.
- No read/open limit.
- No hotel snapshot cache is used by the public reader.
- `GET /api/catalog/hotels/hotel-sync/{city}/{token}` reads the current D1 hotel catalog on every request.
- `current_nightly_usd`, provider/source identity, hotel status, and hotel membership are rebuilt from live D1 on every request.
- `Cache-Control: no-store` plus `Pragma: no-cache` prevents an intermediary response from becoming the source of truth.
- Existing/legacy Hotel Sync URLs remain valid after deployment.
- `DELETE .../hotel-sync/{city}/access` is the only normal action that disables the URL.

## Snapshot compatibility

`snapshot_id` remains in `iumrah.hotel-price-update.v2` for backward compatibility, audit, and configuration history only. It is not an expiry mechanism and is not a global apply lock.

Price application remains protected per hotel by live compare-and-set:

1. hotel ID still exists;
2. city is unchanged;
3. exact provider/property identity is still valid;
4. live current price still equals `old_nightly_usd`.

A newer `snapshot_id` never invalidates an otherwise safe result.

## Monitoring dates

The app now uploads only the preferred check-in/check-out settings, not a hotel snapshot. The public URL keeps the same token. If a stored monitoring date is already in the past, the server automatically rolls the feed to a one-night stay 20 days ahead.

## Deployment

No D1 migration is required.

1. Apply the root patch ZIP.
2. Run **Deploy iumrah Hotels Cloud** so the existing live URLs start serving database-backed feeds.
3. Build iumrah Business/TestFlight only if the updated Hotel Sync UI is needed on the phone.

The backend deployment alone is enough to make already-issued Hotel Sync URLs permanent live feeds.
