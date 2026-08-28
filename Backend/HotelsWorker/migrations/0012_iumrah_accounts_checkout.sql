PRAGMA foreign_keys = OFF;

-- iumrah ID is the only client identity. Remove device/client-user identity columns
-- while preserving every existing six-digit pilgrim id and trip relationship.
CREATE TABLE pilgrims_v2 (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  first_name TEXT NOT NULL DEFAULT '',
  last_name TEXT NOT NULL DEFAULT '',
  display_name TEXT NOT NULL DEFAULT '',
  phone TEXT NOT NULL DEFAULT '',
  email TEXT NOT NULL DEFAULT '',
  telegram TEXT NOT NULL DEFAULT '',
  whatsapp TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  last_trip_at TEXT,
  total_trips INTEGER NOT NULL DEFAULT 0
);
INSERT INTO pilgrims_v2 (
  id, first_name, last_name, display_name, phone, email, telegram, whatsapp,
  created_at, updated_at, last_trip_at, total_trips
)
SELECT id, first_name, last_name, display_name, phone, email, telegram, whatsapp,
       created_at, updated_at, last_trip_at, total_trips
FROM pilgrims;

CREATE TABLE pilgrim_trips_v2 (
  id TEXT PRIMARY KEY,
  booking_id TEXT NOT NULL UNIQUE,
  pilgrim_id INTEGER NOT NULL,
  status TEXT NOT NULL DEFAULT 'availability_check' CHECK (status IN (
    'availability_check','payment_pending','booking_confirmed',
    'ready_to_travel','in_trip','completed','cancelled'
  )),
  payment_status TEXT NOT NULL DEFAULT '',
  confirmation_number TEXT NOT NULL DEFAULT '',
  internal_notes TEXT NOT NULL DEFAULT '',
  start_date TEXT,
  end_date TEXT,
  booking_snapshot_json TEXT NOT NULL DEFAULT '{}',
  pricing_snapshot_json TEXT NOT NULL DEFAULT '{}',
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  completed_at TEXT,
  FOREIGN KEY (pilgrim_id) REFERENCES pilgrims_v2(id) ON DELETE RESTRICT
);
INSERT INTO pilgrim_trips_v2 (
  id, booking_id, pilgrim_id, status, payment_status, confirmation_number,
  internal_notes, start_date, end_date, booking_snapshot_json, pricing_snapshot_json,
  created_at, updated_at, completed_at
)
SELECT id, booking_id, pilgrim_id,
  CASE status
    WHEN 'new' THEN 'availability_check'
    WHEN 'availability_check' THEN 'availability_check'
    WHEN 'payment_pending' THEN 'payment_pending'
    WHEN 'paid' THEN 'booking_confirmed'
    WHEN 'booking_confirmed' THEN 'booking_confirmed'
    WHEN 'documents_ready' THEN 'ready_to_travel'
    WHEN 'ready_to_travel' THEN 'ready_to_travel'
    WHEN 'in_trip' THEN 'in_trip'
    WHEN 'completed' THEN 'completed'
    WHEN 'cancelled' THEN 'cancelled'
    ELSE 'availability_check'
  END,
  payment_status, confirmation_number, internal_notes, start_date, end_date,
  booking_snapshot_json, pricing_snapshot_json, created_at, updated_at, completed_at
FROM pilgrim_trips;

DROP TABLE pilgrim_trips;
DROP TABLE pilgrims;
ALTER TABLE pilgrims_v2 RENAME TO pilgrims;
ALTER TABLE pilgrim_trips_v2 RENAME TO pilgrim_trips;
CREATE INDEX idx_pilgrims_name ON pilgrims(last_name, first_name, display_name);
CREATE INDEX idx_pilgrims_last_trip ON pilgrims(last_trip_at DESC);
CREATE INDEX idx_trips_pilgrim ON pilgrim_trips(pilgrim_id, created_at DESC);
CREATE INDEX idx_trips_status ON pilgrim_trips(status, updated_at DESC);

-- Collapse historical status labels too, so every timeline uses the same state machine.
UPDATE booking_status_history SET
  old_status = CASE old_status
    WHEN 'new' THEN 'availability_check'
    WHEN 'paid' THEN 'booking_confirmed'
    WHEN 'documents_ready' THEN 'ready_to_travel'
    ELSE old_status
  END,
  new_status = CASE new_status
    WHEN 'new' THEN 'availability_check'
    WHEN 'paid' THEN 'booking_confirmed'
    WHEN 'documents_ready' THEN 'ready_to_travel'
    ELSE new_status
  END;

