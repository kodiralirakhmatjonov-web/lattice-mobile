# iumrah Hotels Cloud

Central hotel catalog backend for iumrah.

## Architecture

- **Cloudflare D1** database: `iumrah-hotels`
- **Cloudflare R2** bucket: `iumrah-hotels-media`
- **Worker**: `iumrah-hotels-api`
- Admin route: `https://iumrah.app/api/admin/hotels*`
- Public catalog route: `https://iumrah.app/api/catalog/hotels*`

The Worker runs only on the hotel routes. Business staff authentication remains unchanged: admin requests are validated through the existing staff session endpoint. Client authentication is independent and lives in this Worker: a permanent six-digit **iumrah ID** plus password creates a server-side account session, and all trips belong to that canonical pilgrim identity.

## Data ownership

D1 is the master database for hotel metadata. R2 is the master storage for approved hotel media. iPhone storage is not the source of truth.

The future iumrah consumer app / package generator should read only published hotels from `/api/catalog/hotels` and then perform live-rate checks separately.

## One-time CI setup

Upload `deploy-hotels-cloud.yml` into `.github/workflows/` and add these repository secrets:

- `CLOUDFLARE_API_TOKEN`
- `CLOUDFLARE_ACCOUNT_ID`
- `CLOUDFLARE_ZONE_ID`

Recommended token permissions:

- Account: Workers Scripts Edit
- Account: D1 Edit
- Account: Workers R2 Storage Edit
- Zone `iumrah.app`: Workers Routes Edit

The deploy workflow creates D1/R2 if needed, applies migrations, deploys the Worker, and verifies the public health endpoint.

## Mobile account and checkout

The active mobile identity model is documented in `CLIENT_INTEGRATION.md`. Legacy device `clientUserID` identity is not part of the active architecture. D1 migration `0012_iumrah_accounts_checkout.sql` collapses legacy trip statuses, removes identity-keyed legacy tables/columns, and creates the iumrah account, traveler, payment, receipt and travel-document model.

## Cached hotel prices

Hotel catalog prices are refreshed independently from package generation. The original Booking/Expedia property URL remains in `hotel_sources`; `hotel_price_cache` stores one normalized benchmark quote per hotel.

- Benchmark: 2 adults, 1 room, 2 nights, first probe 14 days ahead (45-day fallback).
- Successful price: cached for 48 hours.
- Failed refresh: last known price is preserved as `stale` and retried after 6 hours.
- Cron: hourly at minute 17; only due hotels are fetched, up to 12 per run with concurrency 3.
- A completed hotel import also attempts one price refresh, but a price failure never fails the hotel import.
- The admin API exposes `POST /api/admin/hotels/:id/price/refresh` for an explicit retry.

Migration `0021_reset_hotel_catalog_clean_start.sql` is an intentional one-time destructive clean start: it deletes canonical hotel rows and cascaded catalog data. Old `hotels/` R2 media is queued for cleanup with a cutoff timestamp so media uploaded after the reset is protected.
