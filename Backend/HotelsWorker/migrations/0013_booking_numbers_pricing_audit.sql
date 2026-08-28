-- Separate permanent Iumrah ID from the booking/package number.
-- Iumrah ID remains the six-digit pilgrims.id presentation. Booking numbers are
-- independent, human-facing counters rendered as #0001, #0002, ...
ALTER TABLE pilgrim_trips ADD COLUMN booking_number INTEGER;

WITH ranked AS (
  SELECT id, ROW_NUMBER() OVER (ORDER BY created_at ASC, id ASC) AS rn
  FROM pilgrim_trips
)
UPDATE pilgrim_trips
SET booking_number = (SELECT rn FROM ranked WHERE ranked.id = pilgrim_trips.id)
WHERE booking_number IS NULL;

CREATE UNIQUE INDEX IF NOT EXISTS idx_pilgrim_trips_booking_number
ON pilgrim_trips(booking_number)
WHERE booking_number IS NOT NULL;

CREATE TABLE IF NOT EXISTS booking_number_sequence (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  next_number INTEGER NOT NULL CHECK (next_number >= 1)
);
INSERT OR IGNORE INTO booking_number_sequence(id, next_number)
VALUES (1, COALESCE((SELECT MAX(booking_number) + 1 FROM pilgrim_trips), 1));
UPDATE booking_number_sequence
SET next_number = MAX(next_number, COALESCE((SELECT MAX(booking_number) + 1 FROM pilgrim_trips), 1))
WHERE id = 1;

-- Package Engine writes internal quote audits here. Only Business reads them.
CREATE TABLE IF NOT EXISTS package_quote_audits (
  quote_id TEXT PRIMARY KEY,
  pricing_version TEXT NOT NULL DEFAULT '',
  audit_json TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
CREATE INDEX IF NOT EXISTS idx_package_quote_audits_created
ON package_quote_audits(created_at DESC);
