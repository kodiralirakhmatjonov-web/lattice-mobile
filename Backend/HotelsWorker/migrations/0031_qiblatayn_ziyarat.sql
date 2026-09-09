-- Medina Ziyarat stop #2: Masjid Al-Qiblatayn.
-- Exact map point is stored as coordinates, never resolved by free-text search.
INSERT OR IGNORE INTO ziyarat_places (
  id, route_id, slug, title, title_ar, category, short_description, long_description,
  interesting_facts_json, visit_notes, visit_type, duration_minutes, latitude, longitude,
  address, map_label, route_order, status, created_by, created_at, updated_at
) VALUES (
  'qiblatayn-mosque', 'medina-main', 'qiblatayn-mosque', 'Masjid Al-Qiblatayn', 'مسجد القبلتين', 'mosque',
  'A historic Madinah mosque associated with the change of the qibla toward the Kaaba in Makkah.',
  'Masjid Al-Qiblatayn, the Mosque of the Two Qiblas, is one of Madinah’s best-known historic mosques. The site is associated with the revelation in Qur’an 2:144 directing the qibla toward Al-Masjid Al-Haram in Makkah after Muslims had prayed toward Bayt al-Maqdis. A major rebuilding and expansion was completed in 1408 AH (1987 CE), and the mosque remains an important stop for visitors exploring the Prophetic history of Madinah.',
  '["Its name means Mosque of the Two Qiblas.","The site is associated with the change of the qibla described in Qur’an 2:144.","The mosque was comprehensively rebuilt and expanded in 1408 AH (1987 CE), while preserving its historic significance."]',
  'Main stop. Plan about 20–30 minutes. Enter respectfully, account for prayer times and crowding, and regroup at the guide’s meeting point before continuing.',
  'enter', 30, 24.484087, 39.578907,
  'Khalid Ibn Al Walid Rd, Al Qiblatayn, Madinah 42312, Saudi Arabia',
  'Masjid Al-Qiblatayn · exact point', 2, 'published', 'seed',
  '2026-09-09T12:30:00.000Z', '2026-09-09T12:30:00.000Z'
);

INSERT OR IGNORE INTO ziyarat_images (
  id, place_id, object_key, content_type, byte_size, width, height, position, created_at
) VALUES
  ('qiblatayn-1', 'qiblatayn-mosque', 'ziyarats/qiblatayn-mosque/qiblatayn-1.jpg', 'image/jpeg', 459066, 1254, 1254, 0, '2026-09-09T12:30:00.000Z'),
  ('qiblatayn-2', 'qiblatayn-mosque', 'ziyarats/qiblatayn-mosque/qiblatayn-2.jpg', 'image/jpeg', 744554, 1254, 1254, 1, '2026-09-09T12:30:00.000Z'),
  ('qiblatayn-3', 'qiblatayn-mosque', 'ziyarats/qiblatayn-mosque/qiblatayn-3.jpg', 'image/jpeg', 433375, 1254, 1254, 2, '2026-09-09T12:30:00.000Z'),
  ('qiblatayn-4', 'qiblatayn-mosque', 'ziyarats/qiblatayn-mosque/qiblatayn-4.jpg', 'image/jpeg', 508013, 1254, 1254, 3, '2026-09-09T12:30:00.000Z'),
  ('qiblatayn-5', 'qiblatayn-mosque', 'ziyarats/qiblatayn-mosque/qiblatayn-5.jpg', 'image/jpeg', 475086, 1254, 1254, 4, '2026-09-09T12:30:00.000Z');

