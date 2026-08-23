ALTER TABLE hotels ADD COLUMN property_type TEXT;
ALTER TABLE hotels ADD COLUMN rating REAL;
ALTER TABLE hotels ADD COLUMN rating_scale REAL;
ALTER TABLE hotels ADD COLUMN review_count INTEGER;
ALTER TABLE hotels ADD COLUMN check_in TEXT;
ALTER TABLE hotels ADD COLUMN check_out TEXT;
ALTER TABLE hotels ADD COLUMN policies_json TEXT NOT NULL DEFAULT '[]';

ALTER TABLE hotel_rooms ADD COLUMN description TEXT;
ALTER TABLE hotel_rooms ADD COLUMN amenities_json TEXT NOT NULL DEFAULT '[]';

ALTER TABLE hotel_sources ADD COLUMN city TEXT;
ALTER TABLE hotel_sources ADD COLUMN country TEXT;
ALTER TABLE hotel_sources ADD COLUMN property_type TEXT;
ALTER TABLE hotel_sources ADD COLUMN rating_scale REAL;
ALTER TABLE hotel_sources ADD COLUMN review_count INTEGER;
ALTER TABLE hotel_sources ADD COLUMN check_in TEXT;
ALTER TABLE hotel_sources ADD COLUMN check_out TEXT;
ALTER TABLE hotel_sources ADD COLUMN room_details_json TEXT NOT NULL DEFAULT '[]';
ALTER TABLE hotel_sources ADD COLUMN policies_json TEXT NOT NULL DEFAULT '[]';

ALTER TABLE hotel_images ADD COLUMN label TEXT;
ALTER TABLE hotel_images ADD COLUMN room_name TEXT;
