import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

const worker = fs.readFileSync(new URL('../src/index.js', import.meta.url), 'utf8');
const migration = fs.readFileSync(new URL('../migrations/0029_payment_templates.sql', import.meta.url), 'utf8');
const hotelReview = fs.readFileSync(new URL('../../../Sources/Hotels/HotelReviewView.swift', import.meta.url), 'utf8');
const importer = fs.readFileSync(new URL('../../../Sources/Hotels/HotelImportCoordinator.swift', import.meta.url), 'utf8');
const sidebar = fs.readFileSync(new URL('../../../Sources/Views/BusinessSidebar.swift', import.meta.url), 'utf8');
const payments = fs.readFileSync(new URL('../../../Sources/Views/PaymentsView.swift', import.meta.url), 'utf8');
const checkout = fs.readFileSync(new URL('../../../Sources/Views/BookingCheckoutAdminCard.swift', import.meta.url), 'utf8');
const api = fs.readFileSync(new URL('../../../Sources/Networking/APIClient.swift', import.meta.url), 'utf8');
const employees = fs.readFileSync(new URL('../../../Sources/Views/EmployeesView.swift', import.meta.url), 'utf8');
const profile = fs.readFileSync(new URL('../../../Sources/Views/ProfileView.swift', import.meta.url), 'utf8');
const privateImage = fs.readFileSync(new URL('../../../Sources/Views/BusinessPrivateImage.swift', import.meta.url), 'utf8');

test('Booking importer allows an admin-entered USD nightly price without changing Expedia rules', () => {
  assert.match(importer, /setManualBookingImportPriceUSD/);
  assert.match(importer, /method: "booking-admin-manual-usd"/);
  assert.match(importer, /currency: "USD"/);
  assert.match(hotelReview, /Ручная цена Booking · USD за 1 ночь/);
  assert.match(hotelReview, /Использовать эту цену и разрешить публикацию/);
  assert.match(hotelReview, /let requiredImageCount = isBooking \? 1 : 4/);
  assert.match(worker, /const requiredImageCount = isBookingImport \? 1 : 4/);
  assert.match(worker, /normalizedHotelPriceProvider\(source\?\.provider, source\?\.sourceURL\) === 'Booking'/);
});

test('Payments is a persistent Business sidebar section with reusable booking templates', () => {
  assert.match(migration, /CREATE TABLE IF NOT EXISTS payment_templates/);
  assert.match(worker, /parts\[0\] === 'payment-templates'/);
  assert.match(worker, /applyPaymentTemplateToBooking/);
  assert.match(worker, /payment-qr\/\$\{bookingID\}/);
  assert.match(sidebar, /case \.payments: PaymentsView\(\)/);
  assert.match(sidebar, /sidebarButton\("Payments"/);
  assert.match(payments, /Сохранённые реквизиты iumrah Business/);
  assert.match(checkout, /Вставить сохранённые реквизиты/);
  assert.match(checkout, /applyPaymentTemplate\(templateID: template\.id, bookingID: bookingID\)/);
});

test('employee photos are loaded through authenticated Business media requests, not bare AsyncImage URLs', () => {
  assert.match(privateImage, /APIClient\.shared\.privateMedia\(path: path\)/);
  assert.match(api, /URL\(string: path, relativeTo: AppConfig\.apiBaseURL\)/);
  assert.match(employees, /BusinessPrivateImage\(path: path\)/);
  assert.match(profile, /BusinessPrivateImage\(path: path\)/);
  assert.doesNotMatch(employees, /AsyncImage\(url: url\)/);
  assert.doesNotMatch(profile, /AsyncImage\(url: url\)/);
  assert.match(worker, /serveAdminTeamMemberPhoto/);
});
