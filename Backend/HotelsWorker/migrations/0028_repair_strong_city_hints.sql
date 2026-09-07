-- Repair only strong Makkah/Madinah locality hints that are safe to infer.
-- Ambiguous rows remain visible in Business and can be corrected manually.

UPDATE hotels
SET city='Makkah', updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now')
WHERE LOWER(COALESCE(city,'')) NOT IN ('makkah','madinah')
  AND (
    LOWER(COALESCE(address,'')) LIKE '%ajyad%'
    OR LOWER(COALESCE(name,'')) LIKE '%ajyad%'
    OR LOWER(COALESCE(address,'')) LIKE '%jabal omar%'
    OR LOWER(COALESCE(name,'')) LIKE '%jabal omar%'
    OR LOWER(COALESCE(address,'')) LIKE '%ibrahim al khalil%'
  );

UPDATE hotels
SET city='Madinah', updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now')
WHERE LOWER(COALESCE(city,'')) NOT IN ('makkah','madinah')
  AND (
    LOWER(COALESCE(address,'')) LIKE '%abi ayoub al ansari%'
    OR LOWER(COALESCE(address,'')) LIKE '%abi ayyub al ansari%'
    OR LOWER(COALESCE(address,'')) LIKE '%abu ayoub al ansari%'
    OR LOWER(COALESCE(address,'')) LIKE '%abu ayyub al ansari%'
    OR LOWER(COALESCE(address,'')) LIKE '%masjid an nabawi%'
    OR LOWER(COALESCE(address,'')) LIKE '%masjid al nabawi%'
  );

-- Never keep a Primary assignment under a city that no longer matches its hotel.
DELETE FROM primary_hotels
WHERE EXISTS (
  SELECT 1 FROM hotels h
  WHERE h.id=primary_hotels.hotel_id
    AND h.city IN ('Makkah','Madinah')
    AND LOWER(primary_hotels.city)<>LOWER(h.city)
);
