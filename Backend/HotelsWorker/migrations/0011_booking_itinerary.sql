CREATE TABLE IF NOT EXISTS booking_itinerary_items (
  id TEXT PRIMARY KEY,
  booking_id TEXT NOT NULL,
  date_local TEXT NOT NULL,
  sort_order INTEGER NOT NULL DEFAULT 0,
  title TEXT NOT NULL,
  subtitle TEXT NOT NULL DEFAULT '',
  icon TEXT NOT NULL DEFAULT 'calendar',
  location TEXT NOT NULL DEFAULT '',
  notes TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_booking_itinerary_booking_date
  ON booking_itinerary_items(booking_id, date_local, sort_order);
