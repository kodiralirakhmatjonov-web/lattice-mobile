PRAGMA foreign_keys = ON;
CREATE TABLE IF NOT EXISTS hotel_price_refresh_leases (
  hotel_id TEXT PRIMARY KEY REFERENCES hotels(id) ON DELETE CASCADE,
  token TEXT NOT NULL,
  expires_at TEXT NOT NULL
);

-- Repair missing price-source locks without touching existing locks or prices.
INSERT OR IGNORE INTO hotel_price_sources (hotel_id, source_id, provider, source_url)
SELECT h.id, hs.id, hs.provider, hs.source_url
FROM hotels h JOIN hotel_sources hs ON hs.id = (
  SELECT s.id FROM hotel_sources s LEFT JOIN hotel_price_cache hp ON hp.hotel_id=s.hotel_id
  WHERE s.hotel_id=h.id AND LOWER(s.provider) IN ('booking','booking.com','expedia','expedia.com')
    AND s.source_url IS NOT NULL AND s.source_url!=''
  ORDER BY CASE WHEN hp.source_id=s.id THEN 0 WHEN hp.source_url=s.source_url THEN 1 ELSE 2 END,
    s.checked_at ASC LIMIT 1
);
