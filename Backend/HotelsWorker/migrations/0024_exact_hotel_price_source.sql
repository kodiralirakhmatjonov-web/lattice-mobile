PRAGMA foreign_keys = ON;

-- Exact-source pricing contract.
-- One hotel owns one immutable price source URL. Price refresh must only open
-- this exact URL; it must never search by name, rewrite dates, switch provider,
-- or probe alternate pages.
CREATE TABLE IF NOT EXISTS hotel_price_sources (
  hotel_id TEXT PRIMARY KEY,
  source_id TEXT NOT NULL,
  provider TEXT NOT NULL,
  source_url TEXT NOT NULL,
  locked_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  FOREIGN KEY (hotel_id) REFERENCES hotels(id) ON DELETE CASCADE,
  FOREIGN KEY (source_id) REFERENCES hotel_sources(id) ON DELETE CASCADE
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_hotel_price_sources_source
  ON hotel_price_sources(hotel_id, source_id);

-- Backfill existing hotels. If an accepted cache already identifies the source,
-- keep that exact source. Otherwise lock the oldest supported source that was
-- originally imported for this hotel.
INSERT OR IGNORE INTO hotel_price_sources (hotel_id, source_id, provider, source_url, locked_at, updated_at)
SELECT h.id, hs.id, hs.provider, hs.source_url,
       strftime('%Y-%m-%dT%H:%M:%fZ','now'), strftime('%Y-%m-%dT%H:%M:%fZ','now')
FROM hotels h
JOIN hotel_sources hs ON hs.id = (
  SELECT hs2.id
  FROM hotel_sources hs2
  LEFT JOIN hotel_price_cache hp ON hp.hotel_id = h.id
  WHERE hs2.hotel_id = h.id
    AND LOWER(hs2.provider) IN ('booking','expedia')
  ORDER BY
    CASE
      WHEN hp.source_id = hs2.id THEN 0
      WHEN hp.source_url = hs2.source_url THEN 1
      ELSE 2
    END,
    hs2.checked_at ASC
  LIMIT 1
)
WHERE LOWER(hs.provider) IN ('booking','expedia');

-- Ask maintenance to re-read existing cards from their locked exact URL as soon
-- as possible, while preserving the currently visible accepted price until the
-- exact-source refresh succeeds.
UPDATE hotel_price_cache
SET next_retry_at = strftime('%Y-%m-%dT%H:%M:%fZ','now'),
    pending_nightly_price_usd = NULL,
    pending_seen_count = 0,
    pending_first_seen_at = NULL,
    pending_last_seen_at = NULL,
    updated_at = strftime('%Y-%m-%dT%H:%M:%fZ','now');
