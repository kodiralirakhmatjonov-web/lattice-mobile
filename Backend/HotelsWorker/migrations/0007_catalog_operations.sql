PRAGMA foreign_keys = ON;

-- Keep the canonical catalog intentionally compact. Rich provider-page noise is not
-- part of the user-facing hotel object; the important catalog surfaces are identity,
-- location, amenities, rooms and optimized media.
ALTER TABLE hotels ADD COLUMN catalog_profile TEXT NOT NULL DEFAULT 'core-v1';
ALTER TABLE hotels ADD COLUMN source_room_count INTEGER NOT NULL DEFAULT 0;

-- Heartbeats make long-running imports observable and recoverable. We keep the
-- existing status CHECK and represent a user cancellation as status='failed',
-- stage='cancelled' so this migration is safe on the existing D1 table.
ALTER TABLE hotel_import_jobs ADD COLUMN heartbeat_at TEXT;
ALTER TABLE hotel_import_jobs ADD COLUMN cancel_requested_at TEXT;
ALTER TABLE hotel_import_jobs ADD COLUMN last_error_code TEXT;

UPDATE hotel_import_jobs
SET heartbeat_at = COALESCE(heartbeat_at, updated_at, created_at)
WHERE heartbeat_at IS NULL;

-- Source rows are provenance, not a second copy of the full property page.
-- Canonical room/media data already lives in hotel_rooms / hotel_images.
UPDATE hotel_sources SET
  images_json='[]',
  amenities_json='[]',
  room_names_json='[]',
  room_details_json='[]',
  policies_json='[]',
  nearby_json='[]',
  facts_json='[]',
  fees_json='[]',
  services_json='[]',
  highlights_json='[]',
  important_information_json='[]',
  food_json='[]',
  parking_transport_json='[]',
  accessibility_json='[]',
  raw_identity_json='{}';

-- Legacy provider-page policies/facts are not needed for hotel selection and made
-- the canonical row difficult to reason about. Keep useful curated sections only.
UPDATE hotels SET
  policies_json='[]',
  facts_json='[]',
  fees_json='[]',
  services_json='[]',
  important_information_json='[]',
  catalog_profile='core-v1';


UPDATE hotels
SET source_room_count = (
  SELECT COUNT(*) FROM hotel_rooms WHERE hotel_rooms.hotel_id = hotels.id
);

CREATE INDEX IF NOT EXISTS idx_hotel_import_jobs_heartbeat
  ON hotel_import_jobs(status, heartbeat_at);
CREATE INDEX IF NOT EXISTS idx_hotels_catalog_profile
  ON hotels(catalog_profile, status, city);
