# iumrah Hotels Cloud

Central hotel catalog backend for iumrah.

## Architecture

- **Cloudflare D1** database: `iumrah-hotels`
- **Cloudflare R2** bucket: `iumrah-hotels-media`
- **Worker**: `iumrah-hotels-api`
- Admin route: `https://iumrah.app/api/admin/hotels*`
- Public catalog route: `https://iumrah.app/api/catalog/hotels*`

The Worker runs only on the hotel routes. Existing `iumrah.app` auth remains the source of truth: admin requests are validated by forwarding the existing session cookie to `/api/auth/staff/session`.

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
