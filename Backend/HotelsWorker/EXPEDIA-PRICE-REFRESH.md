# Expedia hotel price refresh v2

## Contract

The price engine is **hotel-bound, not room-bound**. The imported Expedia property URL (the `.h<propertyID>.Hotel-Information` identity) is the anchor. The Worker never searches Expedia by hotel name and never accepts a different property. For the catalogue benchmark it requests **1 room / 2 adults / USD** and may use any sellable room belonging to that exact property.

A successful refresh has a strict API meaning:

```json
{
  "ok": true,
  "refreshed": true,
  "changed": true,
  "price": {},
  "error": null
}
```

`ok/refreshed=true` is returned only after a live provider snapshot has been persisted in D1 during that request. A stale fallback can still be returned to keep package generation working, but the response is `ok:false, refreshed:false` and the Business UI shows a warning rather than a false success.

## Refresh pipeline

1. `hotel_price_sources` prefers an imported Expedia source when one exists.
2. Opaque Expedia share links are provenance only. The importer-saved canonical property URL is used for pricing.
3. The property ID is extracted before any request and checked again after navigation. A different `.h<ID>` is rejected.
4. The Worker normalizes occupancy to 2 adults / 1 room and requests USD (`currency=USD` and `top_cur=USD`).
5. Expedia availability is probed on a bounded future ladder (valid imported dates first, then +1, +3, +7, +14, +21, +30 days). This solves the “tomorrow is sold out” failure without changing hotels.
6. Cheap HTML/SSR extraction runs for the full ladder first. Expedia property/FAQ nightly text is accepted when it is clearly property-specific.
7. If SSR has no usable price, one Cloudflare Browser Rendering session is opened and up to four same-property dates are tried inside that single browser session.
8. Browser extraction reads visible Expedia room price cards, excludes recommendations/cross-sell blocks, and accepts the lowest sellable rate among equally strong room-card candidates. It does not require a Double Room name.
9. A successful quote is written as `fresh` for 48 hours. A failure keeps the last accepted rate as `stale` and schedules a retry after 6 hours.
10. A D1 lease prevents two requests from refreshing the same hotel at the same time.

## Scheduling

The existing Worker cron runs every 15 minutes. Each pass refreshes up to four due hotels, preferring Expedia and hotels with no accepted rate. A successful price expires after 48 hours, so each hotel becomes due at least every two days. Migration `0034_expedia_price_refresh_v2.sql` switches eligible locks to Expedia and makes existing Expedia rows due immediately after deployment.

## Admin button semantics

“Обновить из источника” uses the same server path as the cron but bypasses waiting for the next scheduled run. The UI only says **“Цена обновилась”** when the newly persisted source rate differs from the previous accepted source rate. If the live read succeeds with the same amount it says that Expedia was checked and the price did not change. If Expedia cannot confirm a price, the last working price remains visible with an orange warning.

## Safety rules

- Never search by hotel name during price refresh.
- Never switch to another Expedia property ID.
- Never treat recommendation/cross-sell prices as the hotel price.
- Never clear the last accepted rate on source failure.
- Never report a stale fallback as a successful refresh.
- Large price jumps still require two matching live reads before replacing the accepted rate.
