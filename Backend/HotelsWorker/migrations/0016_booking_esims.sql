CREATE TABLE IF NOT EXISTS booking_esims (
  id TEXT PRIMARY KEY,
  booking_id TEXT NOT NULL,
  traveler_position INTEGER,
  label TEXT NOT NULL DEFAULT 'Saudi Arabia eSIM',
  provider TEXT NOT NULL DEFAULT 'esim_access',
  provider_esim_id TEXT,
  iccid TEXT NOT NULL DEFAULT '',
  plan_name TEXT NOT NULL DEFAULT '',
  country_code TEXT NOT NULL DEFAULT 'SA',
  total_mb REAL NOT NULL DEFAULT 0,
  used_mb REAL NOT NULL DEFAULT 0,
  remaining_mb REAL NOT NULL DEFAULT 0,
  validity_days INTEGER,
  status TEXT NOT NULL DEFAULT 'ready',
  provider_status TEXT,
  provider_smdp_status TEXT,
  smdp_address TEXT NOT NULL DEFAULT '',
  activation_code TEXT NOT NULL DEFAULT '',
  lpa_string TEXT NOT NULL DEFAULT '',
  qr_code_url TEXT,
  activated_at TEXT,
  expires_at TEXT,
  last_usage_sync_at TEXT,
  usage_source TEXT NOT NULL DEFAULT 'pending',
  updated_by TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_booking_esims_booking ON booking_esims(booking_id, traveler_position, created_at);
CREATE INDEX IF NOT EXISTS idx_booking_esims_iccid ON booking_esims(iccid);
