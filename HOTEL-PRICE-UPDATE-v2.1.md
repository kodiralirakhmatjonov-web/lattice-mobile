# iumrah Business — JSON Price Exchange v2.1

This patch removes the runtime dependency on the new `/api/admin/hotels/price-json/*` routes.

- Export is generated locally in iumrah Business from the existing authenticated `/api/admin/hotels` catalog.
- Import preview is validated locally against a fresh copy of the existing hotel catalog.
- Source URL, city and old price must still match before a row is selectable.
- Only `changed` rows with `high` or `medium` confidence are selectable.
- Apply re-reads the current catalog and writes each approved price through the existing stable per-hotel price endpoint.
- No Browser Rendering, Cloudflare Workflow, ChatGPT bridge, or new Cloudflare route is required.
- The hotel importer remains untouched.
