---
type: knowledge
status: active
date: 2026-04-30
tags: [release, ci, codemagic, testflight, app-store]
---

# Akifi iOS — релиз-процесс

Описание того, как должны идти билды и сабмишн на App Store. Появился после серии повторяющихся ошибок «Apple отверг билд из-за закрытого train» и «What's New заполнено мусором». Все защиты — в `codemagic.yaml`. Если изменения в нём — обновить и этот документ.

## Два workflow

| Workflow | Триггер | Что делает |
|---|---|---|
| `ios-release` | `git push origin main` | Auto-bump версии + guard + build + upload в TestFlight + distribute beta-группам |
| `ios-submit-review` | `git tag release/v* && git push origin release/v*` | Ждёт VALID build в TestFlight → выбирает его для версии в App Store → Sonnet генерирует «Что нового» + Promotional Text → Submit for Review |

## Порядок шагов в `ios-release` (всё критично)

```
1. Decode App Store Connect API key   ← ОБЯЗАТЕЛЬНО ПЕРВЫМ
2. Lint multi-currency (ADR-001)
3. Generate xcconfig from env vars
4. Auto-version, build number, project ← использует .p8 из шага 1
   ├─ ASC query: max(approved, in-review, TF) → bump patch
   └─ Pre-flight guard: версия не должна быть в закрытом state
5. Set up code signing
6. Resolve SPM dependencies
7. Apply profiles + build IPA
8. Upload to TestFlight + distribute Beta Testers, External Testers
```

## Главные защиты (зачем они)

### Decode .p8 ПЕРВЫМ шагом

Без этого auto-bump на шаге 4 не находит `.p8` ключ (он создавался в шаге 5 «Set up code signing») → silent fallback на `MARKETING_VERSION` из `project.yml` → если там 1.3.0, а 1.3.0 уже approved, Apple реджектит upload через 30 минут.

Шаг проверяет, что декодированный ключ **не пустой** — если секрет `APP_STORE_CONNECT_PRIVATE_KEY_BASE64` сломан, билд падает за 5 секунд с понятной ошибкой, а не через полчаса с кодом 90062.

### Pre-flight version guard

Сразу после auto-bump делает дополнительный ASC-запрос и проверяет, что итоговая `MARKETING_VERSION` **не находится в закрытом состоянии** (`READY_FOR_SALE` / `IN_REVIEW` / `PENDING_APPLE_RELEASE` / `PROCESSING_FOR_APP_STORE` / `PENDING_DEVELOPER_RELEASE` / `REPLACED_WITH_NEW_VERSION`).

Если ASC недоступен — логирует WARN и пропускает (не блокирует билд из-за сетевой проблемы). Если попадает в закрытый train — `exit 1` с явным сообщением:

```
==== BUILD ABORTED ====
MARKETING_VERSION '1.3.0' is already taken on App Store Connect.
Bump it in project.yml (e.g. 1.3.1 → 1.3.2) and push again.
=======================
```

### Release-notes генератор (для submit-review)

Использует **Sonnet 4.6** (не Haiku — он терял bullet'ы), max_tokens 8192. Промпт жёсткий:

- Каждый `feat:`/`fix:`/`perf:` коммит обязан стать bullet'ом — нельзя пропускать;
- `docs:`/`chore:`/`ci:`/`test:`/`style:`/`refactor:` НИКОГДА не bullet — схлопываются в одну строку «Performance and stability improvements»;
- Стоп-слова в выходе: README, FEATURE_ROADMAP, PRD, RLS, migration, ViewModel, JWT, cron job, Supabase и т.д.;
- `[BETA]` / `Sprint N —` / `(scope)` чистятся из subject'ов;
- `whatsNew` и `promotionalText` обязательно непустые — оба PATCH'атся всегда (раньше пустой promo пропускался → оставался stale).

Превью первых 400 символов whatsNew + promo пишется в build-лог Codemagic — silent regress становится виден сразу.

## Триггерим релиз

```bash
# 1. Запушить main → запускается ios-release
git push origin main

# 2. Дождаться processed build в TestFlight (~25-35 мин)
#    Видно в App Store Connect → TestFlight → версия 1.3.X

# 3. Тегнуть РЕАЛЬНУЮ версию в TestFlight
git tag release/v1.3.X
git push origin release/v1.3.X
```

> **ВАЖНО:** `1.3.X` в теге должна совпадать с версией в TestFlight. Auto-bump может поднять версию выше, чем в `project.yml` (если в ASC уже есть закрытые train'ы). Перед тегом проверь, что реально загружено в TestFlight, и тегни именно эту версию. Иначе `ios-submit-review` упадёт: «No processed builds found for version 1.3.X».

## Если что-то пошло не так

### Билд упал на «BUILD ABORTED — MARKETING_VERSION already taken»
Pre-flight guard сработал. Ручной bump в `project.yml`:
```bash
sed -i '' 's/MARKETING_VERSION: 1.3.1/MARKETING_VERSION: 1.3.2/' project.yml
git add project.yml && git commit -m "chore(release): bump 1.3.2"
git push origin main
```

### Билд успешен, но `What's New` в App Store — мусор / Promotional Text пуст
Регресс в release-notes генераторе. Проверить в build-логе ios-submit-review:
- Какую модель использовали (`claude-sonnet-4-6`)?
- Что вернул preview? (логируется первыми 400 chars).
- Был ли fallback на `technical_notes`?

Поправить промпт в `codemagic.yaml`, push в main, retag версии (через `git tag -d` + push с двоеточием для удаления, потом новый тег).

### Submit-review упал «No processed builds found»
Тегнули слишком рано — TestFlight ещё processing. Удалить тег и пере-создать:
```bash
git tag -d release/v1.3.1
git push origin :release/v1.3.1
# Подождать пока в TestFlight видно «Ready to Submit», ~10-30 мин
git tag release/v1.3.1 && git push origin release/v1.3.1
```

## Связанные

- Skill `codemagic-ios-cicd` (в `~/.claude/skills/`) — расширенная справка с lesson'ами 1-15, в первую очередь 13 (decode .p8 + guard) и 14 (release-notes).
- `codemagic.yaml` — рабочий конфиг с обоими workflow'ами.
- ADR-001 (`Scripts/lint-amount-usage.sh`) — guard на multi-currency, blocking как часть CI с Phase 8.
