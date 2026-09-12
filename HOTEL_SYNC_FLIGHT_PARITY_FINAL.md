# Hotel Sync — Flight Sync parity final

This cumulative patch replaces the prior HTML/route/keychain experiments.

- Public Hotel Sync uses the same transport as Flight Sync: pretty JSON over `text/plain; charset=utf-8`, `no-store`.
- The sync button always rotates a fresh server access token, saves the current hotel snapshot, then copies that exact URL.
- No cached Keychain URL is reused when Sync is tapped.
- No dedicated Cloudflare `hotel-sync/*` route or HTML reader is used.
- Hotel-specific provider URLs are normalized to the exact property path plus the selected dates/occupancy, so stale Expedia/Booking tracking parameters cannot override the snapshot dates.
- Flight Sync code is unchanged.
