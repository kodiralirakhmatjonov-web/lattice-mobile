-- Booking experience v2: traveler relationship labels and supplier references.
ALTER TABLE booking_travelers ADD COLUMN relationship TEXT NOT NULL DEFAULT 'other';
ALTER TABLE booking_travel_documents ADD COLUMN booking_reference TEXT NOT NULL DEFAULT '';

UPDATE booking_travelers
SET relationship = CASE
  WHEN position = 1 THEN 'self'
  WHEN traveler_type IN ('child','infant') THEN 'child'
  ELSE 'other'
END
WHERE relationship = 'other';

-- Only fields required for flight/hotel fulfilment remain completion blockers.
UPDATE booking_travelers
SET completed = CASE WHEN
  TRIM(COALESCE(first_name,'')) <> '' AND
  TRIM(COALESCE(last_name,'')) <> '' AND
  TRIM(COALESCE(gender,'')) <> '' AND
  TRIM(COALESCE(date_of_birth,'')) <> '' AND
  TRIM(COALESCE(nationality,'')) <> '' AND
  TRIM(COALESCE(passport_number,'')) <> '' AND
  TRIM(COALESCE(passport_expiry_date,'')) <> '' AND
  TRIM(COALESCE(passport_issuing_country,'')) <> '' AND
  passport_object_key IS NOT NULL
THEN 1 ELSE 0 END;
