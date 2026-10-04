PRAGMA foreign_keys = ON;

-- Security timeline used by iumrah Business to surface Telegram-style
-- "New login" banners in-app, not only as APNs notifications.
CREATE TABLE IF NOT EXISTS business_security_login_events (
  id TEXT PRIMARY KEY,
  staff_login TEXT NOT NULL,
  session_id TEXT NOT NULL,
  device_id TEXT NOT NULL,
  device_name TEXT NOT NULL DEFAULT '',
  device_model TEXT NOT NULL DEFAULT '',
  platform TEXT NOT NULL DEFAULT 'ios',
  os_name TEXT NOT NULL DEFAULT '',
  os_version TEXT NOT NULL DEFAULT '',
  city TEXT NOT NULL DEFAULT '',
  country_code TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL,
  FOREIGN KEY (device_id) REFERENCES business_security_devices(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_business_security_login_events_staff
  ON business_security_login_events(staff_login, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_business_security_login_events_session
  ON business_security_login_events(session_id);
