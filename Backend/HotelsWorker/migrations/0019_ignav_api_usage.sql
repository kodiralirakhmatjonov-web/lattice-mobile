CREATE TABLE IF NOT EXISTS ignav_api_usage_monthly (
  period TEXT PRIMARY KEY,
  successful_requests INTEGER NOT NULL DEFAULT 0,
  first_success_at TEXT,
  last_success_at TEXT,
  updated_at TEXT NOT NULL
);
