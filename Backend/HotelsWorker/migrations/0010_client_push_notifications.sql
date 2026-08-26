PRAGMA foreign_keys = ON;

-- Consumer iOS push subscriptions are scoped to a booking because the current
-- Beta client authenticates each trip with its booking access token rather than
-- a global account session. One APNs device may therefore subscribe to several
-- bookings owned by the same pilgrim.
CREATE TABLE IF NOT EXISTS client_push_subscriptions (
  device_token TEXT NOT NULL,
  booking_id TEXT NOT NULL,
  environment TEXT NOT NULL DEFAULT 'production' CHECK (environment IN ('production','development')),
  app_bundle_id TEXT NOT NULL DEFAULT 'com.iumrah.beta',
  locale TEXT NOT NULL DEFAULT 'ru',
  enabled INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0,1)),
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  last_success_at TEXT,
  last_error TEXT,
  PRIMARY KEY (device_token, booking_id),
  FOREIGN KEY (booking_id) REFERENCES pilgrim_trips(booking_id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_client_push_booking
  ON client_push_subscriptions(booking_id, enabled, updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_client_push_token
  ON client_push_subscriptions(device_token, enabled);
