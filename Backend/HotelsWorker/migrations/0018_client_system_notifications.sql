PRAGMA foreign_keys = ON;

-- Global client installation registry used for iumrah Signal broadcasts.
-- Unlike booking-scoped push subscriptions, this table also represents guests
-- and authenticated users who do not yet have a booking.
CREATE TABLE IF NOT EXISTS client_notification_devices (
  installation_id TEXT PRIMARY KEY,
  device_token TEXT,
  environment TEXT NOT NULL DEFAULT 'production' CHECK (environment IN ('production','development')),
  app_bundle_id TEXT NOT NULL DEFAULT 'com.iumrah.beta',
  locale TEXT NOT NULL DEFAULT 'ru',
  pilgrim_id INTEGER,
  is_authenticated INTEGER NOT NULL DEFAULT 0 CHECK (is_authenticated IN (0,1)),
  has_trip INTEGER NOT NULL DEFAULT 0 CHECK (has_trip IN (0,1)),
  enabled INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0,1)),
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  last_seen_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  last_success_at TEXT,
  last_error TEXT
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_client_notification_device_token
  ON client_notification_devices(device_token)
  WHERE device_token IS NOT NULL AND device_token <> '';
CREATE INDEX IF NOT EXISTS idx_client_notification_audience
  ON client_notification_devices(enabled, is_authenticated, has_trip, updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_client_notification_pilgrim
  ON client_notification_devices(pilgrim_id, updated_at DESC);

-- Preserve reachability for existing Beta devices before they open the build that
-- registers a stable installation id. New client registration replaces these legacy rows.
INSERT OR IGNORE INTO client_notification_devices (
  installation_id, device_token, environment, app_bundle_id, locale, pilgrim_id,
  is_authenticated, has_trip, enabled, created_at, updated_at, last_seen_at, last_success_at, last_error
)
SELECT
  'legacy:' || s.device_token,
  s.device_token,
  MAX(s.environment),
  MAX(s.app_bundle_id),
  MAX(s.locale),
  MAX(t.pilgrim_id),
  MAX(CASE WHEN a.pilgrim_id IS NOT NULL THEN 1 ELSE 0 END),
  1,
  MAX(s.enabled),
  MIN(s.created_at),
  MAX(s.updated_at),
  MAX(s.updated_at),
  MAX(s.last_success_at),
  MAX(s.last_error)
FROM client_push_subscriptions s
LEFT JOIN pilgrim_trips t ON t.booking_id=s.booking_id
LEFT JOIN iumrah_accounts a ON a.pilgrim_id=t.pilgrim_id
WHERE s.device_token IS NOT NULL AND s.device_token <> ''
GROUP BY s.device_token;

CREATE TABLE IF NOT EXISTS client_system_notifications (
  id TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  body TEXT NOT NULL,
  target_scope TEXT NOT NULL CHECK (target_scope IN ('all','authenticated','guest','has_trip')),
  destination TEXT NOT NULL DEFAULT 'home' CHECK (destination IN ('home','hotels','bookings','care','account','booking')),
  destination_booking_id TEXT,
  created_by TEXT,
  status TEXT NOT NULL DEFAULT 'sending' CHECK (status IN ('sending','published','failed')),
  matched_devices INTEGER NOT NULL DEFAULT 0,
  push_sent_count INTEGER NOT NULL DEFAULT 0,
  push_failed_count INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL,
  sent_at TEXT,
  expires_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_client_system_notifications_feed
  ON client_system_notifications(status, sent_at DESC, expires_at DESC);

CREATE TABLE IF NOT EXISTS client_system_notification_reads (
  notification_id TEXT NOT NULL,
  installation_id TEXT NOT NULL,
  opened_at TEXT NOT NULL,
  PRIMARY KEY (notification_id, installation_id),
  FOREIGN KEY (notification_id) REFERENCES client_system_notifications(id) ON DELETE CASCADE,
  FOREIGN KEY (installation_id) REFERENCES client_notification_devices(installation_id) ON DELETE CASCADE
);
