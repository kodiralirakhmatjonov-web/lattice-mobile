PRAGMA foreign_keys = ON;

-- Operational flight overrides verified by AeroDataBox. The original client
-- booking snapshot remains immutable history; staff changes live here.
CREATE TABLE IF NOT EXISTS trip_flights (
  booking_id TEXT NOT NULL,
  direction TEXT NOT NULL CHECK (direction IN ('outbound','return')),
  flight_number TEXT NOT NULL DEFAULT '',
  call_sign TEXT NOT NULL DEFAULT '',
  airline_name TEXT NOT NULL DEFAULT '',
  airline_iata TEXT NOT NULL DEFAULT '',
  airline_icao TEXT NOT NULL DEFAULT '',
  departure_airport_iata TEXT NOT NULL DEFAULT '',
  departure_airport_icao TEXT NOT NULL DEFAULT '',
  departure_airport_name TEXT NOT NULL DEFAULT '',
  arrival_airport_iata TEXT NOT NULL DEFAULT '',
  arrival_airport_icao TEXT NOT NULL DEFAULT '',
  arrival_airport_name TEXT NOT NULL DEFAULT '',
  scheduled_departure_local TEXT NOT NULL DEFAULT '',
  scheduled_departure_utc TEXT NOT NULL DEFAULT '',
  scheduled_arrival_local TEXT NOT NULL DEFAULT '',
  scheduled_arrival_utc TEXT NOT NULL DEFAULT '',
  departure_terminal TEXT NOT NULL DEFAULT '',
  arrival_terminal TEXT NOT NULL DEFAULT '',
  departure_gate TEXT NOT NULL DEFAULT '',
  arrival_gate TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL DEFAULT '',
  verification_provider TEXT NOT NULL DEFAULT 'aerodatabox',
  verification_key TEXT NOT NULL DEFAULT '',
  verified_at TEXT,
  last_checked_at TEXT,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  PRIMARY KEY (booking_id, direction)
);
CREATE INDEX IF NOT EXISTS idx_trip_flights_number ON trip_flights(flight_number, scheduled_departure_local);

-- Cache one normalized AeroDataBox result per flight/date. This prevents staff
-- reopening the same flight editor from repeatedly consuming RapidAPI units.
CREATE TABLE IF NOT EXISTS flight_verification_cache (
  cache_key TEXT PRIMARY KEY,
  flight_number TEXT NOT NULL,
  date_local TEXT NOT NULL,
  candidates_json TEXT NOT NULL DEFAULT '[]',
  checked_at TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  provider TEXT NOT NULL DEFAULT 'aerodatabox'
);
CREATE INDEX IF NOT EXISTS idx_flight_verification_expiry ON flight_verification_cache(expires_at);

-- Mutable operational assignments. Canonical hotel content and staff profiles
-- stay in their own tables; a booking only stores references to the selected
-- hotel/guide override.
CREATE TABLE IF NOT EXISTS trip_assignments (
  booking_id TEXT PRIMARY KEY,
  makkah_hotel_id TEXT,
  madinah_hotel_id TEXT,
  guide_team_member_id TEXT,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  FOREIGN KEY (makkah_hotel_id) REFERENCES hotels(id) ON DELETE SET NULL,
  FOREIGN KEY (madinah_hotel_id) REFERENCES hotels(id) ON DELETE SET NULL,
  FOREIGN KEY (guide_team_member_id) REFERENCES team_members(id) ON DELETE SET NULL
);

-- Keep booking deletion explicit and auditable while preventing a deleted
-- upstream booking from being silently re-synchronized if an upstream cache
-- briefly returns stale data.
CREATE TABLE IF NOT EXISTS deleted_bookings (
  booking_id TEXT PRIMARY KEY,
  deleted_by TEXT,
  deleted_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
