PRAGMA foreign_keys = ON;

-- Explicit one-time clean start requested for the hotel catalog. This migration
-- is tracked by D1 and therefore cannot repeat on later deployments.
-- Foreign keys cascade rooms, sources, images metadata, translations, import
-- jobs, Primary Hotel rows and price cache; booking assignments become NULL.
INSERT OR IGNORE INTO catalog_maintenance_tasks (
  id, status, cutoff_at, created_at, updated_at
) VALUES (
  'reset-hotel-media-clean-start-v1',
  'pending',
  strftime('%Y-%m-%dT%H:%M:%fZ','now'),
  strftime('%Y-%m-%dT%H:%M:%fZ','now'),
  strftime('%Y-%m-%dT%H:%M:%fZ','now')
);

DELETE FROM hotels;
