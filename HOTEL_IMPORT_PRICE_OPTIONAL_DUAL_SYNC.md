# Hotel Import price optional + dual Hotel Sync copy

- Hotel Importer no longer rejects a complete hotel with HOTEL_PRICE_REQUIRED.
- Confirmed room types remain required for publish; imported price is best-effort and may be added manually later.
- Hotel Sync keeps both the read-only URL and the JSON body for Makkah and Madinah.
- Each city card exposes separate Copy link and Copy JSON actions.
- JSON body fetch is best-effort: a temporary JSON fetch failure does not invalidate the working read-only URL.
- Existing keyboard dismissal controls remain unchanged.
- No D1 migration.
