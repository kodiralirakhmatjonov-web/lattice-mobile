# iumrah Beta ↔ iumrah Business Cloud contract

This Worker is the source of truth for the mobile client account, operational trip state, checkout, chat and protected trip media. The iumrah Beta app uses HTTP APIs only and never connects directly to D1 or R2.

## Canonical client identity: iumrah ID

There is one client identity model only:

- every pilgrim has one permanent six-digit **iumrah ID**, for example `000016`;
- the iumrah ID is also the username used to sign in;
- the account belongs to the pilgrim, not to a booking and not to a device;
- every current and future trip is linked to that same pilgrim/account;
- no `clientUserID`, device-generated user id, `CLIENT_SESSION_URL`, or identity-keyed push table is part of the active architecture.

Before an account exists, a booking access token is accepted only as a bootstrap capability proving ownership of the booking. It is not an identity. After activation/sign-in, the client uses the iumrah account bearer session.

### Account endpoints

- `POST /api/catalog/hotels/client/account/activate`
  - available when the booking is in `payment_pending`;
  - booking access token proves the user owns the trip;
  - body: `{ "bookingID": "...", "password": "..." }`;
  - returns the permanent iumrah ID and an account session.
- `POST /api/catalog/hotels/client/account/login`
  - body: `{ "iumrahID": "000016", "password": "..." }`.
- `GET /api/catalog/hotels/client/account/session`
- `POST /api/catalog/hotels/client/account/logout`
- `POST /api/catalog/hotels/client/account/link-booking`
  - links an existing booking-token trip to the signed-in canonical pilgrim account.

Passwords are never stored in plaintext. Account sessions are server-side and the mobile app stores only its bearer token in Keychain.

## Canonical trip statuses

Only these seven operational states are active:

1. `availability_check` — New request / availability check
2. `payment_pending` — Availability confirmed / payment and pilgrim data
3. `booking_confirmed` — Paid / booking confirmed
4. `ready_to_travel` — Documents ready / ready to travel
5. `in_trip` — Pilgrim is travelling
6. `completed` — Trip completed
7. `cancelled` — Cancelled

Legacy values are migration inputs only:

- `new` → `availability_check`
- `paid` → `booking_confirmed`
- `documents_ready` → `ready_to_travel`

The client reads the operational status from Business Cloud and does not create a second state machine.

## Trip synchronization and recovery

Immediately after booking creation the Beta app syncs the booking into Business Cloud through the existing trip-sync endpoint using its booking bootstrap credential. Business Cloud creates/links the permanent pilgrim record and returns the six-digit iumrah ID.

Once signed in, account-scoped trip endpoints restore every trip belonging to the canonical pilgrim after reinstall or on another device. A new iumrah ID must never be generated for each trip.

## Checkout: account → travelers → payment

When a trip enters `payment_pending`, the client shows the checkout CTA. The required sequence is:

1. activate the existing iumrah ID by setting and confirming a password (or sign in if already active);
2. complete one traveler form per traveler in the booking;
3. upload a private passport image for every traveler;
4. use payment instructions configured by iumrah Business;
5. upload a payment receipt.

Traveler rows are derived from the real booking traveler counts. Required readiness data includes personal identity, birth data, nationality/residence, passport data, contact data, emergency contact, and a passport image.

Business configures payment details per booking:

- Visa card number + holder;
- PayMe QR;
- Humo card number + holder;
- optional instruction text.

The server rejects a transition into `booking_confirmed` unless the account is active, every traveler form is complete, and at least one receipt exists.

## Protected media

Passport images, PayMe QR images, payment receipts and travel documents live under private R2 object keys. They do not have public R2 URLs.

- client media reads require the signed-in account to own the trip (bootstrap booking token is allowed only where explicitly needed before account activation);
- Business media reads require staff authentication;
- protected responses use `private, no-store` semantics.

## Travel documents

Business can upload visa, voucher, insurance, ticket or other PDF/image documents to a booking. The server rejects `ready_to_travel` until at least one trip document exists. The Beta app displays the protected documents inside the trip and can preview PDFs/images natively.

## One-to-one chat and push

One booking id equals one chat thread. Chat and booking-scoped push subscriptions are authorized through the canonical account session after sign-in, with booking-token bootstrap compatibility only for pre-account trips. The old identity-keyed `client_push_devices` table is removed by migration.

## Public catalog/team APIs

Public team profiles and Primary Hotels continue to use the existing catalog endpoints. Hotel identity, hotel rates and hotel translation architecture are independent of the client-account model and must not be duplicated in the app.
