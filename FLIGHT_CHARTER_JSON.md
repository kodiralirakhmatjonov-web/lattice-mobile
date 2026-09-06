# iumrah Business — Charter JSON Import

## Purpose

The **Чартеры** workspace is the third flight-curation mode next to **Один поиск** and **Массовый**.

It is intentionally separate from Ignav:

- no Ignav search request is made;
- no provider quota is spent;
- pasted JSON is validated locally in iumrah Business;
- valid entries are rendered as normal flight cards;
- publication reuses the existing `publishCuratedFlight` / curated-flight backend path;
- existing published-flight duplicate checks remain active.

This is for confirmed Umrah charter / non-GDS inventory whose fare and schedule were obtained from a supplier, airline, tour operator, or another published source.

## JSON contract

Maximum: **50 charter flights per import**.

```json
{
  "type": "charter",
  "flights": [
    {
      "id": "NMA-MED-F39135-2026-09-09",
      "direction": "outbound",
      "from": "NMA",
      "to": "MED",
      "airline": {
        "name": "flyadeal",
        "iata": "F3"
      },
      "flight_number": "F39135",
      "departure_at": "2026-09-09T15:40:00+05:00",
      "arrival_at": "2026-09-09T19:40:00+03:00",
      "price": {
        "amount": 329,
        "currency": "USD",
        "type": "seat"
      },
      "source": {
        "name": "Supplier / published source",
        "url": "https://example.com/charter-source",
        "published_at": "2026-09-06T17:00:00+05:00"
      },
      "cabin_class": "economy"
    }
  ]
}
```

## Required fields

Each flight must contain:

- `from` — 3-letter IATA origin code;
- `to` — 3-letter IATA destination code;
- `airline.name` — carrier name;
- `airline.iata` — 2-character IATA code;
- `flight_number` — published flight number;
- `departure_at` — exact ISO 8601 date/time with timezone;
- `arrival_at` — exact ISO 8601 date/time with timezone;
- `price.amount` — positive numeric fare;
- `price.currency` — 3-letter currency code;
- `source.name` — supplier / airline / publication name;
- `source.url` — full `http` or `https` source link.

Optional fields:

- `id` — stable human-readable source ID. If omitted, Business generates an internal ID for that import;
- `direction` — `outbound` or `return`; defaults to `outbound`;
- `price.type` — normally `seat`; stored in the itinerary price status;
- `source.published_at` — ISO 8601 timestamp (or `YYYY-MM-DD`) for when the source was published/observed;
- `cabin_class` — defaults to `economy`.

## Timezone rule

Always provide local airport times with explicit UTC offsets.

Uzbekistan example:

`2026-09-09T15:40:00+05:00`

Saudi Arabia example:

`2026-09-09T19:40:00+03:00`

This prevents ambiguous departure/arrival dates and correctly calculates overnight durations.

## Persistence mapping

The charter is converted to the existing `BusinessFlightCurationItinerary` contract:

- `fare_scope = charter`
- `offer_type = one_way`
- `journey_role = outbound` or `return`
- `source = source.url`
- `source_name = source.name`
- `price.amount = price.amount`
- `price.currency = price.currency`
- `price.status = price.type`
- `ignav_id = null`
- `legs[0]` contains airline, flight number, airports, exact timestamps, calculated duration, `stops = 0`, and cabin class.

The resulting itinerary is published through the same curated-flight endpoint already used by manual and bulk Ignav results. No second publication architecture is introduced.

## UI behavior

1. Open **Авиабилеты → Чартеры**.
2. Paste JSON.
3. Tap **Сформировать чартерные карточки**.
4. Business validates the entire payload before creating cards.
5. Every card shows carrier logo, flight number, route, departure/arrival, seat price, source name and source link.
6. Staff can publish one charter or select/publish multiple charters.
7. Already-published physical offers remain protected by the existing publication identity checks.
8. Published charter rows are labeled **CHARTER** and keep the source link when the backend returns the stored itinerary.

## Important separation

- **Один поиск** → Ignav manual search.
- **Массовый** → up to 20 sequential ONE WAY Ignav searches through the same working cache/search path.
- **Чартеры** → JSON import only; never calls Ignav.
- **Туда-обратно** → dedicated Ignav round-trip remains inside manual search and is not mixed with charter import.

## v3 safety / expiry behavior

- Charter cards are marked with a yellow `exclamationmark.triangle.fill` warning and the text `Вне регулярного расписания` so non-GDS/charter inventory is visually distinct from scheduled Ignav fares.
- Charter JSON with a departure date earlier than the current calendar day is rejected before publication.
- When the Business flight screen loads or the app returns to the foreground, it loads the existing published-flight list, finds offers whose `outbound_date` is earlier than today, and deletes them through the existing curated-flight DELETE endpoint. This removes those rows through the same backend deletion path already used by the manual trash action.
- This patch does not add or replace a Cloudflare/D1 flight backend. It deliberately reuses the existing curated-flight API.
