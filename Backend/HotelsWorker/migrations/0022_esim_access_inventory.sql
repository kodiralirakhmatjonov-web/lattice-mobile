CREATE TABLE IF NOT EXISTS esim_access_inventory (
  id TEXT PRIMARY KEY,
  client_request_id TEXT NOT NULL UNIQUE,
  transaction_id TEXT NOT NULL UNIQUE,
  order_no TEXT,
  esim_tran_no TEXT,
  package_code TEXT NOT NULL,
  package_name TEXT NOT NULL DEFAULT '',
  country_code TEXT NOT NULL DEFAULT '',
  price_raw REAL NOT NULL DEFAULT 0,
  currency_code TEXT NOT NULL DEFAULT 'USD',
  volume_bytes REAL NOT NULL DEFAULT 0,
  duration INTEGER,
  duration_unit TEXT,
  iccid TEXT,
  lpa_string TEXT,
  smdp_address TEXT,
  activation_code TEXT,
  qr_code_url TEXT,
  short_url TEXT,
  smdp_status TEXT,
  esim_status TEXT,
  total_volume_bytes REAL NOT NULL DEFAULT 0,
  used_volume_bytes REAL NOT NULL DEFAULT 0,
  expires_at TEXT,
  purchase_status TEXT NOT NULL DEFAULT 'pending',
  provider_payload_json TEXT,
  assigned_booking_id TEXT,
  assigned_booking_esim_id TEXT,
  assigned_traveler_position INTEGER,
  created_by TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_esim_access_inventory_order_no
  ON esim_access_inventory(order_no) WHERE order_no IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS idx_esim_access_inventory_iccid
  ON esim_access_inventory(iccid) WHERE iccid IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_esim_access_inventory_assignment
  ON esim_access_inventory(assigned_booking_id, created_at);
CREATE INDEX IF NOT EXISTS idx_esim_access_inventory_status
  ON esim_access_inventory(purchase_status, created_at);
