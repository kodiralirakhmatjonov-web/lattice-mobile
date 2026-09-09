CREATE TABLE IF NOT EXISTS ziyarat_routes (
  id TEXT PRIMARY KEY,
  slug TEXT NOT NULL UNIQUE,
  city TEXT NOT NULL,
  country TEXT NOT NULL DEFAULT 'Saudi Arabia',
  title TEXT NOT NULL,
  subtitle TEXT,
  transport_mode TEXT NOT NULL DEFAULT 'car',
  status TEXT NOT NULL DEFAULT 'published' CHECK(status IN ('draft','published')),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_ziyarat_routes_city_status
  ON ziyarat_routes(city, status, updated_at DESC);

CREATE TABLE IF NOT EXISTS ziyarat_places (
  id TEXT PRIMARY KEY,
  route_id TEXT NOT NULL REFERENCES ziyarat_routes(id) ON DELETE CASCADE,
  slug TEXT NOT NULL UNIQUE,
  title TEXT NOT NULL,
  title_ar TEXT,
  category TEXT NOT NULL DEFAULT 'historical',
  short_description TEXT NOT NULL DEFAULT '',
  long_description TEXT NOT NULL DEFAULT '',
  interesting_facts_json TEXT NOT NULL DEFAULT '[]',
  visit_notes TEXT,
  visit_type TEXT NOT NULL DEFAULT 'stop',
  duration_minutes INTEGER NOT NULL DEFAULT 30,
  latitude REAL NOT NULL,
  longitude REAL NOT NULL,
  address TEXT,
  map_label TEXT,
  route_order INTEGER NOT NULL DEFAULT 1,
  status TEXT NOT NULL DEFAULT 'draft' CHECK(status IN ('draft','published')),
  created_by TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_ziyarat_places_route_order
  ON ziyarat_places(route_id, status, route_order, updated_at DESC);

CREATE TABLE IF NOT EXISTS ziyarat_images (
  id TEXT PRIMARY KEY,
  place_id TEXT NOT NULL REFERENCES ziyarat_places(id) ON DELETE CASCADE,
  object_key TEXT NOT NULL UNIQUE,
  content_type TEXT NOT NULL DEFAULT 'image/jpeg',
  byte_size INTEGER,
  width INTEGER,
  height INTEGER,
  position INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_ziyarat_images_place_position
  ON ziyarat_images(place_id, position, created_at);

INSERT OR IGNORE INTO ziyarat_routes (
  id, slug, city, country, title, subtitle, transport_mode, status, created_at, updated_at
) VALUES (
  'medina-main', 'medina-ziyarat', 'Madinah', 'Saudi Arabia',
  'Medina Ziyarat', 'Sacred and historic places around Madinah', 'car', 'published',
  '2026-09-09T00:00:00.000Z', '2026-09-09T00:00:00.000Z'
);

INSERT OR IGNORE INTO ziyarat_places (
  id, route_id, slug, title, title_ar, category, short_description, long_description,
  interesting_facts_json, visit_notes, visit_type, duration_minutes, latitude, longitude,
  address, map_label, route_order, status, created_by, created_at, updated_at
) VALUES (
  'quba-mosque', 'medina-main', 'quba-mosque', 'Quba Mosque', 'مسجد قباء', 'mosque',
  'The first mosque established in Islam and one of Madinah’s most important ziyarat stops.',
  'Quba Mosque is closely connected with the Hijrah and the earliest Muslim community in Madinah. The present mosque stands on the historic site and remains one of the city’s most visited places. iumrah uses the exact saved coordinate for this stop rather than a text search, so the map marker always points to the intended location.',
  '["The mosque is connected with the beginning of the Prophet’s ﷺ life in Madinah.","It is traditionally regarded as the first mosque established in Islam.","The modern complex preserves the identity of the historic Quba site while serving large numbers of worshippers."]',
  'Main stop. Allow enough time to enter calmly, pray and regroup with your guide before continuing the route.',
  'enter', 40, 24.43917, 39.61722,
  '3493 Al Hijrah Rd, Al Khatim, Madinah 42318, Saudi Arabia', 'Quba Mosque · exact point',
  1, 'published', 'seed', '2026-09-09T00:00:00.000Z', '2026-09-09T00:00:00.000Z'
);

INSERT OR IGNORE INTO ziyarat_images (id, place_id, object_key, content_type, position, created_at) VALUES
  ('quba-1', 'quba-mosque', 'ziyarats/quba-mosque/quba-1.jpg', 'image/jpeg', 0, '2026-09-09T00:00:00.000Z'),
  ('quba-2', 'quba-mosque', 'ziyarats/quba-mosque/quba-2.jpg', 'image/jpeg', 1, '2026-09-09T00:00:00.000Z'),
  ('quba-3', 'quba-mosque', 'ziyarats/quba-mosque/quba-3.jpg', 'image/jpeg', 2, '2026-09-09T00:00:00.000Z'),
  ('quba-4', 'quba-mosque', 'ziyarats/quba-mosque/quba-4.jpg', 'image/jpeg', 3, '2026-09-09T00:00:00.000Z'),
  ('quba-5', 'quba-mosque', 'ziyarats/quba-mosque/quba-5.jpg', 'image/jpeg', 4, '2026-09-09T00:00:00.000Z');