INSERT OR REPLACE INTO ziyarat_place_translations (
  place_id, locale, title, short_description, long_description,
  interesting_facts_json, visit_notes, created_at, updated_at
) VALUES
(
  'qiblatayn-mosque', 'ru', 'Мечеть Киблатайн',
  'Историческая мечеть Медины, связанная с изменением киблы — направления молитвы — в сторону Каабы в Мекке.',
  'Мечеть Киблатайн («Мечеть двух кибл») — одна из известных исторических мечетей Медины. С этим местом связывают ниспослание аята 2:144, после которого направление молитвы было обращено к Аль-Масджид аль-Харам в Мекке вместо Байт аль-Макдис. В 1408 г. х. (1987) мечеть была масштабно перестроена и расширена. Сегодня это важная точка маршрута по местам, связанным с сирой Пророка ﷺ в Медине.',
  '["Название означает «Мечеть двух кибл».","Место связано с изменением киблы, описанным в Коране 2:144.","В 1408 г. х. (1987) мечеть была масштабно перестроена и расширена, сохранив историческое значение места."]',
  'Основная остановка. Обычно достаточно 20–30 минут. Учитывайте время намаза и загруженность, соблюдайте правила мечети и перед продолжением маршрута соберитесь в точке, указанной гидом.',
  '2026-09-09T12:30:00.000Z', '2026-09-09T12:30:00.000Z'
),
(
  'qiblatayn-mosque', 'uz', 'Qiblatayn masjidi',
  'Madinadagi tarixiy masjid bo‘lib, qiblaning Makkadagi Ka’ba tomon o‘zgartirilishi bilan bog‘liq.',
  'Qiblatayn masjidi (“Ikki qibla masjidi”) Madinadagi mashhur tarixiy masjidlardan biridir. Bu joy Qur’onning 2:144 oyati nozil bo‘lib, namoz yo‘nalishi Bayt al-Maqdisdan Makkadagi Al-Masjid al-Harom tomonga o‘zgartirilgani bilan bog‘lanadi. Masjid 1408 hijriy (1987) yilda keng ko‘lamda qayta qurilib, kengaytirilgan. Bugun u Madinadagi siyrat bilan bog‘liq muhim ziyorat nuqtalaridan biridir.',
  '["Masjid nomi “Ikki qibla masjidi” degan ma’noni anglatadi.","Bu joy Qur’on 2:144 da bayon qilingan qiblaning o‘zgarishi bilan bog‘liq.","Masjid 1408 hijriy (1987) yilda katta hajmda qayta qurilib va kengaytirilib, tarixiy ahamiyatini saqlab qolgan."]',
  'Asosiy to‘xtash joyi. Odatda 20–30 daqiqa yetarli. Namoz va gavjumlik vaqtini hisobga oling, masjid tartiblariga rioya qiling va yo‘lni davom ettirishdan oldin gid belgilagan uchrashuv nuqtasida yig‘iling.',
  '2026-09-09T12:30:00.000Z', '2026-09-09T12:30:00.000Z'
),
(
  'qiblatayn-mosque', 'uz-cyrl', 'Қиблатайн масжиди',
  'Мадинадаги тарихий масжид бўлиб, қибланинг Маккадаги Каъба томон ўзгартирилиши билан боғлиқ.',
  'Қиблатайн масжиди («Икки қибла масжиди») Мадинадаги машҳур тарихий масжидлардан биридир. Бу жой Қуръоннинг 2:144 ояти нозил бўлиб, намоз йўналиши Байт ал-Мақдисдан Маккадаги Ал-Масжид ал-Ҳаром томон ўзгартирилгани билан боғланади. Масжид 1408 ҳижрий (1987) йилда кенг кўламда қайта қурилиб, кенгайтирилган. Бугун у Мадинадаги сийрат билан боғлиқ муҳим зиёрат нуқталаридан биридир.',
  '["Масжид номи «Икки қибла масжиди» деган маънони англатади.","Бу жой Қуръон 2:144 да баён қилинган қибланинг ўзгариши билан боғлиқ.","Масжид 1408 ҳижрий (1987) йилда катта ҳажмда қайта қурилиб ва кенгайтирилиб, тарихий аҳамиятини сақлаб қолган."]',
  'Асосий тўхташ жойи. Одатда 20–30 дақиқа етарли. Намоз ва гавжумлик вақтини ҳисобга олинг, масжид тартибларига риоя қилинг ва йўлни давом эттиришдан олдин гид белгилаган учрашув нуқтасида йиғилинг.',
  '2026-09-09T12:30:00.000Z', '2026-09-09T12:30:00.000Z'
),
(
  'qiblatayn-mosque', 'en', 'Masjid Al-Qiblatayn',
  'A historic Madinah mosque associated with the change of the qibla toward the Kaaba in Makkah.',
  'Masjid Al-Qiblatayn, the Mosque of the Two Qiblas, is one of Madinah’s best-known historic mosques. The site is associated with the revelation in Qur’an 2:144 directing the qibla toward Al-Masjid Al-Haram in Makkah after Muslims had prayed toward Bayt al-Maqdis. A major rebuilding and expansion was completed in 1408 AH (1987 CE), and the mosque remains an important stop for visitors exploring the Prophetic history of Madinah.',
  '["Its name means Mosque of the Two Qiblas.","The site is associated with the change of the qibla described in Qur’an 2:144.","The mosque was comprehensively rebuilt and expanded in 1408 AH (1987 CE), while preserving its historic significance."]',
  'Main stop. Plan about 20–30 minutes. Enter respectfully, account for prayer times and crowding, and regroup at the guide’s meeting point before continuing.',
  '2026-09-09T12:30:00.000Z', '2026-09-09T12:30:00.000Z'
);
