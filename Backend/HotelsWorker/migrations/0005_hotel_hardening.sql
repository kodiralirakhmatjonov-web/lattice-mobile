PRAGMA foreign_keys = ON;

-- Rich canonical identity and normalized property sections.
ALTER TABLE hotels ADD COLUMN brand TEXT;
ALTER TABLE hotels ADD COLUMN chain_name TEXT;
ALTER TABLE hotels ADD COLUMN postal_code TEXT;
ALTER TABLE hotels ADD COLUMN highlights_json TEXT NOT NULL DEFAULT '[]';
ALTER TABLE hotels ADD COLUMN important_information_json TEXT NOT NULL DEFAULT '[]';
ALTER TABLE hotels ADD COLUMN food_json TEXT NOT NULL DEFAULT '[]';
ALTER TABLE hotels ADD COLUMN parking_transport_json TEXT NOT NULL DEFAULT '[]';
ALTER TABLE hotels ADD COLUMN accessibility_json TEXT NOT NULL DEFAULT '[]';
ALTER TABLE hotels ADD COLUMN lifecycle_state TEXT NOT NULL DEFAULT 'draft';
ALTER TABLE hotels ADD COLUMN data_quality_json TEXT NOT NULL DEFAULT '{}';
ALTER TABLE hotels ADD COLUMN last_verified_at TEXT;

-- Preserve lifecycle semantics for catalog rows that existed before this migration.
UPDATE hotels
SET lifecycle_state = CASE
  WHEN status = 'published' THEN 'published'
  WHEN status = 'archived' THEN 'archived'
  ELSE 'draft'
END,
last_verified_at = COALESCE(last_verified_at, updated_at);

ALTER TABLE hotel_sources ADD COLUMN brand TEXT;
ALTER TABLE hotel_sources ADD COLUMN chain_name TEXT;
ALTER TABLE hotel_sources ADD COLUMN postal_code TEXT;
ALTER TABLE hotel_sources ADD COLUMN highlights_json TEXT NOT NULL DEFAULT '[]';
ALTER TABLE hotel_sources ADD COLUMN important_information_json TEXT NOT NULL DEFAULT '[]';
ALTER TABLE hotel_sources ADD COLUMN food_json TEXT NOT NULL DEFAULT '[]';
ALTER TABLE hotel_sources ADD COLUMN parking_transport_json TEXT NOT NULL DEFAULT '[]';
ALTER TABLE hotel_sources ADD COLUMN accessibility_json TEXT NOT NULL DEFAULT '[]';
ALTER TABLE hotel_sources ADD COLUMN raw_identity_json TEXT NOT NULL DEFAULT '{}';

-- Room-specific fields that must not be inferred from generic property text.
ALTER TABLE hotel_rooms ADD COLUMN smoking TEXT;
ALTER TABLE hotel_rooms ADD COLUMN accessibility_json TEXT NOT NULL DEFAULT '[]';
ALTER TABLE hotel_rooms ADD COLUMN category TEXT;
ALTER TABLE hotel_rooms ADD COLUMN bathroom_json TEXT NOT NULL DEFAULT '[]';

-- R2 media integrity / optimization metadata.
ALTER TABLE hotel_images ADD COLUMN content_hash TEXT;
ALTER TABLE hotel_images ADD COLUMN width INTEGER;
ALTER TABLE hotel_images ADD COLUMN height INTEGER;
ALTER TABLE hotel_images ADD COLUMN original_byte_size INTEGER NOT NULL DEFAULT 0;
ALTER TABLE hotel_images ADD COLUMN transform_version TEXT;
ALTER TABLE hotel_images ADD COLUMN source_dedupe_key TEXT;

CREATE UNIQUE INDEX IF NOT EXISTS idx_hotel_images_content_hash
  ON hotel_images(hotel_id, content_hash)
  WHERE content_hash IS NOT NULL AND content_hash != '';
CREATE INDEX IF NOT EXISTS idx_hotel_images_source_dedupe
  ON hotel_images(hotel_id, source_dedupe_key);
CREATE INDEX IF NOT EXISTS idx_hotels_identity_lookup
  ON hotels(city, name, brand);
CREATE INDEX IF NOT EXISTS idx_hotels_lifecycle
  ON hotels(lifecycle_state, updated_at DESC);

-- Immutable import request snapshot + idempotency.
ALTER TABLE hotel_import_jobs ADD COLUMN idempotency_key TEXT;
ALTER TABLE hotel_import_jobs ADD COLUMN hotel_snapshot_json TEXT NOT NULL DEFAULT '{}';
ALTER TABLE hotel_import_jobs ADD COLUMN snapshot_hash TEXT;
ALTER TABLE hotel_import_jobs ADD COLUMN retry_count INTEGER NOT NULL DEFAULT 0;
ALTER TABLE hotel_import_jobs ADD COLUMN possible_duplicate_json TEXT;

CREATE UNIQUE INDEX IF NOT EXISTS idx_hotel_import_jobs_idempotency
  ON hotel_import_jobs(idempotency_key)
  WHERE idempotency_key IS NOT NULL AND idempotency_key != '';
