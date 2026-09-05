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

## Exact-source hotel prices

Hotel pricing has one source of truth: the exact Booking/Expedia URL that was imported for that hotel. Migration `0024_exact_hotel_price_source.sql` locks one immutable source URL per hotel in `hotel_price_sources`.

- Import price: captured only from the exact source page already open in the verified iOS WKWebView. Room recovery never contributes a price.
- Refresh: the Worker re-opens that same locked URL exactly as stored. It does not search by hotel name, add/replace dates, switch provider, canonicalize to another host, or probe alternate pages.
- Rendering: refresh uses Cloudflare Browser Run only for that exact URL so JavaScript-rendered provider prices can be read. There is no static-HTML price fallback.
- Successful price: cached for 48 hours.
- Failed refresh: the last accepted price is preserved as `stale` and retried after 6 hours.
- Large price moves are staged and require a second matching read from the same exact source URL before replacement.
- Cron: hourly at minute 17; only due hotels with a locked exact source URL are refreshed.
- `POST /api/admin/hotels/:id/price/refresh` performs the same exact-source refresh on demand.
- Business hotel cards receive the locked source URL and expose an `Open Expedia/Booking` action so staff can verify the exact page used by refresh.

Migration `0021_reset_hotel_catalog_clean_start.sql` is an intentional one-time destructive clean start: it deletes canonical hotel rows and cascaded catalog data. Old `hotels/` R2 media is queued for cleanup with a cutoff timestamp so media uploaded after the reset is protected.
