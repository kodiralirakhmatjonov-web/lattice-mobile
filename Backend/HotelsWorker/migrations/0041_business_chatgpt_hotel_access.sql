CREATE TABLE IF NOT EXISTS business_chatgpt_hotel_access (
  id TEXT PRIMARY KEY CHECK (id = 'global'),
  enabled INTEGER NOT NULL DEFAULT 0 CHECK (enabled IN (0, 1)),
  updated_by TEXT,
  enabled_at TEXT,
  disabled_at TEXT,
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);

INSERT OR IGNORE INTO business_chatgpt_hotel_access(id, enabled, updated_at)
VALUES('global', 0, strftime('%Y-%m-%dT%H:%M:%fZ','now'));

-- OAuth handshake state exists only because ChatGPT Business custom apps require OAuth.
-- The effective operational permission is still the manual global switch above.
CREATE TABLE IF NOT EXISTS business_chatgpt_oauth_codes (
  code_hash TEXT PRIMARY KEY,
  client_id TEXT NOT NULL,
  redirect_uri TEXT NOT NULL,
  resource TEXT NOT NULL,
  scope TEXT NOT NULL,
  code_challenge TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  used_at TEXT,
  created_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_business_chatgpt_oauth_codes_expiry
  ON business_chatgpt_oauth_codes(expires_at);

CREATE TABLE IF NOT EXISTS business_chatgpt_oauth_tokens (
  token_hash TEXT PRIMARY KEY,
  token_type TEXT NOT NULL CHECK (token_type IN ('access','refresh')),
  client_id TEXT NOT NULL,
  resource TEXT NOT NULL,
  scope TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  last_used_at TEXT,
  created_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_business_chatgpt_oauth_tokens_expiry
  ON business_chatgpt_oauth_tokens(token_type, expires_at);
