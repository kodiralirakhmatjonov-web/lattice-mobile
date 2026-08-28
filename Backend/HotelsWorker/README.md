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
