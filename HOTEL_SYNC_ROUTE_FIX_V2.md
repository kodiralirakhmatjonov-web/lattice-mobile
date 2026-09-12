# Hotel Sync route fix v2

This update keeps Flight Sync unchanged and hardens only Hotel Sync delivery.

Changes:
- keeps the ChatGPT-readable HTML Hotel Sync reader and `?format=json` raw feed;
- strips stale Expedia app/deep-link tracking parameters from monitoring URLs;
- adds an explicit Cloudflare route `iumrah.app/api/catalog/hotels/hotel-sync/*` before the broad hotels route;
- adds release marker `hotel-sync-reader-v2-20260912` to the feed, HTML metadata, response headers, and health payload;
- preserves D1 snapshot validation and manual update confirmation.

After Apply ZIP completes, run `Deploy iumrah Hotels Cloud`, then verify the same secret Hotel Sync URL. A correct production response is HTML by default and contains release `hotel-sync-reader-v2-20260912`.
