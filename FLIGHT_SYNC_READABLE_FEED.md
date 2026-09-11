# iumrah Business — readable ChatGPT Flight Sync feed

This update keeps the existing Flight Sync URL and token unchanged.

## What changes

The public read-only Flight Sync endpoint now returns the same JSON payload as pretty-printed UTF-8 `text/plain` instead of minified `application/json`.

This is intentional: external readers that suppress API JSON bodies can read the feed as normal text, while the body remains valid JSON.

The feed still includes:

- `flight_count`
- `updated_at`
- full `flights` array
- route/date/airline/flight number/current price data already present in the snapshot

No write capability is added. The token remains read-only and can still be revoked from iumrah Business.

## Deployment

Backend only. No TestFlight rebuild is required for this update.

1. Apply this ZIP on top of the current repository.
2. Wait for the ZIP apply workflow to finish successfully.
3. Run `Deploy iumrah Hotels Cloud` once.
4. Keep using the same Flight Sync URL already shown in the app.

No new D1 migration is required.
