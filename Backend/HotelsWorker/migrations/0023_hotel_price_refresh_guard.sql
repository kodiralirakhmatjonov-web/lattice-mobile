PRAGMA foreign_keys = ON;

-- Confirmation guard for large provider-price jumps. The accepted catalog price
-- stays intact until a second matching refresh confirms an unusually large move.
ALTER TABLE hotel_price_cache ADD COLUMN pending_nightly_price_usd REAL;
ALTER TABLE hotel_price_cache ADD COLUMN pending_seen_count INTEGER NOT NULL DEFAULT 0;
ALTER TABLE hotel_price_cache ADD COLUMN pending_first_seen_at TEXT;
ALTER TABLE hotel_price_cache ADD COLUMN pending_last_seen_at TEXT;

CREATE INDEX IF NOT EXISTS idx_hotel_price_pending_confirmation
  ON hotel_price_cache(pending_seen_count, pending_last_seen_at);
