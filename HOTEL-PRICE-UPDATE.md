# iumrah Business — JSON Price Exchange v2

## Active price-update architecture

Hotel price monitoring no longer runs through Cloudflare Browser Rendering or the old ChatGPT access-link bridge.

The active workflow is deliberately explicit and admin-controlled:

1. iumrah Business exports the full **Makkah** or **Madinah** hotel database slice as JSON.
2. The JSON is uploaded to ChatGPT.
3. ChatGPT checks the exact hotels/sources with one consistent monitoring policy and returns `iumrah.hotel-price-update.v1` JSON.
4. iumrah Business imports that result and performs a server-side preview.
5. Only selected, verified changes are written to D1 after the admin taps **Update selected prices**.

The hotel importer remains unchanged for adding new hotels. Initial imported/manual pricing is still supported. The old per-hotel **Update from source** UI is retired; ongoing catalog price updates use JSON exchange.

## Export schema

`iumrah.hotel-monitor.v1`

Each exported hotel contains:

- stable `hotelID`
- hotel name, city, stars
- current effective nightly USD price
- whether the current value is a manual override
- provider
- exact stored source URL
- last stored price timestamp

The monitoring policy in the document tells ChatGPT to use the same method for every hotel and prefer future samples around +20 / +25 / +30 days when a provider needs dates.

## Return schema

`iumrah.hotel-price-update.v1`

Each result item preserves `hotelID`, old price, provider and source URL, and returns:

- `status`: `changed`, `unchanged`, or `unverified`
- `newNightlyUSD`
- `confidence`: `high`, `medium`, `low`, or `none`
- optional checked URL / reason / timestamp

## Safety before D1 write

The Worker validates the result again at preview and again immediately before applying it:

- hotel still exists in the selected city
- city still matches the export
- source URL still points to the same stored hotel page
- current D1 price is still equal to the exported old price
- new price is valid USD nightly data
- low-confidence / unverified data is not selectable

If a price or source changed after export, the item becomes a conflict and cannot be silently overwritten.

When an approved JSON price is applied, any old manual override for that hotel is removed so the newly approved price becomes the effective catalog/generator price.

## Retired runtime pieces

The active Worker no longer routes or schedules:

- `/api/iumrah/chatgpt/*`
- `/api/admin/hotels/price-monitor`
- `/api/admin/hotels/chatgpt-links`
- Cloudflare price-monitor Workflows
- scheduled automatic hotel price maintenance

The historical migration/table files remain in the repository because already-applied D1 migrations must not be deleted or rewritten.
