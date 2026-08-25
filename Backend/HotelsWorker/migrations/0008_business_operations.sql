PRAGMA foreign_keys = ON;

-- Public-facing owner / staff directory. Authentication remains in the existing
-- iumrah staff auth; this table stores editable business profile metadata only.
CREATE TABLE IF NOT EXISTS team_members (
  id TEXT PRIMARY KEY,
  staff_login TEXT,
  first_name TEXT NOT NULL DEFAULT '',
  last_name TEXT NOT NULL DEFAULT '',
  role_kind TEXT NOT NULL DEFAULT 'guide' CHECK (role_kind IN ('owner','guide','manager','operations')),
  role_title TEXT NOT NULL DEFAULT '',
  phone_uz TEXT NOT NULL DEFAULT '',
  phone_sa TEXT NOT NULL DEFAULT '',
  telegram TEXT NOT NULL DEFAULT '',
  whatsapp TEXT NOT NULL DEFAULT '',
  instagram TEXT NOT NULL DEFAULT '',
  bio TEXT NOT NULL DEFAULT '',
  public_slug TEXT NOT NULL UNIQUE,
  public_visible INTEGER NOT NULL DEFAULT 1 CHECK (public_visible IN (0,1)),
  active INTEGER NOT NULL DEFAULT 1 CHECK (active IN (0,1)),
  is_owner INTEGER NOT NULL DEFAULT 0 CHECK (is_owner IN (0,1)),
  sort_order INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_team_owner_login ON team_members(staff_login) WHERE staff_login IS NOT NULL AND staff_login != '';
CREATE INDEX IF NOT EXISTS idx_team_public ON team_members(public_visible, active, sort_order, last_name, first_name);

-- One canonical pilgrim identity. The public/display identifier is derived from
-- the integer id as PILGRIM-000006, avoiding a second mutable identifier system.
CREATE TABLE IF NOT EXISTS pilgrims (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  client_user_id TEXT UNIQUE,
  first_name TEXT NOT NULL DEFAULT '',
  last_name TEXT NOT NULL DEFAULT '',
  display_name TEXT NOT NULL DEFAULT '',
  phone TEXT NOT NULL DEFAULT '',
  email TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  last_trip_at TEXT,
  total_trips INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_pilgrims_name ON pilgrims(last_name, first_name, display_name);
CREATE INDEX IF NOT EXISTS idx_pilgrims_last_trip ON pilgrims(last_trip_at DESC);

-- A booking/trip is the operational envelope for one pilgrim. We deliberately
-- keep one compact raw booking snapshot and one pricing snapshot rather than
-- duplicating every provider field into dozens of sparse columns.
CREATE TABLE IF NOT EXISTS pilgrim_trips (
  id TEXT PRIMARY KEY,
  booking_id TEXT NOT NULL UNIQUE,
  pilgrim_id INTEGER NOT NULL,
  client_user_id TEXT,
  status TEXT NOT NULL DEFAULT 'new' CHECK (status IN (
    'new','availability_check','payment_pending','paid','booking_confirmed',
    'documents_ready','ready_to_travel','in_trip','completed','cancelled'
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
  FOREIGN KEY (pilgrim_id) REFERENCES pilgrims(id) ON DELETE RESTRICT
);
CREATE INDEX IF NOT EXISTS idx_trips_pilgrim ON pilgrim_trips(pilgrim_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_trips_status ON pilgrim_trips(status, updated_at DESC);

CREATE TABLE IF NOT EXISTS booking_status_history (
  id TEXT PRIMARY KEY,
  booking_id TEXT NOT NULL,
  old_status TEXT,
  new_status TEXT NOT NULL,
  changed_by TEXT,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
CREATE INDEX IF NOT EXISTS idx_booking_status_history ON booking_status_history(booking_id, created_at DESC);

-- Up to three curated hotels per city + star category. Consumer app renders
-- these as "Рекомендует iumrah"; live room rates remain a separate subsystem.
CREATE TABLE IF NOT EXISTS primary_hotels (
  city TEXT NOT NULL,
  star_category INTEGER NOT NULL CHECK (star_category BETWEEN 1 AND 5),
  position INTEGER NOT NULL CHECK (position BETWEEN 1 AND 3),
  hotel_id TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  PRIMARY KEY (city, star_category, position),
  UNIQUE (city, star_category, hotel_id),
  FOREIGN KEY (hotel_id) REFERENCES hotels(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_primary_hotels_lookup ON primary_hotels(city, star_category, position);

-- Chat images are optimized into R2 and referenced from messages. Text and media
-- stay in one chronological thread keyed by booking/trip.
ALTER TABLE business_chat_messages ADD COLUMN message_type TEXT NOT NULL DEFAULT 'text';
ALTER TABLE business_chat_messages ADD COLUMN attachment_id TEXT;

CREATE TABLE IF NOT EXISTS business_chat_attachments (
  id TEXT PRIMARY KEY,
  booking_id TEXT NOT NULL,
  object_key TEXT NOT NULL UNIQUE,
  content_type TEXT NOT NULL DEFAULT 'image/webp',
  byte_size INTEGER NOT NULL DEFAULT 0,
  width INTEGER,
  height INTEGER,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  FOREIGN KEY (booking_id) REFERENCES business_chat_threads(booking_id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_chat_attachments_booking ON business_chat_attachments(booking_id, created_at ASC);
