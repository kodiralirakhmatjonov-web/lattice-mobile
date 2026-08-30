CREATE TABLE IF NOT EXISTS booking_pricing_overrides (
  booking_id TEXT PRIMARY KEY,
  currency TEXT NOT NULL DEFAULT 'USD',
  components_json TEXT NOT NULL DEFAULT '[]',
  markup_rate REAL NOT NULL DEFAULT 0.50,
  payment_fee_rate REAL NOT NULL DEFAULT 0.02,
  supplier_cost_usd REAL NOT NULL DEFAULT 0,
  markup_amount_usd REAL NOT NULL DEFAULT 0,
  subtotal_after_markup_usd REAL NOT NULL DEFAULT 0,
  payment_fee_amount_usd REAL NOT NULL DEFAULT 0,
  calculated_selling_price_usd REAL NOT NULL DEFAULT 0,
  public_price_per_pilgrim_usd REAL NOT NULL DEFAULT 0,
  public_total_usd REAL NOT NULL DEFAULT 0,
  rounding_difference_usd REAL NOT NULL DEFAULT 0,
  estimated_profit_usd REAL NOT NULL DEFAULT 0,
  traveler_count INTEGER NOT NULL DEFAULT 1,
  updated_by TEXT,
  updated_at TEXT NOT NULL
);
