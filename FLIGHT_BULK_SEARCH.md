# iumrah Business — Flight Bulk JSON Search

## Purpose

Bulk search is a thin queue layer on top of the existing working manual flight curation flow.
It does **not** introduce a new Ignav architecture, a second flight cache, or a second publication path.

Every JSON item is converted into the same `BusinessFlightCurationSearchRequest` used by the manual screen and is sent sequentially to:

`POST /api/admin/package/flights/curation-search`

Because the same endpoint is reused, the existing backend behavior remains authoritative for:

- Ignav request execution
- existing server/database cache
- result normalization
- airline/logo presentation data
- publication into curated/current flights
- duplicate protection already used by the publication flow

## Product separation

These products must not be mixed:

- `ONE WAY` — one independent flight segment
- `RETURN` — technically the same ONE WAY search, but marked as the return role in Business
- `ROUND TRIP` — a separate unified Ignav round-trip fare
- `OPEN JAW` — not a round trip; search its two legs as independent ONE WAY requests

Bulk JSON accepts only ONE WAY inventory. Round-trip remains in the separate manual `Туда-обратно` mode.
The client now filters that mode to show only real `round_trip` offers and does not mix `paired_one_way` results into it.

## JSON contract

Maximum: **20 search tasks per pasted JSON**.

```json
{
  "type": "one_way",
  "searches": [
    {
      "id": "TAS-JED-2026-09-08",
      "direction": "outbound",
      "from": "TAS",
      "to": "JED",
      "date": "2026-09-08"
    },
    {
      "id": "MED-TAS-2026-09-15",
      "direction": "return",
      "from": "MED",
      "to": "TAS",
      "date": "2026-09-15"
    }
  ]
}
```

### Fields

- `type`: must be `one_way` when present
- `id`: optional human-readable identifier
- `direction`: `outbound` or `return`; defaults to `outbound` if omitted
- `from`: 3-letter IATA airport code
- `to`: 3-letter IATA airport code
- `date`: `YYYY-MM-DD`

All bulk requests preserve the current manual-search constraints:

- direct flights only (`max_stops = 0`)
- self-transfer disabled
- economy cabin
- currently selected airline filter
- current pilgrim count

## Execution behavior

1. Parse and validate the pasted JSON.
2. Reject more than 20 tasks.
3. Normalize IATA codes to uppercase.
4. Remove duplicate tasks with the same direction + origin + destination + date before any API call.
5. Execute requests **one by one**, never as a parallel burst.
6. A failed request does not cancel the rest of the batch.
7. `No results` is not treated as an error.
8. `Retry failed` repeats only failed tasks.
9. Each search group keeps all returned tariffs sorted by price.
10. Staff can publish one tariff, select all, or select the cheapest tariff from every search.
11. Bulk publication reuses the existing `publishCuratedFlight` path.
12. Already-published physical offers are shown as already published and cannot be selected again.

## Cache rule

Do **not** add a separate iOS cache for bulk search.

The server/database cache already used by the manual `curation-search` endpoint remains the single source of truth. Reusing the same endpoint is deliberate: a repeated bulk JSON request should benefit from exactly the same cache behavior as a repeated manual request.

## Airlines currently surfaced in the Business filter

- HY — Uzbekistan Airways
- C6 — Centrum Air
- HH — Qanot Sharq
- 9S — Air Samarkand
- 2U — Fly Khiva
- XY — flynas
- F3 — flyadeal
- SV — Saudia
- FZ — flydubai

Charter-only inventory may still be absent from Ignav. This bulk feature searches the same Ignav-backed inventory as the working manual screen; it does not pretend that Ignav contains private Umrah charter blocks.
