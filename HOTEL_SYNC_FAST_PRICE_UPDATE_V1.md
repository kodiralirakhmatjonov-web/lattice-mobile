# Hotel Sync Fast Price Update v1

Purpose: make hotel price maintenance fast enough to run every day or every 48 hours without a global snapshot conflict.

## New apply rule

`snapshot_id` stays in the feed and result for audit/history, but it no longer locks price application.

A changed hotel is accepted only when all of these are still true at apply time:

- the hotel exists and is published in the same city;
- `status=changed` and `confidence=high`;
- the live catalog price still equals `old_nightly_usd`;
- provider matches the live locked price source;
- `checked_source_url` resolves to the same Expedia/Booking property;
- the new USD nightly price is valid.

If the live price already changed, only that hotel is rejected with `HOTEL_SYNC_PRICE_ALREADY_CHANGED`. Other selected hotels can still update.

## Dates

The feed date remains the preferred monitoring date and stays in the result for audit. If the provider does not expose that exact date, a directly verified nearby stay date for the same property and occupancy may be used. The checked URL no longer has to contain the exact feed dates.

## Source URL drift

Affiliate parameters, redirects and localized Booking filenames no longer create a false snapshot conflict. Booking identities such as `hotel-name.ru.html`, `hotel-name.en-gb.html` and `hotel-name.html` are normalized as the same property. New Booking monitoring URLs also preserve `app_hotel_id` when available.

## Verification

Backend test suite: 125/125 passing.
Backend JavaScript syntax check: passing.
Modified Swift files: `swiftc -parse` passing.
