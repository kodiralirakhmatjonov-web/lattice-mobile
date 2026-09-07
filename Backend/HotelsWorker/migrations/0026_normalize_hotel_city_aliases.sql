-- Normalize legacy/provider city spellings so every Makkah/Madinah hotel is
-- visible in the same catalog bucket. New writes are normalized by
-- canonicalCity() in the Worker; this migration fixes existing D1 rows.

UPDATE hotels
SET city = 'Makkah'
WHERE lower(trim(city)) LIKE '%makkah%'
   OR lower(trim(city)) LIKE '%mecca%'
   OR city LIKE '%مكة%';

UPDATE hotels
SET city = 'Madinah'
WHERE lower(trim(city)) LIKE '%madinah%'
   OR lower(trim(city)) LIKE '%medina%'
   OR city LIKE '%المدينة%';

-- Keep source metadata aligned as well; this does not change source URLs or
-- any pricing/media data.
UPDATE hotel_sources
SET city = 'Makkah'
WHERE city IS NOT NULL
  AND (
    lower(trim(city)) LIKE '%makkah%'
    OR lower(trim(city)) LIKE '%mecca%'
    OR city LIKE '%مكة%'
  );

UPDATE hotel_sources
SET city = 'Madinah'
WHERE city IS NOT NULL
  AND (
    lower(trim(city)) LIKE '%madinah%'
    OR lower(trim(city)) LIKE '%medina%'
    OR city LIKE '%المدينة%'
  );
