# Аудит GitHub-аккаунта Serg2206 — 27.09.2026

Проверено **56 репозиториев** (45 публичных, 11 приватных): секреты в коде (gitleaks),
уязвимости зависимостей (`npm audit`), статус CI (GitHub Actions), валидность workflow,
сборка (`npm ci` + `build`) для всех изменённых проектов.

Все исправления сделаны **в отдельных ветках `claude/…`** — основные ветки не тронуты.
Чтобы применить исправление, откройте ссылку «Создать PR» и нажмите *Create pull request* → *Merge*.

---

## 1. Что нужно сделать вам (не может быть сделано из кода)

| Приоритет | Действие |
|---|---|
| 🔴 **Срочно** | **Сменить пароль базы PostgreSQL** `role_fdeea2342@db-fdeea2342.db003.hosteddb.reai.io` и **`NEXTAUTH_SECRET`** проекта `ssvnauka1`: файл `.env` с ними был в **публичном** репозитории. Удаление файла (PR ниже) не убирает его из истории git. Дополнительно — сделать репозиторий приватным. |
| 🔴 **Срочно** | `ssvnauka-platform`: в Vercel → Project → Settings → Environment Variables задать **настоящие** `DATABASE_URL`, `NEXTAUTH_SECRET`, `NEXTAUTH_URL` (раньше `vercel.json` подставлял заглушки, например `NEXTAUTH_SECRET="nextauth_secret"`). |
| 🟠 | Слить 15 PR из раздела 2 (ссылки ниже). |
| 🟡 | Решить судьбу пустых/дублирующих репозиториев (раздел 4). |

---

## 2. Исправлено (15 репозиториев, сборка проверена)

