PRAGMA foreign_keys = ON;

-- Reusable payment details managed in iumrah Business. Templates are copied into
-- a booking when selected; the booking keeps its own snapshot and QR object.
CREATE TABLE IF NOT EXISTS payment_templates (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  visa_card_number TEXT NOT NULL DEFAULT '',
  visa_holder TEXT NOT NULL DEFAULT '',
  payme_qr_object_key TEXT,
  payme_qr_content_type TEXT,
  humo_card_number TEXT NOT NULL DEFAULT '',
  humo_holder TEXT NOT NULL DEFAULT '',
  instructions TEXT NOT NULL DEFAULT '',
  sort_order INTEGER NOT NULL DEFAULT 0,
  created_by TEXT,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
CREATE INDEX IF NOT EXISTS idx_payment_templates_sort ON payment_templates(sort_order, updated_at DESC);