-- Booking tombstones replace the duplicated-0010 deleted-booking naming split.
-- Both compatibility tables are materialized first: on production one may already
-- exist and the other becomes an empty table. This lets the migration preserve data
-- regardless of which historical 0010 path ran.
CREATE TABLE IF NOT EXISTS deleted_bookings (
  booking_id TEXT PRIMARY KEY,
  deleted_by TEXT,
  deleted_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
CREATE TABLE IF NOT EXISTS legacy_deleted_bookings_cleanup (
  booking_id TEXT PRIMARY KEY,
  deleted_by TEXT,
  deleted_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
CREATE TABLE booking_tombstones (
  booking_id TEXT PRIMARY KEY,
  deleted_by TEXT,
  deleted_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
INSERT OR IGNORE INTO booking_tombstones (booking_id, deleted_by, deleted_at)
SELECT booking_id, deleted_by, deleted_at FROM deleted_bookings;
INSERT OR IGNORE INTO booking_tombstones (booking_id, deleted_by, deleted_at)
SELECT booking_id, deleted_by, deleted_at FROM legacy_deleted_bookings_cleanup;
DROP TABLE deleted_bookings;
DROP TABLE legacy_deleted_bookings_cleanup;

-- Device-generated identity is permanently retired. Push remains booking/account
-- authorized through client_push_subscriptions; this identity-keyed table is obsolete.
DROP TABLE IF EXISTS client_push_devices;

-- One account per permanent iumrah ID / pilgrim id.
CREATE TABLE iumrah_accounts (
  pilgrim_id INTEGER PRIMARY KEY,
  password_salt TEXT NOT NULL,
  password_hash TEXT NOT NULL,
  password_iterations INTEGER NOT NULL DEFAULT 100000,
  activated_at TEXT NOT NULL,
  password_updated_at TEXT NOT NULL,
  failed_attempts INTEGER NOT NULL DEFAULT 0,
  locked_until TEXT,
  last_login_at TEXT,
  FOREIGN KEY (pilgrim_id) REFERENCES pilgrims(id) ON DELETE CASCADE
);

CREATE TABLE iumrah_account_sessions (
  token_hash TEXT PRIMARY KEY,
  pilgrim_id INTEGER NOT NULL,
  created_at TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  last_used_at TEXT NOT NULL,
  revoked_at TEXT,
  FOREIGN KEY (pilgrim_id) REFERENCES pilgrims(id) ON DELETE CASCADE
);
CREATE INDEX idx_iumrah_sessions_pilgrim ON iumrah_account_sessions(pilgrim_id, expires_at DESC);
CREATE INDEX idx_iumrah_sessions_expiry ON iumrah_account_sessions(expires_at);

-- One structured travel form per traveler in the booking.
CREATE TABLE booking_travelers (
  id TEXT PRIMARY KEY,
  booking_id TEXT NOT NULL,
  position INTEGER NOT NULL,
  traveler_type TEXT NOT NULL DEFAULT 'adult' CHECK (traveler_type IN ('adult','child','infant')),
  first_name TEXT NOT NULL DEFAULT '',
  middle_name TEXT NOT NULL DEFAULT '',
  last_name TEXT NOT NULL DEFAULT '',
  gender TEXT NOT NULL DEFAULT '',
  date_of_birth TEXT NOT NULL DEFAULT '',
  place_of_birth TEXT NOT NULL DEFAULT '',
  nationality TEXT NOT NULL DEFAULT '',
  residence_country TEXT NOT NULL DEFAULT '',
  passport_number TEXT NOT NULL DEFAULT '',
  passport_issue_date TEXT NOT NULL DEFAULT '',
  passport_expiry_date TEXT NOT NULL DEFAULT '',
  passport_issuing_country TEXT NOT NULL DEFAULT '',
  phone TEXT NOT NULL DEFAULT '',
  email TEXT NOT NULL DEFAULT '',
  emergency_name TEXT NOT NULL DEFAULT '',
  emergency_phone TEXT NOT NULL DEFAULT '',
  emergency_relation TEXT NOT NULL DEFAULT '',
  passport_object_key TEXT,
  passport_content_type TEXT,
  completed INTEGER NOT NULL DEFAULT 0 CHECK (completed IN (0,1)),
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  UNIQUE (booking_id, position)
);
CREATE INDEX idx_booking_travelers_booking ON booking_travelers(booking_id, position);

CREATE TABLE booking_payment_instructions (
  booking_id TEXT PRIMARY KEY,
  visa_card_number TEXT NOT NULL DEFAULT '',
  visa_holder TEXT NOT NULL DEFAULT '',
  payme_qr_object_key TEXT,
  payme_qr_content_type TEXT,
  humo_card_number TEXT NOT NULL DEFAULT '',
  humo_holder TEXT NOT NULL DEFAULT '',
  instructions TEXT NOT NULL DEFAULT '',
  updated_by TEXT,
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);

CREATE TABLE booking_payment_receipts (
  id TEXT PRIMARY KEY,
  booking_id TEXT NOT NULL,
  payment_method TEXT NOT NULL CHECK (payment_method IN ('visa','payme','humo','other')),
  object_key TEXT NOT NULL UNIQUE,
  content_type TEXT NOT NULL,
  byte_size INTEGER NOT NULL DEFAULT 0,
  note TEXT NOT NULL DEFAULT '',
  review_status TEXT NOT NULL DEFAULT 'submitted' CHECK (review_status IN ('submitted','approved','rejected')),
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  reviewed_at TEXT,
  reviewed_by TEXT
);
CREATE INDEX idx_payment_receipts_booking ON booking_payment_receipts(booking_id, created_at DESC);

CREATE TABLE booking_travel_documents (
  id TEXT PRIMARY KEY,
  booking_id TEXT NOT NULL,
  document_kind TEXT NOT NULL DEFAULT 'other' CHECK (document_kind IN ('visa','voucher','insurance','ticket','other')),
  title TEXT NOT NULL,
  object_key TEXT NOT NULL UNIQUE,
  content_type TEXT NOT NULL,
  byte_size INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  created_by TEXT
);
CREATE INDEX idx_travel_documents_booking ON booking_travel_documents(booking_id, created_at ASC);

PRAGMA foreign_keys = ON;
