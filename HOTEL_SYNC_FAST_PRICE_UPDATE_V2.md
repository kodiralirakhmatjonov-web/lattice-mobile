# Hotel Sync Fast Price Update V2

## Fix in this update

After a successful price apply, Hotel Sync removed the tall preview/result list while SwiftUI could keep the previous deep ScrollView offset. The content became shorter but the viewport remained below it, producing an apparently blank white screen.

The screen now uses `ScrollViewReader` with a stable top anchor. After a successful apply and state reset, it explicitly scrolls back to the Hotel Sync top.

## Preserved V1 behavior

- `snapshot_id` is audit/history only and does not globally invalidate updates.
- Updates are protected per hotel using live hotel ID, provider/property identity and `old_nightly_usd` compare-and-set.
- Nearby directly verified stay dates are allowed by the feed policy.
- Booking localized URL variants normalize to the same property identity.
- Provider query/affiliate URL changes do not create false snapshot conflicts.

## Validation

- `swiftc -parse Sources/Views/HotelPriceMonitoringView.swift`
- HotelsWorker Node test suite: 126/126 passing, including a regression test for the blank-screen scroll reset.