| Репозиторий | Проблема → исправление | Создать PR |
|---|---|---|
| **ssvnauka1** (публ.) | 🔴 закоммичен `.env` с паролем БД и `NEXTAUTH_SECRET` → удалён из индекса, `.gitignore` | [PR](https://github.com/Serg2206/ssvnauka1/pull/new/claude/remove-committed-env) |
| **ssvnauka.com** | Деплой на Pages падал с июля (серверное приложение с Prisma/NextAuth нельзя экспортировать статически) → проверка сборки; отключён `/_next/image` (RCE в Next 14); из репо убраны `.logs/` (113 файлов) и `.deploy/app.tgz` (26 МБ) | [PR](https://github.com/Serg2206/ssvnauka.com/pull/new/claude/fix-ci-and-hardening) |
| **ssvnauka.net** | 🔴 Next 15.5.20 (критические RCE) → **15.5.26**; сборка и typecheck ✅ | [PR](https://github.com/Serg2206/ssvnauka.net/pull/new/claude/security-deps) |
| **gastric-cancer-platform-2026** (прив.) | 🔴 Next 15.5.19 → **15.5.26**; `npm ci` падал (lock-файл не совпадал) → исправлен | [PR](https://github.com/Serg2206/gastric-cancer-platform-2026/pull/new/claude/security-deps) |
| **gastric-cancer-platform-2026s** | то же | [PR](https://github.com/Serg2206/gastric-cancer-platform-2026s/pull/new/claude/security-deps) |
| **surgical-research-platform-mvp** | 🔴 Next 16.2.11 → **16.3.6**; lint, тесты 20/20, сборка ✅ | [PR](https://github.com/Serg2206/surgical-research-platform-mvp/pull/new/claude/security-deps) |
| **next-platform-starter** | 🔴 Next 15.1.5 (обход авторизации middleware, RCE) → **15.5.26**; 2 шаблонных workflow падали всегда (Grunt без Gruntfile, Datadog без ключей) → нормальный CI | [PR](https://github.com/Serg2206/next-platform-starter/pull/new/claude/security-deps-ci) |
| **ssvnauka** | Деплой падал (lock-файл рассинхр., нет статического экспорта) и мог затереть живой сайт `gh-pages` → только проверка сборки; Next → 14.2.35; next-auth → 4.24.15 (критич.) | [PR](https://github.com/Serg2206/ssvnauka/pull/new/claude/fix-ci) |
| **ssvnauka-platform** | 🔴 `vercel.json` задавал `NEXTAUTH_SECRET="nextauth_secret"` в публичном репо → удалено; деплой падал с ноября 2025 → пропускается без токенов Vercel | [PR](https://github.com/Serg2206/ssvnauka-platform/pull/new/claude/fix-vercel-config) |
| **ssvproff-journal** | `yarn.lock` сохранён как символическая ссылка длиной 438 КБ → репозиторий **не распаковывался нигде** → обычный файл | [PR](https://github.com/Serg2206/ssvproff-journal/pull/new/claude/fix-yarn-lock-symlink) |
| **SSVproff** | CodeQL и Release Drafter: испорченный YAML (лесенка отступов) — падали на каждый push → восстановлены | [PR](https://github.com/Serg2206/SSVproff/pull/new/claude/fix-broken-workflows) |
| **WindowsOptimizer** | Функция `Clear-RecycleBin` вызывала саму себя (бесконечная рекурсия); файл без BOM (кракозябры в PS 5.1); 2 испорченных workflow | [PR](https://github.com/Serg2206/WindowsOptimizer/pull/new/claude/fix-script-and-workflows) |
| **ai-oncotarget-hope-site** (прив.) | Проект **не устанавливался и не собирался**: конфликт `date-fns`, неверный `manualChunks`, нет `terser` → всё исправлено; уязвимости 26 → 6 | [PR](https://github.com/Serg2206/ai-oncotarget-hope-site/pull/new/claude/security-deps) |
| **cdss-ostry-zhivot-2026** | `npm audit fix` (7 → 0 уязвимостей) | [PR](https://github.com/Serg2206/cdss-ostry-zhivot-2026/pull/new/claude/security-deps) |
| **surgical-ai-mentor-hub** (прив.) | `npm audit fix` (26 → 6) | [PR](https://github.com/Serg2206/surgical-ai-mentor-hub/pull/new/claude/security-deps) |

---

## 3. Проверено, исправлений не требует

- **Секреты**: кроме `ssvnauka1`, находки gitleaks — ложные (заглушки `YOUR_TOKEN` в документации, тестовый ключ, ссылка на картинку). Ключи Supabase в двух Lovable-проектах — публичные `anon`-ключи (так задумано; важно, чтобы в Supabase была включена RLS).
- **`medical_data.csv`** в medical-research-repoNS — 10 обезличенных учебных строк, персональных данных нет.
- **Next 14** в ssvnauka1, gastric-surgery-course, ssvnauka-platform — `images.unoptimized: true`, поэтому критическая RCE через `/_next/image` не применима.
- Все остальные workflow (54 репозитория) — валидный YAML.

---

## 4. Рекомендации (решение за вами)

**Пустые репозитории** (0 файлов): `Discord-SSVproff`, `pages-deploy`, `Serg2206.github.ioo` — удалить или архивировать.

**Дубли**:
- `ssvnauka-net` и `ssvnauka-net-backup` — идентичны (отличается только README);
- `gastric-cancer-platform-2026` (прив.) и `gastric-cancer-platform-2026s` (публ.) — почти копии;
- **7 репозиториев одного сайта ssvnauka**: `ssvnauka`, `ssvnauka1`, `ssvnauka.com`, `ssvnauka-platform`, `ssvnauka-site`, `ssvnauka.github.io`, `ssvnauka.net`. Причём CNAME `ssvnauka.com` есть в `ssvnauka` (ветка gh-pages), а `ssvnauka.com` и `ssvnauka-platform` настроены на Vercel — стоит определить **один** источник живого сайта, остальные архивировать (Settings → Archive).

**Боты в medical-research-repoNS**: 8 расписаний делают ~2000 запусков и коммитят прямо в `main` каждые 6 часов (327 автоматических отчётов). `auto-refactoring` переписывает код через OpenAI и **пушит в main без проверки**, тратя ключ `OPENAI_API_KEY`. Рекомендуется: оставить `pylint`, а остальным поставить `workflow_dispatch` (запуск вручную) или переключить на создание PR.

**Остаточные уязвимости**: `postcss` внутри Next (только при сборке), `plotly.js`/`maplibre-gl` в ssvnauka (исправление — мажорное обновление plotly 2→4, требует проверки графиков).

**Гигиена**: 20 репозиториев без коммитов с 2025 г.; 30 без файла LICENSE; включите в Settings → *Code security* **Dependabot alerts** и **Secret scanning** для всех публичных репозиториев — они бесплатны.
