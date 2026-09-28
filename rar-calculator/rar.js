/*
 * RAR (RDW / Albumin) — расчётное ядро калькулятора.
 * Без зависимостей; работает в браузере (window.RAR) и в Node (module.exports).
 *
 * Две конвенции записи RAR в литературе:
 *   - "g/L":  RDW(%) / Albumin(g/L)   → типичные значения 0.25–0.70 (справочник, cutoff 0.42)
 *   - "g/dL": RDW(%) / Albumin(g/dL)  → типичные значения 2.5–7.0  (большинство публикаций)
 * Значения отличаются ровно в 10 раз. Путаница единиц — главная ошибка при внедрении.
 */
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.RAR = factory();
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  // Пресеты порогов. Все хранятся в конвенции g/L.
  var PRESETS = {
    handbook: {
      label: 'Справочник (0.42, 5 категорий) — не валидирован',
      tiers: [0.35, 0.42, 0.55, 0.70],
      source: 'Практический справочник «RAR в украинской хирургической клинике», 2026'
    },
    cao2026: {
      label: 'Cao et al., Cancer Med 2026 (3.18 в g/dL = 0.318 в g/L)',
      tiers: [0.318],
      source: 'Cao et al. Preoperative RDW–Albumin Ratio as a Prognostic Biomarker in Gastric Cancer Surgery. Cancer Med. 2026;15(9):e72197. doi:10.1002/cam4.72197'
    }
  };

  var CATEGORY_NAMES = {
    5: ['Оптимально', 'Норма', 'Внимание', 'Высокий', 'Критический'],
    2: ['Низкий RAR', 'Высокий RAR']
  };

  function round(x, d) { var p = Math.pow(10, d); return Math.round(x * p) / p; }

  /** Нормализует альбумин в g/L. unit: 'g/L' | 'g/dL' | 'auto'. */
  function albuminToGL(value, unit) {
    var v = Number(value);
    if (!isFinite(v) || v <= 0) return { ok: false, error: 'Альбумин должен быть положительным числом' };
    var detected = unit;
    if (unit === 'auto') detected = v < 10 ? 'g/dL' : 'g/L';
    var gl = detected === 'g/dL' ? v * 10 : v;
    var warn = [];
    if (unit === 'g/L' && v < 10) warn.push('Альбумин < 10 g/L — вероятно, введено значение в g/dL. Проверьте единицы.');
    if (unit === 'g/dL' && v >= 10) warn.push('Альбумин ≥ 10 g/dL невозможен — вероятно, значение в g/L.');
    return { ok: true, gl: gl, unit: detected, autoDetected: unit === 'auto', warnings: warn };
  }

  /** Проверки правдоподобия и конфаундеров. flags — объект с булевыми полями. */
  function checks(rdw, albGL, flags, labAgeDays) {
    var errors = [], warnings = [];
    if (!isFinite(rdw) || rdw <= 0) errors.push('RDW должен быть положительным числом');
    else {
      if (rdw > 30) errors.push('RDW > 30 — похоже на RDW-SD (фл), а нужен RDW-CV (%).');
      else if (rdw < 10) warnings.push('RDW-CV < 10% — нетипично низкое значение, проверьте ввод.');
      else if (rdw > 25) warnings.push('RDW-CV > 25% — крайне высокое значение, проверьте ввод и мазок.');
    }
    if (isFinite(albGL)) {
      if (albGL < 15 || albGL > 60) errors.push('Альбумин вне диапазона 15–60 g/L — проверьте ввод и единицы.');
    }
    flags = flags || {};
    if (flags.transfusion) warnings.push('Гемотрансфузия < 3 мес.: RDW отражает смесь донорских и собственных эритроцитов — RAR ненадёжен.');
    if (flags.albuminInfusion) warnings.push('Инфузия альбумина/плазмы: сывороточный альбумин искусственно завышен — RAR занижен.');
    if (flags.bleeding) warnings.push('Активное/недавнее кровотечение: RDW и альбумин искажены.');
    if (flags.liver) warnings.push('Цирроз/хроническое заболевание печени: низкий альбумин не отражает онкологический статус.');
    if (flags.kidney) warnings.push('Нефротический синдром/протеинурия: потеря альбумина с мочой.');
    if (flags.hydration) warnings.push('Дегидратация/гипергидратация: альбумин изменён гемоконцентрацией/гемодилюцией.');
    if (flags.acuteInflammation) warnings.push('Острая инфекция/сепсис: альбумин — отрицательный белок острой фазы, RAR отражает острое состояние.');
    if (flags.hematologic) warnings.push('Гемоглобинопатия/гемолиз/миелодиспластический синдром: RDW повышен независимо от опухоли.');
    if (flags.recentChemo) warnings.push('Неоадъювантная химиотерапия < 4 нед.: RDW может быть повышен миелотоксичностью.');
    if (labAgeDays != null && isFinite(labAgeDays)) {
      if (labAgeDays < 0) errors.push('Дата анализа позже даты операции.');
      else if (labAgeDays > 14) warnings.push('Анализы старше 14 дней до операции — рекомендуется повторить.');
    }
    return { errors: errors, warnings: warnings };
  }

  /** Категория по массиву возрастающих порогов (g/L-конвенция). Граница включается в нижнюю категорию. */
  function categorize(rarGL, tiers) {
    var idx = 0;
    while (idx < tiers.length && rarGL > tiers[idx]) idx++;
    var names = CATEGORY_NAMES[tiers.length + 1] ||
      tiers.concat([null]).map(function (_, i) { return 'Категория ' + (i + 1); });
    var nearest = tiers.reduce(function (m, t) { return Math.min(m, Math.abs(rarGL - t)); }, Infinity);
    return {
      index: idx,
      count: tiers.length + 1,
      name: names[idx],
      grayZone: nearest <= 0.01 // ±0.01 от любой границы — «серая зона»
    };
  }

  /**
   * Главная функция.
   * input: { rdw, albumin, albuminUnit, tiers?, flags?, labDate?, surgeryDate? }
   */
  function compute(input) {
    var rdw = Number(input.rdw);
    var alb = albuminToGL(input.albumin, input.albuminUnit || 'auto');
    var labAge = null;
    if (input.labDate && input.surgeryDate) {
      labAge = Math.round((new Date(input.surgeryDate) - new Date(input.labDate)) / 86400000);
    }
    var c = checks(rdw, alb.ok ? alb.gl : NaN, input.flags, labAge);
    if (!alb.ok) c.errors.unshift(alb.error);
    else c.warnings = alb.warnings.concat(c.warnings);
    if (c.errors.length) return { ok: false, errors: c.errors, warnings: c.warnings };

    var rarGL = rdw / alb.gl;
    var tiers = input.tiers || PRESETS.handbook.tiers;
    return {
      ok: true,
      rdw: rdw,
      albuminGL: round(alb.gl, 1),
      albuminUnitUsed: alb.unit,
      albuminAutoDetected: alb.autoDetected,
      rarGL: round(rarGL, 3),
      rarGdL: round(rarGL * 10, 2),
      category: categorize(rarGL, tiers),
      labAgeDays: labAge,
      reliable: c.warnings.length === 0,
      errors: [],
      warnings: c.warnings
    };
  }

  /** Клинические соображения — только проверка/оценка, без автоматических назначений. */
  function considerations(result) {
    if (!result.ok) return [];
    var out = [];
    var hi = result.category.index >= Math.floor(result.category.count / 2); // 5 категорий: с «Внимание»; 2 категории: «Высокий»
    if (hi) {
      out.push('Скрининг нутритивного риска NRS-2002 и оценка мальнутриции по критериям GLIM (вес, ИМТ, потеря массы, мышечная масса).');
      out.push('ESPEN: при тяжёлом нутритивном риске — нутритивная поддержка 7–14 дней до большой операции, даже ценой её отсрочки.');
      out.push('Уточнить причину высокого RDW: ферритин, насыщение трансферрина, B12, фолат, ретикулоциты; коррекция по выявленному дефициту.');
      out.push('Учесть в обсуждении периоперационного риска с анестезиологом и на онкоконсилиуме (вместе с ECOG, ASA, возрастом, коморбидностью).');
    } else {
      out.push('RAR не указывает на дополнительный риск; план лечения — по стадии TNM и клиническим рекомендациям.');
    }
    if (result.category.grayZone) out.push('Значение в «серой зоне» у границы категории — ориентироваться на клинику и динамику, при сомнении повторить анализ.');
    out.push('RAR — прогностический маркер. Объём операции и показания к адъювантной терапии определяются стадией и рекомендациями (ESMO/NCCN/МОЗ), а не RAR.');
    return out;
  }

  return {
    PRESETS: PRESETS,
    albuminToGL: albuminToGL,
    checks: checks,
    categorize: categorize,
    compute: compute,
    considerations: considerations
  };
});
