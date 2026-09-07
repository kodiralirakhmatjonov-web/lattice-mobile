PRAGMA foreign_keys = ON;

-- Manual admin price override. The provider cache remains untouched so an
-- administrator can always return to the exact locked Booking/Expedia source.
CREATE TABLE IF NOT EXISTS hotel_price_overrides (
  hotel_id TEXT PRIMARY KEY,
  nightly_price_usd REAL NOT NULL CHECK (nightly_price_usd > 0),
  updated_by TEXT,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  FOREIGN KEY (hotel_id) REFERENCES hotels(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_hotel_price_overrides_updated
  ON hotel_price_overrides(updated_at);
