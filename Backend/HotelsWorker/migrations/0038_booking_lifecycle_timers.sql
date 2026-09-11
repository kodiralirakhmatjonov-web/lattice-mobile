-- Canonical booking lifecycle timers shared by iumrah Business and the client app.
-- All timestamps are absolute UTC deadlines; apps only render countdowns.
ALTER TABLE pilgrim_trips ADD COLUMN availability_started_at TEXT;
ALTER TABLE pilgrim_trips ADD COLUMN availability_deadline_at TEXT;
ALTER TABLE pilgrim_trips ADD COLUMN price_lock_started_at TEXT;
ALTER TABLE pilgrim_trips ADD COLUMN price_lock_expires_at TEXT;
ALTER TABLE pilgrim_trips ADD COLUMN payment_received_at TEXT;
ALTER TABLE pilgrim_trips ADD COLUMN payment_confirmation_deadline_at TEXT;
ALTER TABLE pilgrim_trips ADD COLUMN documents_started_at TEXT;
ALTER TABLE pilgrim_trips ADD COLUMN documents_deadline_at TEXT;

-- Existing bookings receive deterministic deadlines based on their canonical
-- creation/status-history timestamps. These values are historical aids only;
-- no booking status is changed by this migration.
UPDATE pilgrim_trips
SET availability_started_at = COALESCE(availability_started_at, created_at),
    availability_deadline_at = COALESCE(
      availability_deadline_at,
      strftime('%Y-%m-%dT%H:%M:%fZ', julianday(created_at) + (6.0 / 24.0))
    )
WHERE status = 'availability_check';

UPDATE pilgrim_trips
SET price_lock_started_at = COALESCE(
      price_lock_started_at,
      (SELECT MAX(h.created_at) FROM booking_status_history h WHERE h.booking_id = pilgrim_trips.booking_id AND h.new_status = 'payment_pending'),
      updated_at,
      created_at
    )
WHERE status = 'payment_pending';

UPDATE pilgrim_trips
SET price_lock_expires_at = COALESCE(
      price_lock_expires_at,
      strftime('%Y-%m-%dT%H:%M:%fZ', julianday(price_lock_started_at) + (30.0 / 1440.0))
    )
WHERE price_lock_started_at IS NOT NULL;

UPDATE pilgrim_trips
SET payment_received_at = COALESCE(
      payment_received_at,
      (SELECT MIN(r.created_at) FROM booking_payment_receipts r WHERE r.booking_id = pilgrim_trips.booking_id)
    )
WHERE EXISTS (SELECT 1 FROM booking_payment_receipts r WHERE r.booking_id = pilgrim_trips.booking_id);

UPDATE pilgrim_trips
SET payment_confirmation_deadline_at = COALESCE(
      payment_confirmation_deadline_at,
      strftime('%Y-%m-%dT%H:%M:%fZ', julianday(payment_received_at) + (10.0 / 1440.0))
    )
WHERE payment_received_at IS NOT NULL;

UPDATE pilgrim_trips
SET documents_started_at = COALESCE(
      documents_started_at,
      (SELECT MAX(h.created_at) FROM booking_status_history h WHERE h.booking_id = pilgrim_trips.booking_id AND h.new_status = 'booking_confirmed'),
      CASE WHEN status IN ('booking_confirmed','ready_to_travel','in_trip','completed') THEN updated_at END
    )
WHERE status IN ('booking_confirmed','ready_to_travel','in_trip','completed');

UPDATE pilgrim_trips
SET documents_deadline_at = COALESCE(
      documents_deadline_at,
      strftime('%Y-%m-%dT%H:%M:%fZ', julianday(documents_started_at) + 1.0)
    )
WHERE documents_started_at IS NOT NULL;
