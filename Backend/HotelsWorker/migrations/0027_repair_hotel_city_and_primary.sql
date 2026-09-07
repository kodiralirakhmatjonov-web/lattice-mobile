PRAGMA foreign_keys = ON;

-- Repair legacy hotel rows whose provider wrote a neighbourhood, alternate
-- locality, empty-ish value or malformed city.  We infer only Makkah/Madinah
-- from strong evidence: hotel/source text, source URL, or coordinates close to
-- the city centre.  This prevents valid rows from disappearing from the two
-- Business catalog tabs and from Primary Hotel queries.

UPDATE hotels
SET city = 'Makkah',
    updated_at = strftime('%Y-%m-%dT%H:%M:%fZ','now')
WHERE id IN (
  SELECT h.id
  FROM hotels h
  WHERE
    LOWER(REPLACE(REPLACE(COALESCE(h.city,''),'-',' '),'_',' ')) LIKE '%makkah%'
    OR LOWER(REPLACE(REPLACE(COALESCE(h.city,''),'-',' '),'_',' ')) LIKE '%mecca%'
    OR COALESCE(h.city,'') LIKE '%مكة%'
    OR LOWER(COALESCE(h.name,'')) LIKE '%makkah%'
    OR LOWER(COALESCE(h.name,'')) LIKE '%mecca%'
    OR COALESCE(h.name,'') LIKE '%مكة%'
    OR LOWER(COALESCE(h.address,'')) LIKE '%makkah%'
    OR LOWER(COALESCE(h.address,'')) LIKE '%mecca%'
    OR COALESCE(h.address,'') LIKE '%مكة%'
    OR (
      h.latitude IS NOT NULL AND h.longitude IS NOT NULL
      AND ((h.latitude - 21.4225) * (h.latitude - 21.4225) + (h.longitude - 39.8262) * (h.longitude - 39.8262)) <= 0.20
    )
    OR EXISTS (
      SELECT 1 FROM hotel_sources hs
      WHERE hs.hotel_id = h.id AND (
        LOWER(COALESCE(hs.city,'')) LIKE '%makkah%'
        OR LOWER(COALESCE(hs.city,'')) LIKE '%mecca%'
        OR COALESCE(hs.city,'') LIKE '%مكة%'
        OR LOWER(COALESCE(hs.source_name,'')) LIKE '%makkah%'
        OR LOWER(COALESCE(hs.source_name,'')) LIKE '%mecca%'
        OR LOWER(COALESCE(hs.address,'')) LIKE '%makkah%'
        OR LOWER(COALESCE(hs.address,'')) LIKE '%mecca%'
        OR LOWER(COALESCE(hs.source_url,'')) LIKE '%makkah%'
        OR LOWER(COALESCE(hs.source_url,'')) LIKE '%mecca%'
        OR (hs.latitude IS NOT NULL AND hs.longitude IS NOT NULL
            AND ((hs.latitude - 21.4225) * (hs.latitude - 21.4225) + (hs.longitude - 39.8262) * (hs.longitude - 39.8262)) <= 0.20)
      )
    )
);

UPDATE hotels
SET city = 'Madinah',
    updated_at = strftime('%Y-%m-%dT%H:%M:%fZ','now')
WHERE city <> 'Makkah'
  AND id IN (
  SELECT h.id
  FROM hotels h
  WHERE
    LOWER(REPLACE(REPLACE(COALESCE(h.city,''),'-',' '),'_',' ')) LIKE '%madinah%'
    OR LOWER(REPLACE(REPLACE(COALESCE(h.city,''),'-',' '),'_',' ')) LIKE '%medina%'
    OR COALESCE(h.city,'') LIKE '%المدينة%'
    OR LOWER(COALESCE(h.name,'')) LIKE '%madinah%'
    OR LOWER(COALESCE(h.name,'')) LIKE '%medina%'
    OR COALESCE(h.name,'') LIKE '%المدينة%'
    OR LOWER(COALESCE(h.address,'')) LIKE '%madinah%'
    OR LOWER(COALESCE(h.address,'')) LIKE '%medina%'
    OR COALESCE(h.address,'') LIKE '%المدينة%'
    OR (
      h.latitude IS NOT NULL AND h.longitude IS NOT NULL
      AND ((h.latitude - 24.4672) * (h.latitude - 24.4672) + (h.longitude - 39.6111) * (h.longitude - 39.6111)) <= 0.20
    )
    OR EXISTS (
      SELECT 1 FROM hotel_sources hs
      WHERE hs.hotel_id = h.id AND (
        LOWER(COALESCE(hs.city,'')) LIKE '%madinah%'
        OR LOWER(COALESCE(hs.city,'')) LIKE '%medina%'
        OR COALESCE(hs.city,'') LIKE '%المدينة%'
        OR LOWER(COALESCE(hs.source_name,'')) LIKE '%madinah%'
        OR LOWER(COALESCE(hs.source_name,'')) LIKE '%medina%'
        OR LOWER(COALESCE(hs.address,'')) LIKE '%madinah%'
        OR LOWER(COALESCE(hs.address,'')) LIKE '%medina%'
        OR LOWER(COALESCE(hs.source_url,'')) LIKE '%madinah%'
        OR LOWER(COALESCE(hs.source_url,'')) LIKE '%medina%'
        OR (hs.latitude IS NOT NULL AND hs.longitude IS NOT NULL
            AND ((hs.latitude - 24.4672) * (hs.latitude - 24.4672) + (hs.longitude - 39.6111) * (hs.longitude - 39.6111)) <= 0.20)
      )
    )
);

-- Primary assignments must use the same canonical city as the hotel row or the
-- consumer query can miss a perfectly valid Primary Hotel.
INSERT OR IGNORE INTO primary_hotels (city, star_category, position, hotel_id, created_at, updated_at)
SELECT h.city, p.star_category, p.position, p.hotel_id, p.created_at, strftime('%Y-%m-%dT%H:%M:%fZ','now')
FROM primary_hotels p
JOIN hotels h ON h.id = p.hotel_id
WHERE h.city IN ('Makkah','Madinah')
  AND LOWER(COALESCE(p.city,'')) <> LOWER(h.city);

DELETE FROM primary_hotels
WHERE EXISTS (
  SELECT 1 FROM hotels h
  WHERE h.id = primary_hotels.hotel_id
    AND h.city IN ('Makkah','Madinah')
    AND LOWER(COALESCE(primary_hotels.city,'')) <> LOWER(h.city)
);
