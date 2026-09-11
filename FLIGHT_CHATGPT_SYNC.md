# iumrah Business — ChatGPT Flight Sync (compatible with Price Monitor Bridge)

This patch is designed to be applied **after** `iumrah-business-price-monitor-chatgpt-bridge-v1`.
It preserves that bridge and adds the flight catalogue feed.

## Why migration 0036
The Price Monitor Bridge already owns migration `0035_price_monitor_chatgpt_bridge.sql`.
Flight Sync therefore uses `0036_business_flight_sync.sql` so both schemas remain independent and deploy in a clear order.

## Flight-monitor access model
The Flight Sync URL is durable, revocable and read-only so a recurring ChatGPT monitor can use the same URL over time.
The public URL can only read the published-flight mirror and cannot search Ignav, publish, edit, delete, access bookings or staff sessions.

The current repository does not contain the backend implementation that owns
`/api/admin/package/flights/curated`. Therefore this version mirrors the published list fetched by iumrah Business into D1.
The mirror refreshes whenever the published list is loaded/changed while the Flights screen is active and can be forced with **Синхронизировать**.

For a future zero-staleness design, move the read-only token endpoint into the backend that owns
`/api/admin/package/flights/curated` and return the canonical flight rows directly on every GET. That would retain the durable token while removing the mirror entirely.

## One-time setup
1. Deploy Hotels Worker migrations. `0035_price_monitor_chatgpt_bridge.sql` remains intact; this patch adds `0036_business_flight_sync.sql`.
2. Build/install iumrah Business.
3. Open **Авиабилеты → Опубликованные**.
4. Tap **Подключить ChatGPT**.
5. Paste the generated read-only URL into the monitoring chat.

## Comparison rule
Normal one-way/charter comparison key:
`FROM-TO-FLIGHTNUMBER-YYYY-MM-DD`

- absent key -> new flight -> return publication JSON;
- same key, same seat-only fare -> ignore;
- same key, changed verified seat-only fare -> report price change separately;
- package prices are never interpreted as seat-only prices.
