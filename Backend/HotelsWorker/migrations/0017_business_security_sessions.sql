PRAGMA foreign_keys = ON;

-- A persistent device identity is separate from an individual login session.
-- This lets the original iPhone remain the protected primary device even after
-- a normal logout, while every new installation starts with restricted rights.
CREATE TABLE IF NOT EXISTS business_security_devices (
  id TEXT PRIMARY KEY,
  staff_login TEXT NOT NULL,
  installation_id TEXT NOT NULL,
  installation_secret_hash TEXT NOT NULL,
  device_name TEXT NOT NULL DEFAULT '',
  device_model TEXT NOT NULL DEFAULT '',
  hardware_identifier TEXT NOT NULL DEFAULT '',
  platform TEXT NOT NULL DEFAULT 'ios',
  os_name TEXT NOT NULL DEFAULT 'iOS',
  os_version TEXT NOT NULL DEFAULT '',
  app_version TEXT NOT NULL DEFAULT '',
  app_build TEXT NOT NULL DEFAULT '',
  locale TEXT NOT NULL DEFAULT '',
  time_zone TEXT NOT NULL DEFAULT '',
  city TEXT NOT NULL DEFAULT '',
  country_code TEXT NOT NULL DEFAULT '',
  is_primary INTEGER NOT NULL DEFAULT 0 CHECK (is_primary IN (0,1)),
  trusted INTEGER NOT NULL DEFAULT 0 CHECK (trusted IN (0,1)),
  created_at TEXT NOT NULL,
  last_seen_at TEXT NOT NULL,
  approved_at TEXT,
  approved_by_device_id TEXT,
  revoked_at TEXT,
  revoked_by_device_id TEXT,
  UNIQUE(staff_login, installation_id)
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_business_security_primary
  ON business_security_devices(staff_login)
  WHERE is_primary=1 AND revoked_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_business_security_devices_login
  ON business_security_devices(staff_login, revoked_at, last_seen_at DESC);

-- Raw session credentials are never stored. Only SHA-256 token hashes live in D1.
CREATE TABLE IF NOT EXISTS business_staff_sessions (
  id TEXT PRIMARY KEY,
  staff_login TEXT NOT NULL,
  device_id TEXT NOT NULL,
  token_hash TEXT NOT NULL UNIQUE,
  created_at TEXT NOT NULL,
  last_seen_at TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  revoked_at TEXT,
  revoked_by_session_id TEXT,
  revocation_reason TEXT,
  FOREIGN KEY (device_id) REFERENCES business_security_devices(id) ON DELETE CASCADE
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_business_staff_active_device
  ON business_staff_sessions(device_id)
  WHERE revoked_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_business_staff_sessions_login
  ON business_staff_sessions(staff_login, revoked_at, expires_at DESC);
CREATE INDEX IF NOT EXISTS idx_business_staff_sessions_expiry
  ON business_staff_sessions(expires_at);

-- Links APNs registrations to the protected installation so the new-login alert
-- can be sent to the owner's other devices without notifying the new device.
ALTER TABLE business_push_devices ADD COLUMN installation_id TEXT;
CREATE INDEX IF NOT EXISTS idx_business_push_staff_installation
  ON business_push_devices(staff_login, installation_id, enabled);
