ALTER TABLE hotel_images ADD COLUMN category TEXT NOT NULL DEFAULT 'other';
CREATE INDEX IF NOT EXISTS idx_hotel_images_category ON hotel_images(hotel_id, category, position);
