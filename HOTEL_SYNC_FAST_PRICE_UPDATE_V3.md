# Hotel Sync Fast Price Update V3

This update fixes the stale-link / stale-snapshot state visible on the Hotel Sync screen and hardens daily hotel-price synchronization.

## What was wrong

The screen could combine the *current* app catalog/date with an *old* Hotel Sync status/link. Hotel Sync also rotated the public token before every refresh. If snapshot creation then failed, the previous public URL could be invalidated while the UI still displayed old state. The backup JSON was fetched by asking the iOS app to call its own public token URL, so a public-route/CDN fetch problem could make the app show "JSON body failed" even when the authenticated snapshot existed.

A newly added hotel without an exact Expedia/Booking property link could also reject the whole city snapshot instead of simply being left unverified.

## V3 behavior

- The read-only Hotel Sync URL is created once and remains stable, matching the proven Flight Sync workflow.
- Daily/2-day refreshes only replace the snapshot behind that stable link; the token is not rotated on every refresh.
- The UI distinguishes `Hotel Sync актуален` from `Предыдущая синхронизация` using selected date + current hotel count.
- Copy link / copy JSON are disabled while the shown snapshot is stale, preventing accidental use of an old feed.
- Backup JSON is loaded through a new authenticated admin route:
  - `GET /api/admin/hotels/operations/hotel-sync/{city}/body`
- The public ChatGPT URL remains read-only and unchanged.
- A failed first-time setup cleans up its half-created access token. A failed normal daily refresh never revokes the existing good link.
- Hotels without a monitorable Expedia/Booking property no longer break the whole city sync. They remain in the feed with:
  - `monitoring_status: "unverified_source"`
  - `provider: null`
  - `source_url: null`
  - `monitoring_url: null`
  ChatGPT must mark those hotels unverified rather than substituting another property.
- Includes V1 live per-hotel compare-and-set / nearby-date policy and V2 blank-screen scroll reset.

## Verification

- Backend test suite: 127 / 127 passing.
- `node --check` passes for HotelsWorker.
- `swiftc -parse` passes for the changed Hotel Sync Swift files.
- No D1 migration is required.

## Deployment

1. Put this ZIP in the repository root and let the existing Apply ZIP workflow merge it.
2. Run `Deploy iumrah Hotels Cloud` because V3 adds/changes backend Hotel Sync behavior.
3. Build a new iOS/TestFlight version because the Hotel Sync UI/client behavior also changed.
