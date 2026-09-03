PRAGMA foreign_keys = ON;

-- One conservative, normalized hotel price snapshot per canonical hotel.
-- The source URL already belongs to hotel_sources; this cache only stores the
-- latest provider quote and its exact benchmark context. A successful quote is
-- valid for 48 hours. Failed refreshes never destroy the last known price.
CREATE TABLE IF NOT EXISTS hotel_price_cache (
  hotel_id TEXT PRIMARY KEY,
  source_id TEXT,
  provider TEXT,
  source_url TEXT,
  resolved_url TEXT,
  amount_original REAL,
  currency_original TEXT,
  price_basis TEXT CHECK (price_basis IS NULL OR price_basis IN ('nightly','stay_total')),
  nightly_price_usd REAL,
  quote_total_usd REAL,
  quote_check_in TEXT,
  quote_check_out TEXT,
  quote_nights INTEGER,
  quote_adults INTEGER,
  quote_rooms INTEGER,
  confidence REAL,
  method TEXT,
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','fresh','stale','failed')),
  fetched_at TEXT,
  expires_at TEXT,
  last_attempt_at TEXT,
  next_retry_at TEXT,
  last_http_status INTEGER,
  error TEXT,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  FOREIGN KEY (hotel_id) REFERENCES hotels(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_hotel_price_due
  ON hotel_price_cache(status, expires_at, next_retry_at);
CREATE INDEX IF NOT EXISTS idx_hotel_price_provider
  ON hotel_price_cache(provider, fetched_at DESC);

-- D1 cannot remove R2 objects. One-time catalog maintenance is therefore queued
-- by SQL and completed by the Worker. The cutoff protects any new hotel media
-- uploaded after the clean-start migration from being deleted.
CREATE TABLE IF NOT EXISTS catalog_maintenance_tasks (
  id TEXT PRIMARY KEY,
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','running','completed','failed')),
  cutoff_at TEXT,
  deleted_objects INTEGER NOT NULL DEFAULT 0,
  attempt_count INTEGER NOT NULL DEFAULT 0,
  next_retry_at TEXT,
  error TEXT,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  started_at TEXT,
  completed_at TEXT,
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);

CREATE INDEX IF NOT EXISTS idx_catalog_maintenance_due
  ON catalog_maintenance_tasks(status, next_retry_at, created_at);
