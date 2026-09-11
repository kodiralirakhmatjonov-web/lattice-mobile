# Expedia Price Refresh v2 — 11 сентября 2026

## Что исправлено

Главная цель этой версии — сделать Expedia основным автоматическим источником цены отеля и перестать считать сохранённую старую цену «успешным обновлением».

Найдены четыре практических причины, из-за которых карточка могла оставаться со старой ценой:

1. Expedia Share URL (`expe.onelink.me`) распознавался iOS-импортером, но сервер цен проверял его как обычный `expedia.*` URL и мог упасть **до** перехода на уже сохранённый `canonical_url` конкретного отеля.
2. Сервер фактически проверял один набор дат. Если завтра у отеля нет доступности, обновление завершалось без цены, хотя тот же отель мог продаваться через несколько дней.
3. Browser Run запускался отдельно на один URL и не имел Expedia-логики «любой продаваемый номер этого exact property».
4. При неудачном live refresh API мог вернуть сохранённую stale-цену вместе с `ok:true`. Это позволяло UI выглядеть так, будто цена действительно была обновлена.

## Новая архитектура

`Admin button / 15-min cron → D1 lease → preferred Expedia source → canonical Expedia property → same-property date ladder → SSR/HTML → one Browser Run session if needed → exact property validation → D1 price cache`

### 1. Expedia — предпочтительный источник

Если у одного отеля есть Booking и Expedia, `hotel_price_sources` теперь выбирает Expedia. Миграция `0034_expedia_price_refresh_v2.sql` переводит существующие eligible locks на Expedia без удаления отелей, фотографий или последней принятой цены.

### 2. Жёсткая привязка к конкретному отелю

Идентичность Expedia берётся из `.h<propertyID>.Hotel-Information`. Система не ищет отель по названию и не может принять цену другого property ID. Share URL остаётся provenance; для price refresh используется связанный `canonical_url`, если Share URL сам не содержит property ID.

### 3. Любой номер, но только этого отеля

Benchmark остаётся `1 room / 2 adults / 1 night / USD`. Название room type больше не является обязательным. Если Double Room не продаётся, Browser extractor может принять другой реально продаваемый номер этого же Expedia property. Recommendation / Similar properties / cross-sell блоки исключаются.

### 4. Не только «завтра»

Если валидные будущие даты были импортированы, они проверяются первыми. Затем Expedia проверяется на bounded ladder: `+1, +3, +7, +14, +21, +30` дней. Все URL обязаны сохранить тот же Expedia property ID. Поэтому sold-out на завтра больше не означает, что отель вообще не имеет цены.

### 5. Дешёвый путь перед браузером

Сначала весь same-property ladder проходит через HTTP/SSR parsing. Поддерживаются Expedia room price lockups, явные nightly prices и property-specific FAQ/SSR price text. Только если подтверждённая цена не найдена, включается Cloudflare Browser Run.

### 6. Один браузер на отель

Expedia browser fallback открывает **одну** browser session и в ней проверяет до четырёх same-property date probes. Это существенно дешевле, чем запускать отдельный browser instance на каждую дату.

### 7. Автообновление раз в 48 часов

Подтверждённая цена живёт 48 часов. Cron запускается каждые 15 минут и берёт до 4 due hotels за проход, сначала Expedia и отели без принятой цены. Ошибка не удаляет последнюю рабочую цену: она становится stale, retry назначается через 6 часов.

### 8. Честный ответ кнопки

`ok:true, refreshed:true` теперь означает только одно: **в этом запросе реально получен live provider snapshot и успешно записан в D1**.

- Цена реально изменилась → `changed:true`, UI: `Цена обновилась в Expedia: $old → $new / ночь.`
- Expedia подтвердила ту же цену → `changed:false`, UI: `Цена проверена в Expedia: $X / ночь. Цена не изменилась.`
- Expedia не подтвердила новую цену → `ok:false, refreshed:false`; последняя рабочая цена может остаться на экране, но UI показывает оранжевое предупреждение, а не зелёный success.
- Резкий скачок по-прежнему требует второй близкой live-проверки до замены принятой цены.

## Файлы изменения

- `Backend/HotelsWorker/src/hotel-price-source.js`
- `Backend/HotelsWorker/src/hotel-price.js`
- `Backend/HotelsWorker/src/index.js`
- `Backend/HotelsWorker/migrations/0034_expedia_price_refresh_v2.sql`
- `Sources/Models/HotelModels.swift`
- `Sources/Views/HotelAdminDetailView.swift`
- price refresh tests в `Backend/HotelsWorker/tests/`
- `Backend/HotelsWorker/EXPEDIA-PRICE-REFRESH.md`

## Проверка

Локально выполнены:

- `npm run check` — успешно;
- полный `npm test` — **92/92 tests passed**;
- реальные SQL execution tests на SQLite для 48h TTL, 6h retry, lease, manual override, large-move confirmation и новой Expedia migration;
- отдельные tests для sold-out first date → later same-property date, Expedia date ladder, any-room browser fallback contract, Expedia FAQ rate extraction и truthful refresh response.

Live production Browser Run, ваш реальный D1 и ваши Cloudflare logs из локальной среды недоступны, поэтому финальное production-подтверждение делается после Deploy Hotels Cloud нажатием «Обновить из источника» на одном Expedia-отеле.

## Установка

1. Загрузить patch ZIP в корень `iumrah Business` репозитория, ветка `main`.
2. Дождаться `Apply iumrah Business ZIP update`.
3. Запустить `Deploy iumrah Hotels Cloud`. Workflow сам применит migration `0034` и развернёт Worker.
4. Запустить TestFlight build, потому что контракт ответа и сообщения кнопки изменены также в Swift.
5. Открыть Expedia-отель и нажать `Обновить из источника`.

Новая версия не требует новых secrets. `BROWSER` binding и `@cloudflare/puppeteer` уже присутствуют в текущей архитектуре.
