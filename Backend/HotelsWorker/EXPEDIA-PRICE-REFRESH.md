# Expedia hotel price refresh v3

Updated: 2026-09-11

## Goal

The catalogue needs a **fresh representative Expedia price for the exact hotel**, not an exact quote for the guest's eventual travel dates. Hotel identity is the Expedia `.h<propertyID>.Hotel-Information` ID. Room type and exact date are secondary: any sellable room for the same property is acceptable.

## What v3 fixes

1. **Large real price moves no longer look like failures.** v2 staged every move below 65% or above 175% of the old rate. A legitimate exact-property Expedia read such as `$87 -> ~$190` therefore returned `PRICE_CHANGE_AWAITING_CONFIRMATION`. v3 accepts a large move immediately when the evidence is strong and property-bound: Expedia rolling FAQ, explicit nightly lockup, or a high-confidence Browser Rendering room card. Weak/generic extraction still needs the two-hit confirmation guard.
2. **The Browser Rendering fallback now reaches the dates the catalogue actually needs.** Expedia probes are `+1, +7, +14, +20, +25, +30, +45, +60` days. The shared browser session can try the first six probes, so it now reaches `+20`, `+25`, and `+30` instead of stopping around the first two weeks.
3. **Imported trip dates no longer dominate refreshes.** They remain provenance only. Every Expedia refresh builds a rolling horizon relative to today.
4. **The imported Expedia storefront is preserved.** An `expedia.sa` source stays on `expedia.sa`; the refresher no longer rewrites it to `www.expedia.com`. This keeps the automated source aligned with the page the admin opens manually.
5. **Expedia's own rolling 30-day benchmark is now readable even when it appears after “Similar properties”.** Expedia often places the property FAQ below recommendation cards. The generic property scope intentionally stops before recommendations, so v2 could accidentally cut off the FAQ. v3 has a dedicated full-document parser for Expedia's property-specific sentence: “prices found for a 1-night stay for 2 adults … start from …”. This is treated as a high-confidence nightly benchmark because Expedia describes it as the lowest nightly rate found in the last 24 hours for stays in the next 30 days.

## Refresh order

`manual button / 15-min cron -> D1 lease -> preferred Expedia source -> canonical exact property -> rolling date ladder -> HTTP/SSR extraction -> one Browser Rendering session if necessary -> exact property validation -> D1 cache`

For Expedia, the engine tries the cheap HTTP/SSR path across the full rolling ladder first. If no usable rate is found, one Browser Rendering session checks up to six sparse dates. It never searches Expedia by hotel name and never accepts another property ID.

## Price semantics

- benchmark: `1 room / 2 adults / 1 night`
- room type: any sellable room belonging to the exact Expedia property
- currency: source amount may be USD/SAR/AED and is normalized to USD for the catalogue
- exact travel date: not required for catalogue pricing
- freshness: accepted source price expires after 48 hours
- failed refresh: previous accepted price stays visible and retry remains scheduled

## Admin button contract

- live source read succeeds and amount changed -> `ok:true, refreshed:true, changed:true`
- live source read succeeds and amount is the same -> `ok:true, refreshed:true, changed:false`
- no live source price was confirmed -> `ok:false, refreshed:false`; stale price may still be returned for continuity

A strong exact-property Expedia result is not blocked just because it differs sharply from the old price.

## Tests

The Worker suite covers the rolling Expedia FAQ after a `Similar properties` boundary, the new `+1/+7/+14/+20/+25/+30/+45/+60` ladder, regional storefront preservation, sold-out fallback, exact-property enforcement, and immediate acceptance of a large high-confidence Expedia movement. `npm run check` and the full `npm test` suite must pass before deployment.
