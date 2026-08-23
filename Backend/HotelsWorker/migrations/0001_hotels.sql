PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS hotels (
  id TEXT PRIMARY KEY,
  slug TEXT NOT NULL UNIQUE,
  name TEXT NOT NULL,
  city TEXT NOT NULL,
  country TEXT NOT NULL DEFAULT 'Saudi Arabia',
  stars INTEGER,
  address TEXT NOT NULL DEFAULT '',
  description TEXT NOT NULL DEFAULT '',
  latitude REAL,
  longitude REAL,
  status TEXT NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'published', 'archived')),
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);

CREATE INDEX IF NOT EXISTS idx_hotels_city_status ON hotels(city, status);
CREATE INDEX IF NOT EXISTS idx_hotels_updated_at ON hotels(updated_at DESC);

CREATE TABLE IF NOT EXISTS hotel_amenities (
  hotel_id TEXT NOT NULL,
  amenity TEXT NOT NULL,
  position INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (hotel_id, amenity),
  FOREIGN KEY (hotel_id) REFERENCES hotels(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS hotel_rooms (
  id TEXT PRIMARY KEY,
  hotel_id TEXT NOT NULL,
  name TEXT NOT NULL,
  max_guests INTEGER,
  size_m2 REAL,
  beds TEXT,
  view TEXT,
  position INTEGER NOT NULL DEFAULT 0,
  FOREIGN KEY (hotel_id) REFERENCES hotels(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_hotel_rooms_hotel ON hotel_rooms(hotel_id, position);

CREATE TABLE IF NOT EXISTS hotel_sources (
  id TEXT PRIMARY KEY,
  hotel_id TEXT NOT NULL,
  provider TEXT NOT NULL,
  source_url TEXT NOT NULL,
  source_name TEXT,
  address TEXT,
  description TEXT,
  stars INTEGER,
  rating REAL,
  latitude REAL,
  longitude REAL,
  images_json TEXT NOT NULL DEFAULT '[]',
  amenities_json TEXT NOT NULL DEFAULT '[]',
  room_names_json TEXT NOT NULL DEFAULT '[]',
  checked_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  FOREIGN KEY (hotel_id) REFERENCES hotels(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_hotel_sources_hotel ON hotel_sources(hotel_id, provider);

CREATE TABLE IF NOT EXISTS hotel_images (
  id TEXT PRIMARY KEY,
  hotel_id TEXT NOT NULL,
  object_key TEXT NOT NULL UNIQUE,
  source_provider TEXT,
  source_url TEXT,
  content_type TEXT NOT NULL DEFAULT 'image/jpeg',
  byte_size INTEGER NOT NULL DEFAULT 0,
  position INTEGER NOT NULL DEFAULT 0,
  is_cover INTEGER NOT NULL DEFAULT 0 CHECK (is_cover IN (0, 1)),
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  FOREIGN KEY (hotel_id) REFERENCES hotels(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_hotel_images_hotel ON hotel_images(hotel_id, is_cover DESC, position ASC);
