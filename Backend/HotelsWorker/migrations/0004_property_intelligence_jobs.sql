ALTER TABLE hotels ADD COLUMN canonical_key TEXT;
ALTER TABLE hotels ADD COLUMN google_maps_url TEXT;
ALTER TABLE hotels ADD COLUMN nearby_json TEXT NOT NULL DEFAULT '[]';
ALTER TABLE hotels ADD COLUMN facts_json TEXT NOT NULL DEFAULT '[]';
ALTER TABLE hotels ADD COLUMN fees_json TEXT NOT NULL DEFAULT '[]';
ALTER TABLE hotels ADD COLUMN services_json TEXT NOT NULL DEFAULT '[]';

ALTER TABLE hotel_sources ADD COLUMN provider_hotel_id TEXT;
ALTER TABLE hotel_sources ADD COLUMN canonical_url TEXT;
ALTER TABLE hotel_sources ADD COLUMN google_maps_url TEXT;
ALTER TABLE hotel_sources ADD COLUMN nearby_json TEXT NOT NULL DEFAULT '[]';
ALTER TABLE hotel_sources ADD COLUMN facts_json TEXT NOT NULL DEFAULT '[]';
ALTER TABLE hotel_sources ADD COLUMN fees_json TEXT NOT NULL DEFAULT '[]';
ALTER TABLE hotel_sources ADD COLUMN services_json TEXT NOT NULL DEFAULT '[]';

CREATE INDEX IF NOT EXISTS idx_hotels_canonical_key ON hotels(canonical_key);
CREATE INDEX IF NOT EXISTS idx_hotel_sources_url ON hotel_sources(source_url);
CREATE INDEX IF NOT EXISTS idx_hotel_sources_provider_id ON hotel_sources(provider, provider_hotel_id);

CREATE TABLE IF NOT EXISTS hotel_import_jobs (
  id TEXT PRIMARY KEY,
  hotel_id TEXT NOT NULL,
  hotel_name TEXT NOT NULL,
  source_provider TEXT,
  source_url TEXT,
  workflow_instance_id TEXT,
  status TEXT NOT NULL DEFAULT 'queued' CHECK (status IN ('queued','running','completed','failed','duplicate')),
  stage TEXT NOT NULL DEFAULT 'queued',
  progress INTEGER NOT NULL DEFAULT 0,
  total_images INTEGER NOT NULL DEFAULT 0,
  stored_images INTEGER NOT NULL DEFAULT 0,
  failed_images INTEGER NOT NULL DEFAULT 0,
  images_json TEXT NOT NULL DEFAULT '[]',
  publish_when_complete INTEGER NOT NULL DEFAULT 0 CHECK (publish_when_complete IN (0,1)),
  error TEXT,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  started_at TEXT,
  completed_at TEXT,
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  FOREIGN KEY (hotel_id) REFERENCES hotels(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_hotel_import_jobs_status ON hotel_import_jobs(status, updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_hotel_import_jobs_hotel ON hotel_import_jobs(hotel_id, created_at DESC);

CREATE TABLE IF NOT EXISTS hotel_translations (
  hotel_id TEXT NOT NULL,
  locale TEXT NOT NULL,
  source_hash TEXT NOT NULL,
  payload_json TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  PRIMARY KEY (hotel_id, locale),
  FOREIGN KEY (hotel_id) REFERENCES hotels(id) ON DELETE CASCADE
);
