PRAGMA foreign_keys = ON;

ALTER TABLE pilgrims ADD COLUMN telegram TEXT NOT NULL DEFAULT '';
ALTER TABLE pilgrims ADD COLUMN whatsapp TEXT NOT NULL DEFAULT '';
CREATE INDEX IF NOT EXISTS idx_pilgrims_telegram ON pilgrims(telegram) WHERE telegram <> '';
CREATE INDEX IF NOT EXISTS idx_pilgrims_whatsapp ON pilgrims(whatsapp) WHERE whatsapp <> '';

ALTER TABLE team_members ADD COLUMN photo_object_key TEXT;
ALTER TABLE team_members ADD COLUMN photo_content_type TEXT;

CREATE TABLE IF NOT EXISTS client_push_devices (
  device_token TEXT PRIMARY KEY,
  client_user_id TEXT NOT NULL,
  platform TEXT NOT NULL DEFAULT 'ios',
  environment TEXT NOT NULL DEFAULT 'production',
  app_bundle_id TEXT NOT NULL DEFAULT 'com.iumrah.beta',
  enabled INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0,1)),
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  last_success_at TEXT,
  last_error TEXT
);
CREATE INDEX IF NOT EXISTS idx_client_push_identity ON client_push_devices(client_user_id, enabled, updated_at DESC);

CREATE TABLE IF NOT EXISTS operation_notification_receipts (
  event_key TEXT PRIMARY KEY,
  booking_id TEXT NOT NULL,
  event_type TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
CREATE INDEX IF NOT EXISTS idx_operation_notification_booking ON operation_notification_receipts(booking_id, created_at DESC);

ALTER TABLE deleted_bookings RENAME TO legacy_deleted_bookings_cleanup;
