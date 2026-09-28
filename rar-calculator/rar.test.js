// Запуск: node rar-calculator/rar.test.js
const assert = require('assert');
const R = require('./rar.js');

let n = 0;
function t(name, fn) { fn(); n++; console.log('ok -', name); }

t('примеры справочника', () => {
  assert.strictEqual(R.compute({ rdw: 14.8, albumin: 38, albuminUnit: 'g/L' }).rarGL, 0.389);
  assert.strictEqual(R.compute({ rdw: 16.2, albumin: 31, albuminUnit: 'g/L' }).rarGL, 0.523);
  assert.strictEqual(R.compute({ rdw: 13.5, albumin: 35, albuminUnit: 'g/L' }).rarGL, 0.386);
});

t('g/dL и g/L дают одно значение, rarGdL = rarGL × 10', () => {
  const a = R.compute({ rdw: 14.8, albumin: 3.8, albuminUnit: 'g/dL' });
  const b = R.compute({ rdw: 14.8, albumin: 38, albuminUnit: 'g/L' });
  assert.strictEqual(a.rarGL, b.rarGL);
  assert.strictEqual(b.rarGdL, 3.89);
});

t('автоопределение единиц', () => {
  assert.strictEqual(R.compute({ rdw: 14, albumin: 3.5, albuminUnit: 'auto' }).albuminUnitUsed, 'g/dL');
  assert.strictEqual(R.compute({ rdw: 14, albumin: 35, albuminUnit: 'auto' }).albuminUnitUsed, 'g/L');
});

t('явно указан g/L, но значение похоже на g/dL → ошибка диапазона', () => {
  const r = R.compute({ rdw: 14, albumin: 3.5, albuminUnit: 'g/L' });
  assert.strictEqual(r.ok, false);
  assert.ok(r.warnings.some(w => w.includes('g/dL')));
});

t('RDW-SD вместо RDW-CV → ошибка', () => {
  const r = R.compute({ rdw: 45, albumin: 38, albuminUnit: 'g/L' });
  assert.strictEqual(r.ok, false);
  assert.ok(r.errors[0].includes('RDW-SD'));
});

t('категории справочника, граница включается в нижнюю', () => {
  const cat = (rdw, alb) => R.compute({ rdw, albumin: alb, albuminUnit: 'g/L' }).category.index;
  assert.strictEqual(cat(13.8, 39), 1);   // 0.354 — «Норма»
  assert.strictEqual(cat(14.7, 35), 1);   // ровно 0.42
  assert.strictEqual(cat(15.4, 32), 2);   // 0.481
  assert.strictEqual(cat(17.2, 26), 3);   // 0.662
  assert.strictEqual(cat(20, 26), 4);     // 0.769
  assert.strictEqual(cat(13, 40), 0);     // 0.325
});

t('пресет Cao 2026: 2 категории, порог 0.318', () => {
  const r = R.compute({ rdw: 13.8, albumin: 39, albuminUnit: 'g/L', tiers: R.PRESETS.cao2026.tiers });
  assert.strictEqual(r.category.count, 2);
  assert.strictEqual(r.category.name, 'Высокий RAR');
});

t('серая зона', () => {
  assert.ok(R.compute({ rdw: 14.6, albumin: 35, albuminUnit: 'g/L' }).category.grayZone); // 0.417
  assert.ok(!R.compute({ rdw: 15, albumin: 40, albuminUnit: 'g/L' }).category.grayZone); // 0.375
});

t('конфаундеры делают результат ненадёжным', () => {
  const r = R.compute({ rdw: 15, albumin: 36, albuminUnit: 'g/L', flags: { transfusion: true } });
  assert.strictEqual(r.ok, true);
  assert.strictEqual(r.reliable, false);
});

t('давность анализов', () => {
  const r = R.compute({ rdw: 15, albumin: 36, albuminUnit: 'g/L', labDate: '2026-09-01', surgeryDate: '2026-09-20' });
  assert.strictEqual(r.labAgeDays, 19);
  assert.ok(r.warnings.some(w => w.includes('14 дней')));
});

t('соображения никогда не содержат назначений доз', () => {
  const r = R.compute({ rdw: 18, albumin: 27, albuminUnit: 'g/L' });
  const text = R.considerations(r).join(' ');
  assert.ok(!/\bmg\b|мг/.test(text));
  assert.ok(text.includes('NRS-2002'));
});

t('«Внимание» (0.42–0.55) уже запускает нутритивный скрининг', () => {
  const r = R.compute({ rdw: 15.4, albumin: 32, albuminUnit: 'g/L' });
  assert.strictEqual(r.category.name, 'Внимание');
  assert.ok(R.considerations(r).join(' ').includes('NRS-2002'));
  const low = R.compute({ rdw: 13.8, albumin: 39, albuminUnit: 'g/L' });
  assert.ok(!R.considerations(low).join(' ').includes('NRS-2002'));
});

console.log(`\n${n} тестов пройдено`);
