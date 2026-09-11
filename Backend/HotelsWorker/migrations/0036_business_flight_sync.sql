CREATE TABLE IF NOT EXISTS business_flight_sync_feeds (
  owner_login TEXT PRIMARY KEY,
  token_hash TEXT NOT NULL UNIQUE,
  enabled INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0, 1)),
  snapshot_json TEXT NOT NULL DEFAULT '{"version":1,"flights":[]}',
  flight_count INTEGER NOT NULL DEFAULT 0,
  snapshot_updated_at TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_business_flight_sync_token
  ON business_flight_sync_feeds(token_hash, enabled);
