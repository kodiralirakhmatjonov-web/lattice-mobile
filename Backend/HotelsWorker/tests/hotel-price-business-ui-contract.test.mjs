import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

const view = fs.readFileSync(new URL('../../../Sources/Views/HotelAdminDetailView.swift', import.meta.url), 'utf8');

test('hotel card shows stale/failed source price as not updated', () => {
  assert.match(view, /case "stale": return "Цена не обновилась"/);
  assert.match(view, /case "failed": return "Цена не обновилась"/);
  assert.match(view, /Цена не обновилась\. Показана последняя подтверждённая цена\./);
  assert.match(view, /Color\.orange/);
});

test('hotel card renders source refresh time in Tashkent timezone', () => {
  assert.match(view, /TimeZone\(identifier: "Asia\/Tashkent"\)/);
  assert.match(view, /Последнее обновление:/);
  assert.match(view, /Источник проверен:/);
});
