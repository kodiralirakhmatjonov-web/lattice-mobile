PRAGMA foreign_keys = ON;

-- Manual iumrah Security review queue. Client submissions stay pending here
-- until a staff member verifies the passport photo against the entered data.
CREATE TABLE IF NOT EXISTS iumrah_security_submissions (
  id TEXT PRIMARY KEY,
  booking_id TEXT NOT NULL UNIQUE,
  pilgrim_id INTEGER,
  first_name TEXT NOT NULL DEFAULT '',
  last_name TEXT NOT NULL DEFAULT '',
  passport_number TEXT NOT NULL DEFAULT '',
  passport_last4 TEXT NOT NULL DEFAULT '',
  identity_fingerprint TEXT NOT NULL DEFAULT '',
  passport_object_key TEXT,
  passport_content_type TEXT,
  status TEXT NOT NULL DEFAULT 'draft'
    CHECK (status IN ('draft','submitted','under_review','confirmed','rejected','needs_resubmission')),
  submitted_at TEXT,
  reviewed_at TEXT,
  reviewed_by TEXT,
  review_note TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  FOREIGN KEY (pilgrim_id) REFERENCES pilgrims(id) ON DELETE SET NULL
);
CREATE INDEX IF NOT EXISTS idx_iumrah_security_submission_status
ON iumrah_security_submissions(status, submitted_at DESC);
CREATE INDEX IF NOT EXISTS idx_iumrah_security_submission_identity
ON iumrah_security_submissions(identity_fingerprint, status);

-- Final anti-fraud identity registry. Only Business manual approval creates a
-- confirmed row. Gift Card redemption reads this registry, never raw form data.
CREATE TABLE IF NOT EXISTS iumrah_identity_confirmations (
  id TEXT PRIMARY KEY,
  booking_id TEXT NOT NULL UNIQUE,
  identity_fingerprint TEXT NOT NULL,
  first_name TEXT NOT NULL,
  last_name TEXT NOT NULL,
  passport_last4 TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'confirmed'
    CHECK (status IN ('submitted','manual_review','confirmed','rejected')),
  verification_method TEXT NOT NULL DEFAULT 'business_manual_passport_review',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_iumrah_identity_fingerprint
ON iumrah_identity_confirmations(identity_fingerprint, updated_at DESC);
