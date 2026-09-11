PRAGMA foreign_keys = ON;

-- Expedia price refresh v2.
-- Prefer the imported Expedia property as the deterministic price source when a
-- hotel has both Booking and Expedia metadata. We change only the source lock;
-- the last accepted price remains untouched until a live Expedia refresh wins.
UPDATE hotel_price_sources
SET source_id = (
      SELECT hs.id
      FROM hotel_sources hs
      WHERE hs.hotel_id = hotel_price_sources.hotel_id
        AND LOWER(hs.provider) IN ('expedia','expedia.com')
        AND hs.source_url IS NOT NULL AND hs.source_url != ''
      ORDER BY hs.checked_at DESC, hs.id DESC
      LIMIT 1
    ),
    provider = 'Expedia',
    source_url = (
      SELECT hs.source_url
      FROM hotel_sources hs
      WHERE hs.hotel_id = hotel_price_sources.hotel_id
        AND LOWER(hs.provider) IN ('expedia','expedia.com')
        AND hs.source_url IS NOT NULL AND hs.source_url != ''
      ORDER BY hs.checked_at DESC, hs.id DESC
      LIMIT 1
    ),
    updated_at = strftime('%Y-%m-%dT%H:%M:%fZ','now')
WHERE EXISTS (
  SELECT 1 FROM hotel_sources hs
  WHERE hs.hotel_id = hotel_price_sources.hotel_id
    AND LOWER(hs.provider) IN ('expedia','expedia.com')
    AND hs.source_url IS NOT NULL AND hs.source_url != ''
);

-- Hotels imported after older migrations may not have a price-source lock yet.
INSERT OR IGNORE INTO hotel_price_sources (hotel_id, source_id, provider, source_url, locked_at, updated_at)
SELECT h.id, hs.id, 'Expedia', hs.source_url,
       strftime('%Y-%m-%dT%H:%M:%fZ','now'), strftime('%Y-%m-%dT%H:%M:%fZ','now')
FROM hotels h
JOIN hotel_sources hs ON hs.id = (
  SELECT hs2.id
  FROM hotel_sources hs2
  WHERE hs2.hotel_id = h.id
    AND LOWER(hs2.provider) IN ('expedia','expedia.com')
    AND hs2.source_url IS NOT NULL AND hs2.source_url != ''
  ORDER BY hs2.checked_at DESC, hs2.id DESC
  LIMIT 1
);

-- Make Expedia rows due immediately so the new same-property/any-room reader is
-- exercised by the next 15-minute cron pass. Preserve nightly_price_usd: a
-- provider failure must never erase the last accepted catalogue rate.
UPDATE hotel_price_cache
SET status = CASE WHEN nightly_price_usd IS NOT NULL THEN 'stale' ELSE 'failed' END,
    expires_at = strftime('%Y-%m-%dT%H:%M:%fZ','now'),
    next_retry_at = strftime('%Y-%m-%dT%H:%M:%fZ','now'),
    error = NULL,
    updated_at = strftime('%Y-%m-%dT%H:%M:%fZ','now')
WHERE hotel_id IN (
  SELECT hotel_id FROM hotel_price_sources
  WHERE LOWER(provider) IN ('expedia','expedia.com')
);
