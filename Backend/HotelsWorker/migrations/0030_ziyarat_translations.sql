CREATE TABLE IF NOT EXISTS ziyarat_place_translations (
  place_id TEXT NOT NULL REFERENCES ziyarat_places(id) ON DELETE CASCADE,
  locale TEXT NOT NULL CHECK(locale IN ('ru','uz','uz-cyrl','en')),
  title TEXT NOT NULL DEFAULT '',
  short_description TEXT NOT NULL DEFAULT '',
  long_description TEXT NOT NULL DEFAULT '',
  interesting_facts_json TEXT NOT NULL DEFAULT '[]',
  visit_notes TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY(place_id, locale)
);

CREATE INDEX IF NOT EXISTS idx_ziyarat_place_translations_locale
  ON ziyarat_place_translations(locale, place_id);

INSERT OR REPLACE INTO ziyarat_place_translations (
  place_id, locale, title, short_description, long_description,
  interesting_facts_json, visit_notes, created_at, updated_at
) VALUES
(
  'quba-mosque', 'ru', 'Мечеть Куба',
  'Первая мечеть, основанная в исламе, и одна из важнейших точек зиярата в Медине.',
  'Мечеть Куба тесно связана с хиджрой и ранней мусульманской общиной Медины. Современная мечеть находится на историческом месте и остаётся одной из самых посещаемых точек города.',
  '["Мечеть связана с началом периода жизни Пророка ﷺ в Медине.","Она традиционно считается первой мечетью, основанной в исламе.","Современный комплекс сохраняет связь с историческим местом Куба и принимает большое количество молящихся."]',
  'Основная остановка. Оставьте достаточно времени, чтобы спокойно войти, совершить намаз и собраться с группой перед продолжением маршрута.',
  '2026-09-09T00:00:00.000Z', '2026-09-09T00:00:00.000Z'
),
(
  'quba-mosque', 'uz', 'Qubo masjidi',
  'Islomda barpo etilgan ilk masjid va Madinadagi eng muhim ziyorat maskanlaridan biri.',
  'Qubo masjidi hijrat va Madinadagi ilk musulmon jamoasi bilan chambarchas bog‘liq. Hozirgi masjid tarixiy joyda joylashgan bo‘lib, shaharning eng ko‘p ziyorat qilinadigan maskanlaridan biri bo‘lib qolmoqda.',
  '["Masjid Payg‘ambarimiz ﷺning Madinadagi hayotining boshlanish davri bilan bog‘liq.","U an’anaviy ravishda Islomda barpo etilgan birinchi masjid deb qaraladi.","Zamonaviy majmua tarixiy Qubo maskani bilan bog‘liqlikni saqlab, ko‘plab namozxonlarga xizmat qiladi."]',
  'Asosiy to‘xtash joyi. Ichkariga xotirjam kirish, namoz o‘qish va yo‘nalishni davom ettirishdan oldin guruh bilan yig‘ilish uchun yetarli vaqt ajrating.',
  '2026-09-09T00:00:00.000Z', '2026-09-09T00:00:00.000Z'
),
(
  'quba-mosque', 'uz-cyrl', 'Қубо масжиди',
  'Исломда барпо этилган илк масжид ва Мадинадаги энг муҳим зиёрат масканларидан бири.',
  'Қубо масжиди ҳижрат ва Мадинадаги илк мусулмон жамоаси билан чамбарчас боғлиқ. Ҳозирги масжид тарихий жойда жойлашган бўлиб, шаҳарнинг энг кўп зиёрат қилинадиган масканларидан бири бўлиб қолмоқда.',
  '["Масжид Пайғамбаримиз ﷺнинг Мадинадаги ҳаётининг бошланиш даври билан боғлиқ.","У анъанавий равишда Исломда барпо этилган биринчи масжид деб қаралади.","Замонавий мажмуа тарихий Қубо маскани билан боғлиқликни сақлаб, кўплаб намозхонларга хизмат қилади."]',
  'Асосий тўхташ жойи. Ичкарига хотиржам кириш, намоз ўқиш ва йўналишни давом эттиришдан олдин гуруҳ билан йиғилиш учун етарли вақт ажратинг.',
  '2026-09-09T00:00:00.000Z', '2026-09-09T00:00:00.000Z'
),
(
  'quba-mosque', 'en', 'Quba Mosque',
  'The first mosque established in Islam and one of Madinah’s most important ziyarat stops.',
  'Quba Mosque is closely connected with the Hijrah and the earliest Muslim community in Madinah. The present mosque stands on the historic site and remains one of the city’s most visited places.',
  '["The mosque is connected with the beginning of the Prophet’s ﷺ life in Madinah.","It is traditionally regarded as the first mosque established in Islam.","The modern complex preserves the identity of the historic Quba site while serving large numbers of worshippers."]',
  'Main stop. Allow enough time to enter calmly, pray and regroup with your guide before continuing the route.',
  '2026-09-09T00:00:00.000Z', '2026-09-09T00:00:00.000Z'
);
