-- Server-owned post-booking hand-off from PackageEngine to iumrah Business.
-- No configurator state is written here before a real booking exists.
CREATE TABLE IF NOT EXISTS pending_package_pricing_reports (
  booking_id TEXT PRIMARY KEY,
  quote_id TEXT NOT NULL,
  pricing_version TEXT NOT NULL,
  pricing_snapshot_json TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_pending_package_pricing_reports_updated_at
ON pending_package_pricing_reports(updated_at);
