PRAGMA foreign_keys = ON;

-- Staged hotel price monitoring. A monitor run never mutates the production
-- hotel_price_cache until an administrator explicitly publishes selected rows.
CREATE TABLE IF NOT EXISTS hotel_price_monitor_runs (
  id TEXT PRIMARY KEY,
  status TEXT NOT NULL DEFAULT 'queued' CHECK (status IN ('queued','running','completed','completed_with_errors','failed')),
  requested_by TEXT,
  total_hotels INTEGER NOT NULL DEFAULT 0,
  checked_hotels INTEGER NOT NULL DEFAULT 0,
  changed_hotels INTEGER NOT NULL DEFAULT 0,
  unchanged_hotels INTEGER NOT NULL DEFAULT 0,
  failed_hotels INTEGER NOT NULL DEFAULT 0,
  published_hotels INTEGER NOT NULL DEFAULT 0,
  workflow_instance_id TEXT,
  error TEXT,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  started_at TEXT,
  completed_at TEXT,
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);

CREATE INDEX IF NOT EXISTS idx_hotel_price_monitor_runs_created
  ON hotel_price_monitor_runs(created_at DESC);

CREATE TABLE IF NOT EXISTS hotel_price_monitor_items (
  id TEXT PRIMARY KEY,
  run_id TEXT NOT NULL,
  hotel_id TEXT NOT NULL,
  hotel_name TEXT NOT NULL,
  city TEXT,
  stars INTEGER,
  provider TEXT,
  source_url TEXT,
  resolved_url TEXT,
  old_nightly_usd REAL,
  candidate_nightly_usd REAL,
  amount_original REAL,
  currency_original TEXT,
  price_basis TEXT,
  quote_total_usd REAL,
  quote_check_in TEXT,
  quote_check_out TEXT,
  quote_nights INTEGER,
  quote_adults INTEGER,
  quote_rooms INTEGER,
  confidence REAL,
  method TEXT,
  http_status INTEGER,
  status TEXT NOT NULL DEFAULT 'queued' CHECK (status IN ('queued','checking','changed','unchanged','failed','published','ignored')),
  error TEXT,
  checked_at TEXT,
  published_at TEXT,
  published_by TEXT,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  FOREIGN KEY (run_id) REFERENCES hotel_price_monitor_runs(id) ON DELETE CASCADE,
  FOREIGN KEY (hotel_id) REFERENCES hotels(id) ON DELETE CASCADE,
  UNIQUE (run_id, hotel_id)
);

CREATE INDEX IF NOT EXISTS idx_hotel_price_monitor_items_run
  ON hotel_price_monitor_items(run_id, status, hotel_name);

-- Read-only, short-lived links that can be pasted into ChatGPT on plans where a
-- private MCP app cannot be connected. Only a SHA-256 token hash is persisted.
CREATE TABLE IF NOT EXISTS chatgpt_access_links (
  id TEXT PRIMARY KEY,
  token_hash TEXT NOT NULL UNIQUE,
  scope TEXT NOT NULL CHECK (scope IN ('hotel_catalog','price_monitor_run')),
  run_id TEXT,
  created_by TEXT,
  expires_at TEXT NOT NULL,
  revoked_at TEXT,
  last_used_at TEXT,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  FOREIGN KEY (run_id) REFERENCES hotel_price_monitor_runs(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_chatgpt_access_links_expiry
  ON chatgpt_access_links(expires_at);
