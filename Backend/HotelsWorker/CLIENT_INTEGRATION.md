# iumrah client integration contract

The consumer iumrah app must use HTTP APIs. It must never connect directly to D1 or R2.

## Public team profiles

- `GET https://iumrah.app/api/catalog/hotels/team`
- `GET https://iumrah.app/api/catalog/hotels/team/{publicSlug}`

These endpoints expose only team members that are both active and public.

## Primary Hotels

- `GET https://iumrah.app/api/catalog/hotels/primary?city=Makkah&stars=5`

The response contains up to three curated hotels in priority order and `recommendationLabel: "Рекомендует iumrah"`.
Fetch the full hotel card from `GET /api/catalog/hotels/{hotelID}` with the app's selected locale/translation flow.

## Trip / pilgrim synchronization

After a booking is successfully created, call:

- `POST https://iumrah.app/api/catalog/hotels/client/trips/sync`

using the same authenticated client session. The authenticated user id must equal `clientUserID`.

Payload shape:

```json
{
  "bookingID": "BOOKING-ID",
  "clientUserID": "STABLE-USER-ID",
  "firstName": "",
  "lastName": "",
  "displayName": "",
  "phone": "",
  "email": "",
  "startDate": "2026-09-05",
  "endDate": "2026-09-12",
  "bookingSnapshot": {
    "id": "BOOKING-ID"
  },
  "pricingSnapshot": {
    "currency": "USD",
    "components": []
  }
}
```

Always send the complete generator snapshot needed by iumrah Business. Do not send only the public total.
Recommended component keys include outbound flight, return flight, visa, Makkah hotel, Madinah hotel, transfers, guide, eSIM, support, platform/service fee, payment fee, supplier cost, sell price, margin and totals.

The Business Cloud derives a stable pilgrim display id such as `PILGRIM-000006` and stores every booking as a separate Trip under that pilgrim.

To read Business-managed trip status back in the client:

- `GET /api/catalog/hotels/client/trips`
- `GET /api/catalog/hotels/client/trips/{bookingID}`

Use these statuses for payment/confirmation/travel progress instead of inventing a second client-only state machine.

## One-to-one chat

The chat uses the booking id as the thread id and requires the same authenticated client session that owns the synchronized trip.

- `GET /api/catalog/hotels/client/chats/{bookingID}/messages`
- `POST /api/catalog/hotels/client/chats/{bookingID}/messages`
  - JSON: `{ "body": "...", "clientMessageID": "UUID" }`
- `POST /api/catalog/hotels/client/chats/{bookingID}/attachments`
  - raw image body; `Content-Type: image/jpeg` (or another image content type)
- `POST /api/catalog/hotels/client/chats/{bookingID}/read`

Image URLs returned in messages are relative to `https://iumrah.app` and remain protected by booking ownership checks.

## Authentication adapter

The Worker currently validates the client session through `CLIENT_SESSION_URL`, defaulting to `https://iumrah.app/api/auth/session`. If the consumer app's actual authenticated session endpoint differs, update this binding/adapter to the client's real source of truth rather than weakening booking authorization.
