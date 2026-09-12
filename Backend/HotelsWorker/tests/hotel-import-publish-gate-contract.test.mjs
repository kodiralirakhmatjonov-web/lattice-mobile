import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

const worker = fs.readFileSync(new URL('../src/index.js', import.meta.url), 'utf8');
const review = fs.readFileSync(new URL('../../../Sources/Hotels/HotelReviewView.swift', import.meta.url), 'utf8');
const models = fs.readFileSync(new URL('../../../Sources/Models/HotelModels.swift', import.meta.url), 'utf8');

test('Hotel Importer publishes with one general hotel photo and confirmed rooms; room photos and price are optional', () => {
  assert.match(models, /var selectedHotelImages:[\s\S]*\$0\.kind != \.room && \$0\.kind != \.bathroom/);
  assert.match(review, /let canPublish = !draft\.sources\.isEmpty && !draft\.selectedHotelImages\.isEmpty && !draft\.rooms\.isEmpty/);
  assert.doesNotMatch(review, /canPublish[^\n]*importedPrice/);
  assert.match(worker, /HOTEL_PHOTO_REQUIRED/);
  assert.match(worker, /hotelLevelImages\.length > 0 && plausibleRooms\.length > 0/);
  assert.doesNotMatch(worker, /trustedImageCount >= requiredImageCount/);
});

test('Import finalization requires one stored general hotel photo but no room-specific media quota', () => {
  assert.match(worker, /category NOT IN \('room','bathroom','other'\)/);
  assert.match(worker, /const mediaReady = stored > 0 && hotelPhotoCount > 0 && coverCount > 0/);
  assert.doesNotMatch(worker, /const requiredImages = Math\.min\(4, total\)/);
  assert.match(worker, /photo rooms are optional|room photos are optional|фото комнат/iu);
});
