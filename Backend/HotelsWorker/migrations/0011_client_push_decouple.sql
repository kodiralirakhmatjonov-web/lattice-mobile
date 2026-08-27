PRAGMA foreign_keys = ON;

-- Push subscriptions are authorized by the upstream booking access token. They must
-- survive independently of the local operational trip mirror so that a temporary
-- sync problem cannot disable client notifications or chat availability.
CREATE TABLE client_push_subscriptions_v2 (
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
  PRIMARY KEY (device_token, booking_id)
);

INSERT OR IGNORE INTO client_push_subscriptions_v2 (
  device_token, booking_id, environment, app_bundle_id, locale, enabled,
  created_at, updated_at, last_success_at, last_error
)
SELECT
  device_token, booking_id, environment, app_bundle_id, locale, enabled,
  created_at, updated_at, last_success_at, last_error
FROM client_push_subscriptions;

DROP TABLE client_push_subscriptions;
ALTER TABLE client_push_subscriptions_v2 RENAME TO client_push_subscriptions;

CREATE INDEX IF NOT EXISTS idx_client_push_booking
  ON client_push_subscriptions(booking_id, enabled, updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_client_push_token
  ON client_push_subscriptions(device_token, enabled);
