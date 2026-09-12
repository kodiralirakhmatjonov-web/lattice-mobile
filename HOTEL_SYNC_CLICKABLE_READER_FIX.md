# Hotel Sync clickable reader fix

## Changed files

- `Backend/HotelsWorker/src/index.js`
- `Backend/HotelsWorker/tests/business-hotel-sync-runtime.test.mjs`
- `Backend/HotelsWorker/tests/price-monitor-chatgpt-bridge-contract.test.mjs`
- `HOTEL_CHATGPT_SYNC.md`

## Deployment

No database migration is required.

Deploy the Hotels Worker from the normal repository workflow. Existing Hotel Sync secret URLs stay valid.

After deployment:

1. Open iumrah Business → Hotels → price update / ChatGPT Sync.
2. Choose the city/date.
3. Tap **Синхронизировать и скопировать** once so the saved snapshot is regenerated with clean monitoring URLs.
4. Paste the copied URL into ChatGPT.
5. ChatGPT can now follow each exact Expedia/Booking link directly from the sync page.
6. Paste the returned `iumrah.hotel-price-update.v2` JSON into iumrah Business and preview/apply selected changes as before.

Appending `?format=json` to the secret URL exposes the raw snapshot for diagnostics.
