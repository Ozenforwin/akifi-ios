# Agent Factory Brain — Инструкции для агентов

## Кто мы
Команда Agent Factory — 12 специализированных AI-агентов для мультиплатформенной разработки.
Этот Obsidian vault — наша общая память, knowledge graph и система принятия решений.

**Стек:** SwiftUI · Kotlin/Compose · PHP/Laravel/DDD · Next.js/React · Supabase
**Деплой:** Railway (основной) · Hetzner (production-grade)
**Дизайн:** Figma
**Трекер:** Linear

## Иерархия чтения контекста

При старте ЛЮБОЙ сессии агент ОБЯЗАН читать в этом порядке:

1. `Hot/hot.md` — текущий фокус, приоритеты, ключевые решения
2. `Hot/current-sprint.md` — задачи текущего спринта
3. `Hot/blockers.md` — активные блокеры
4. Релевантный `_index.md` в нужной папке (карта содержимого)
5. Конкретные заметки по задаче

> [!warning] Экономия токенов
> НЕ читай всё подряд. Используй `_index.md` как навигацию, потом иди в конкретные файлы.

## Правила работы с vault

### Frontmatter (ОБЯЗАТЕЛЬНО в каждой заметке)
```yaml
---
type: adr | prd | sprint | session | bug | knowledge | agent | daily
status: draft | proposed | active | accepted | rejected | resolved | done
date: YYYY-MM-DD
tags: [tag1, tag2]
---
```

### Wikilinks (КРИТИЧНО для графа связей)
ВСЕГДА создавай связи через `[[]]`:
- Агент → `[[team-lead]]`, `[[backend]]`, `[[ios]]`
- Проект → `[[project-name]]`
- ADR → `[[ADR-001-название]]`
- PRD → `[[feature-название]]`
- Паттерн → `[[cqrs]]`, `[[ddd-aggregates]]`
- Спринт → `[[2026-W15]]`
- Термин → `[[glossary#термин]]`

### Callouts (визуальное выделение)
```markdown
> [!danger] Критично
> Требует немедленного внимания

> [!warning] Блокер
> Описание проблемы

> [!tip] Решение
> Как решили

> [!info] Контекст
> Дополнительная информация

> [!question] Вопрос
> Нужно уточнить у Vladimir
```

### Tags (стандартные)
- `#adr` — архитектурное решение
- `#prd` — требования к продукту
- `#bug` — баг
- `#session` — лог сессии агентов
- `#decision` — принятое решение
- `#blocker` — блокер
- `#spike` — исследование/эксперимент
- `#tech-debt` — технический долг
- `#api` — связано с API
- `#security` — безопасность
- `#performance` — производительность

### Именование файлов
| Тип | Формат | Пример |
|-----|--------|--------|
| ADR | `ADR-NNN-kebab-case.md` | `ADR-001-database-choice.md` |
| PRD | `feature-kebab-case.md` | `feature-auth.md` |
| Sprint | `YYYY-WNN.md` | `2026-W15.md` |
| Session | `YYYY-MM-DD-description.md` | `2026-04-09-auth-api.md` |
| Bug | `BUG-NNN-description.md` | `BUG-001-login-crash.md` |
| Daily | `YYYY-MM-DD.md` | `2026-04-09.md` |

### Размещение файлов
| Тип | Папка |
|-----|-------|
| Архитектурные решения | `Architecture/ADR/` |
| Диаграммы (Mermaid) | `Architecture/diagrams/` |
| Паттерны проектирования | `Architecture/patterns/` |
| Требования к фичам | `PRD/` |
| Информация об агентах | `Agents/` |
| Технические знания | `Knowledge/tech/` |
| Доменные знания | `Knowledge/domain/` |
| Конкуренты | `Knowledge/competitors/` |
| Спринты | `Sprints/` |
| Открытые баги | `Issues/open/` |
| Решённые баги | `Issues/resolved/` |
| Логи сессий | `Sessions/` |
| Ежедневные заметки | `Daily/` |

## Протокол сессии

### При СТАРТЕ сессии
1. Прочитай `Hot/hot.md`
2. Определи релевантный контекст через `_index.md` файлы
3. Прочитай связанные ADR и PRD

### При ЗАВЕРШЕНИИ сессии
1. Создай session log в `Sessions/YYYY-MM-DD-description.md`
2. Обнови `Hot/hot.md` — текущий статус, что изменилось
3. Обнови `Hot/current-sprint.md` — отметь выполненные задачи
4. Добавь новые блокеры в `Hot/blockers.md` (если есть)
5. Создай/обнови заметки в `Issues/` для найденных багов
6. Добавь wikilinks на все упомянутые сущности

## Команда агентов

| Агент | Модель | Роль |
|-------|--------|------|
| [[product-manager]] | Opus | Продуктовая стратегия, PRD, приоритизация |
| [[team-lead]] | Opus | Оркестрация, декомпозиция, делегирование |
| [[architect]] | Opus | DDD, CQRS, API, ADR |
| [[ai-architect]] | Opus | RAG, LLM, промпты, AI-фичи |
| [[backend]] | Opus | PHP 8.3, Laravel 11, DDD, TDD |
| [[frontend]] | Sonnet | Next.js 14, React 18, TypeScript |
| [[ios]] | Opus | SwiftUI, Swift 5.9+, @Observable |
| [[android]] | Opus | Kotlin, Compose, Material3, Hilt |
| [[tester]] | Sonnet | QA, тест-планы, edge cases |
| [[reviewer]] | Opus | Code review, OWASP, quality gates |
| [[devops]] | Sonnet | Docker, Railway, Hetzner, CI/CD |
| [[designer]] | Sonnet | UI/UX, дизайн-система, токены |
