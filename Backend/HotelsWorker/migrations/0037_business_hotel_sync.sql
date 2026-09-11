CREATE TABLE IF NOT EXISTS business_hotel_sync_feeds (
  owner_login TEXT NOT NULL,
  city TEXT NOT NULL CHECK (city IN ('Makkah', 'Madinah')),
  token_hash TEXT NOT NULL UNIQUE,
  enabled INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0, 1)),
  snapshot_id TEXT,
  snapshot_json TEXT NOT NULL DEFAULT '{"version":2,"hotels":[]}',
  hotel_count INTEGER NOT NULL DEFAULT 0,
  check_in TEXT,
  check_out TEXT,
  snapshot_updated_at TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (owner_login, city)
);

CREATE INDEX IF NOT EXISTS idx_business_hotel_sync_token
  ON business_hotel_sync_feeds(token_hash, enabled);
